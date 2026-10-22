#!/usr/bin/env bash
#
# SYNOPSIS
#     Состояние процесса запуска: конфигурация, флаги, значения, результаты шагов.
#
# DESCRIPTION
#     Баш не умеет возвращать из функции ничего, кроме кода возврата, поэтому всё
#     разделяемое состояние живёт в глобальных переменных этого модуля, а доступ к нему
#     идёт только через функции-аксессоры. Прямое обращение к LCFG_* из шагов считается
#     ошибкой: аксессоры - единственное место, где определены имена и значения по умолчанию.
#
#     Результаты шагов накапливаются в параллельных массивах (имя/статус/сообщение/длительность),
#     а не в строках JSON, чтобы сводку можно было напечатать без парсера и не потерять
#     сообщения, содержащие кавычки и переводы строк.

declare -gA LCFG_FLAGS=()
declare -gA LCFG_VALUES=()
declare -ga LCFG_RESULT_NAME=()
declare -ga LCFG_RESULT_STATUS=()
declare -ga LCFG_RESULT_MESSAGE=()
declare -ga LCFG_RESULT_MS=()
declare -g LCFG_CONFIG=''
declare -g LCFG_PROJECT_ROOT=''
declare -g LCFG_VERSION='0.0.0'

runtime_init() {
    LCFG_PROJECT_ROOT="$1"
    LCFG_VERSION="$2"
    LCFG_RESULT_NAME=()
    LCFG_RESULT_STATUS=()
    LCFG_RESULT_MESSAGE=()
    LCFG_RESULT_MS=()
}

runtime_set_config() {
    LCFG_CONFIG="$1"
}

runtime_get_config() {
    printf '%s' "$LCFG_CONFIG"
}

runtime_set_flag() {
    LCFG_FLAGS["$1"]="$2"
}

runtime_flag() {
    local name="$1"
    [[ "${LCFG_FLAGS[$name]:-false}" == true ]]
}

runtime_set_value() {
    LCFG_VALUES["$1"]="$2"
}

runtime_value() {
    local name="$1"
    local default="${2:-}"
    printf '%s' "${LCFG_VALUES[$name]:-$default}"
}

# Добавляет результат шага в сводку.
#
# Аргументы:
#   $1 - имя шага
#   $2 - статус: Success | Failed | Skipped | WhatIf
#   $3 - человекочитаемое сообщение
#   $4 - длительность в миллисекундах (необязательно)
runtime_add_result() {
    LCFG_RESULT_NAME+=("$1")
    LCFG_RESULT_STATUS+=("$2")
    LCFG_RESULT_MESSAGE+=("$3")
    LCFG_RESULT_MS+=("${4:-0}")
}

# Печатает сводку запуска и возвращает код: 0 - все шаги успешны, 1 - есть упавшие.
runtime_print_summary() {
    local total="${#LCFG_RESULT_NAME[@]}"
    local failed=0
    local skipped=0
    local i status

    console_plain ''
    console_plain '=========> Summary <========='

    for ((i = 0; i < total; i++)); do
        status="${LCFG_RESULT_STATUS[$i]}"
        case "$status" in
            Failed)  ((failed++))  || true ;;
            Skipped) ((skipped++)) || true ;;
        esac
        console_result_line "${LCFG_RESULT_NAME[$i]}" "$status" \
            "${LCFG_RESULT_MESSAGE[$i]}" "${LCFG_RESULT_MS[$i]}"
    done

    console_plain "Steps: ${total}, failed: ${failed}, skipped: ${skipped}"
    console_plain '=============================================='

    if ((failed > 0)); then
        return 1
    fi
    return 0
}
