#!/usr/bin/env bash
#
# SYNOPSIS
#     Чтение и валидация конфигурации, доступ к значениям по jq-пути.
#
# DESCRIPTION
#     Конфигурация загружается в память ОДИН раз (runtime_set_config) и дальше
#     читается из переменной, а не с диска: шаги опрашивают её десятки раз, и каждый
#     повторный jq-вызов по файлу - это лишний fork на одноядерной машине.
#
#     Валидация по схеме выполняется до любых изменений системы. Это принципиально:
#     конфигуратор правит sshd_config и fstab, и применять настройки из конфигурации,
#     где опечатка в имени поля прошла незамеченной, значит настраивать машину
#     значениями по умолчанию молча.
#
#     Особенности чтения значений:
#       - jq выводит строку "null" для отсутствующего поля, поэтому "null" трактуется
#         как отсутствие значения и заменяется значением по умолчанию. Побочный эффект:
#         строковое значение буквально равное "null" неотличимо от отсутствия - на практике
#         в конфигурации сервера таких значений не бывает, а отдельный протокол "пусто/нет"
#         усложнил бы все аксессоры;
#       - config_get_array печатает по элементу в строку, поэтому значения, содержащие
#         перевод строки, массивом передать нельзя (для списков пакетов и портов это не нужно).

declare -g LCFG_SCHEMA_PATH=''

config_schema_path() {
    if [[ -n "$LCFG_SCHEMA_PATH" ]]; then
        printf '%s' "$LCFG_SCHEMA_PATH"
        return 0
    fi
    printf '%s' "${LCFG_PROJECT_ROOT}/config/config.schema.json"
}

# Проверяет файл конфигурации по схеме.
# Печатает ошибки в консоль и возвращает 0/1.
config_validate_file() {
    local config_path="$1"
    local schema_path
    schema_path="$(config_schema_path)"

    if [[ ! -r "$config_path" ]]; then
        console_fatal "Файл конфигурации не найден или не читается: ${config_path}"
        return 1
    fi
    if [[ ! -r "$schema_path" ]]; then
        console_fatal "Файл схемы не найден или не читается: ${schema_path}"
        return 1
    fi

    if ! jq -e . "$config_path" > /dev/null 2>&1; then
        console_fatal "Конфигурация не является корректным JSON: ${config_path}"
        jq . "$config_path" 2>&1 | head -3 | while IFS= read -r line; do console_fatal "  ${line}"; done
        return 1
    fi

    local result
    result="$(jq -f "${LCFG_PROJECT_ROOT}/lib/config/validate-schema.jq" \
                 --argjson config "$(cat "$config_path")" "$schema_path" 2>&1)" || {
        console_fatal "Валидатор схемы завершился ошибкой:"
        printf '%s\n' "$result" | head -5 | while IFS= read -r line; do console_fatal "  ${line}"; done
        return 1
    }

    local error error_count
    error_count="$(printf '%s' "$result" | jq -r '.errorCount')"

    if [[ "$error_count" == 0 ]]; then
        return 0
    fi

    console_fatal "Ошибок валидации: ${error_count}"
    while IFS= read -r error; do
        [[ -n "$error" ]] && console_fatal "  ${error}"
    done < <(printf '%s' "$result" | jq -r '.errors[]')

    return 1
}

# Загружает конфигурацию: валидирует и возвращает компактный JSON.
config_load() {
    local config_path="$1"

    config_validate_file "$config_path" || return 1
    jq -c . "$config_path"
}

