#!/usr/bin/env bash
#
# SYNOPSIS
#     Точка входа базового конфигуратора Linux-сервера.
#
# DESCRIPTION
#     Тонкая обёртка: разбирает аргументы, загружает функции проекта, вызывает
#     оркестратор start_configuration и ПРЕОБРАЗУЕТ его результат в код возврата
#     процесса. Прикладной логики здесь намеренно нет - её тестируют через функции
#     из lib/, а сам файл проверяется интеграционным тестом (запуск в дочернем bash).
#
#     Коды возврата:
#       0 - все шаги выполнены успешно (или запрошена только проверка конфигурации);
#       1 - часть шагов завершилась ошибкой (сводка в консоли и в журнале);
#       2 - критическая ошибка запуска: конфигурация не прошла валидацию по схеме,
#           нет прав root, неизвестный шаг, не найдена обязательная утилита.
#
# ARGUMENTS
#     --run-all            выполнить шаги из General.DefaultSteps конфигурации
#     --run-steps LIST     выполнить только перечисленные шаги (через запятую)
#     --interactive        запустить интерактивное меню выбора шагов
#     --config PATH        путь к config.json (по умолчанию <проект>/config/config.json)
#     --validate-config    только проверить конфигурацию по схеме и выйти (0 или 2)
#     --log PATH           переопределить путь журнала (Logging.FilePath)
#     --user NAME          целевой пользователь для шагов, работающих с профилем
#     --test-mode          полная логика шагов, но все побочные эффекты СИМУЛИРУЮТСЯ:
#                          команды журналируются, файлы пишутся в песочницу
#                          (/tmp/LCFG-TestMode-*), по итогам создаётся testmode-report.json
#     --what-if            только показать запланированные действия, ничего не выполняя
#     --yes                не спрашивать подтверждений
#     --verbose            подробный вывод (уровень Debug)
#     --version            версия конфигуратора
#     --help               эта справка
#
# EXAMPLES
#     sudo ./configure-linux.sh --run-all
#     sudo ./configure-linux.sh --run-steps ssh,firewall,fail2ban
#     sudo ./configure-linux.sh --test-mode --run-all
#     ./configure-linux.sh --validate-config --config /etc/lcfg/prod.json
#     sudo ./configure-linux.sh --interactive
#
# NOTES
#     Требуется bash 5.x и jq. Совместимость: Debian 11/12, Ubuntu 20.04/22.04/24.04,
#     RHEL-подобные 8/9 (шаги, специфичные для семейства, пропускаются с [SKIP]).

set -euo pipefail

readonly LC_VERSION='1.0.0'

# Присваивание отделено от readonly: запись вида `readonly X="$(...)"` всегда
# возвращает статус самого readonly, поэтому сбой cd/pwd остался бы незамеченным
# и запуск продолжился бы с пустым путём к проекту.
LC_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "[FATAL] Could not determine the project directory." >&2
    exit 2
}
readonly LC_PROJECT_ROOT

# Префикс переменных окружения конфигуратора. Намеренно НЕ "LC_": LC_ALL, LC_CTYPE
# и прочие LC_* зарезервированы POSIX под локаль, и их перехват сломал бы кодировки.
export LCFG_PREFIX='LCFG_'

usage() {
    sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
    local run_all=false
    local interactive=false
    local validate_only=false
    local test_mode=false
    local what_if=false
    local assume_yes=false
    local verbose=false
    local run_steps=''
    local config_path=''
    local log_path=''
    local target_user=''

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-all)         run_all=true; shift ;;
            --run-steps)       run_steps="${2:-}"; shift 2 ;;
            --interactive)     interactive=true; shift ;;
            --config)          config_path="${2:-}"; shift 2 ;;
            --validate-config) validate_only=true; shift ;;
            --log)             log_path="${2:-}"; shift 2 ;;
            --user)            target_user="${2:-}"; shift 2 ;;
            --test-mode)       test_mode=true; shift ;;
            --what-if)         what_if=true; shift ;;
            --yes|-y)          assume_yes=true; shift ;;
            --verbose|-v)      verbose=true; shift ;;
            --version)         echo "LinuxConfigurator ${LC_VERSION}"; return 0 ;;
            --help|-h)         usage; return 0 ;;
            *)
                echo "[FATAL] Unknown argument: $1" >&2
                echo "        Run with --help to see the argument list." >&2
                return 2
                ;;
        esac
    done

    if [[ -z "$config_path" ]]; then
        config_path="${LC_PROJECT_ROOT}/config/config.json"
    fi

    # shellcheck source=lib/load-functions.sh
    if ! source "${LC_PROJECT_ROOT}/lib/load-functions.sh"; then
        echo "[FATAL] Failed to load the project functions." >&2
        return 2
    fi

    runtime_init "$LC_PROJECT_ROOT" "$LC_VERSION"
    runtime_set_flag test_mode "$test_mode"
    runtime_set_flag what_if "$what_if"
    runtime_set_flag assume_yes "$assume_yes"
    runtime_set_flag verbose "$verbose"
    # Путь сохраняется для меню (пункт "проверить конфигурацию") и для отчёта.
    runtime_set_value config_path "$config_path"

    if [[ "$test_mode" == true ]]; then
        testmode_enable
    fi

    # --- Режим проверки конфигурации: никаких изменений системы ---
    if [[ "$validate_only" == true ]]; then
        if config_validate_file "$config_path"; then
            console_ok "Configuration '${config_path}' matches the schema."
            config_print_warnings "$config_path"
            return 0
        fi
        console_fatal "Configuration '${config_path}' does NOT match the schema (details above)."
        return 2
    fi

    log_init "$config_path" "$log_path"

    local config
    if ! config="$(config_load "$config_path")"; then
        console_fatal "Failed to read configuration '${config_path}'."
        return 2
    fi
    runtime_set_config "$config"

    # Каталог резервных копий: без этого вызова LCFG_BACKUP_DIR пуст, fs_backup
    # молча ничего не копирует, и откатывать правки sshd/fstab было бы неоткуда.
    if config_get_bool '.Backup.Enabled' true; then
        fs_set_backup_dir "$(config_get '.Backup.DirectoryPath' '/var/backups/linuxconfigurator')"
        fs_ensure_dir "$(config_get '.Backup.DirectoryPath' '/var/backups/linuxconfigurator')" 700
    fi

    # Порог подтверждения из конфигурации: без этого General.ConfirmImpact
    # игнорировался и confirm_step_action всегда работал со значением Medium.
    confirm_set_impact "$(config_get '.General.ConfirmImpact' 'Medium')"

    if [[ -n "$target_user" ]]; then
        runtime_set_value target_user "$target_user"
    fi

    local summary_rc=0
    if [[ "$interactive" == true ]]; then
        menu_run || summary_rc=$?
    elif [[ -n "$run_steps" ]]; then
        orchestrator_run_steps "$run_steps" || summary_rc=$?
    elif [[ "$run_all" == true ]]; then
        orchestrator_run_default_steps || summary_rc=$?
    else
        console_fatal 'No run mode selected: use --run-all, --run-steps LIST or --interactive.'
        return 2
    fi

    return "$summary_rc"
}

main "$@"