# Предупреждения, которые не являются ошибками схемы, но означают вероятную проблему.
config_print_warnings() {
    local config_path="$1"
    local is_test pw_auth step stop_on_failure swap_mb disk_free_mb

    is_test="$(jq -r '.Meta.IsTestData // false' "$config_path")"
    if [[ "$is_test" == true ]]; then
        console_warn 'Meta.IsTestData = true: конфигурация содержит тестовые значения. Замените их перед применением к боевой машине.'
    fi

    # Заглушка в Hostname.Name - самая частая ошибка при копировании конфига
    # с другой машины: имя применяется, и в логах целого парка оказывается
    # одинаковый hostname.
    local host_name
    host_name="$(jq -r '.Hostname.Name // ""' "$config_path")"
    case "$host_name" in
        ''|changeme-host|changeme|localhost|hostname|server)
            console_warn "Hostname.Name = '${host_name:-<пусто>}' похоже на заглушку. Задайте реальное имя машины, иначе шаг hostname завершится ошибкой."
            ;;
    esac

    pw_auth="$(jq -r '.Ssh.PasswordAuthentication // false' "$config_path")"
    if [[ "$pw_auth" == true ]]; then
        console_warn 'Ssh.PasswordAuthentication = true: вход по паролю останется разрешён. Для публичного сервера это основной вектор подбора.'
    fi

    # Неизвестное имя шага в DefaultSteps - опечатка, из-за которой часть настройки
    # молча не выполнится. Схема не может это проверить: список шагов живёт в реестре.
    while IFS= read -r step; do
        [[ -n "$step" ]] || continue
        if ! step_exists "$step"; then
            console_warn "General.DefaultSteps содержит неизвестный шаг '${step}' - он будет отклонён при запуске."
        fi
    done < <(jq -r '.General.DefaultSteps[]?' "$config_path")

    stop_on_failure="$(jq -r '.General.StopOnFirstFailure // false' "$config_path")"
    if [[ "$stop_on_failure" == true ]]; then
        console_warn 'General.StopOnFirstFailure = true: первая же ошибка прервёт весь прогон.'
    fi

    swap_mb="$(jq -r '.Swap.SizeMegabytes // 0' "$config_path")"
    if [[ "$swap_mb" =~ ^[0-9]+$ ]] && (( swap_mb > 0 )); then
        disk_free_mb="$(sys_disk_free_mb /)"
        if [[ -n "$disk_free_mb" ]] && (( swap_mb + 1024 > disk_free_mb )); then
            console_warn "Swap.SizeMegabytes=${swap_mb}, но на / свободно всего ${disk_free_mb} MiB - не хватает места."
        fi
    fi
}

config_get() {
    local path="$1"
    local default="${2:-}"
    local value

    [[ -n "$LCFG_CONFIG" ]] || { printf '%s' "$default"; return 0; }

    value="$(printf '%s' "$LCFG_CONFIG" | jq -r "$path" 2>/dev/null || printf '')"
    if [[ -z "$value" || "$value" == null ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

config_get_bool() {
    local value
    value="$(config_get "$1" "${2:-false}")"
    [[ "${value,,}" == true ]]
}

config_get_int() {
    local value
    value="$(config_get "$1" "${2:-0}")"
    if [[ "$value" =~ ^-?[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "${2:-0}"
    fi
}

# Элементы массива по одному в строку. Отсутствие массива - пустой вывод, не ошибка.
config_get_array() {
    local path="$1"
    [[ -n "$LCFG_CONFIG" ]] || return 0
    printf '%s' "$LCFG_CONFIG" | jq -r "${path}[]? // empty" 2>/dev/null || true
}

config_get_object() {
    local path="$1"
    [[ -n "$LCFG_CONFIG" ]] || { printf '{}'; return 0; }
    printf '%s' "$LCFG_CONFIG" | jq -c "${path} // {}" 2>/dev/null || printf '{}'
}

# Секция включена, если у неё нет поля Enabled либо оно true.
# Отсутствие секции означает "не включать": шаг, для которого в конфигурации
# ничего не описано, не должен менять систему.
config_section_enabled() {
    local section="$1"
    local present enabled

    present="$(printf '%s' "$LCFG_CONFIG" | jq -r "has(\"${section}\")" 2>/dev/null || echo false)"
    [[ "$present" == true ]] || return 1

    enabled="$(config_get ".${section}.Enabled" true)"
    [[ "${enabled,,}" == true ]]
}
