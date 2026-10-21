#!/usr/bin/env bash
#
# SYNOPSIS
#     Предполётные проверки окружения.
#
# DESCRIPTION
#     Проверяются три вещи, без которых запуск бессмыслен или опасен: версия bash,
#     наличие обязательных утилит и права root.
#
#     Права root в тестовом режиме НЕ требуются - это принципиально: тестовый режим
#     существует затем, чтобы прогнать сценарий на живой машине или в CI без риска,
#     а требование root свело бы его пользу к нулю.
#
#     Проверка bash отделена от проверки утилит, потому что associative arrays
#     (declare -A) не работают в bash 3.x, а именно они используются в runtime.sh,
#     который загружается раньше всех остальных модулей.

# Требуется bash 5.0+: declare -A (4.0), ${var^^} (4.0) и EPOCHREALTIME (5.0),
# который оркестратор использует для замера длительности шагов в миллисекундах.
# Debian 11+/Ubuntu 20.04+ поставляют bash 5.x, поэтому требование не ограничивает парк.
require_bash() {
    local major="${BASH_VERSINFO[0]:-0}"
    if (( major < 5 )); then
        console_fatal "Требуется bash 5.0 или новее, обнаружен ${BASH_VERSION}."
        console_fatal "Причина: EPOCHREALTIME для замера длительности шагов."
        return 2
    fi
    return 0
}

# Проверяет наличие исполняемых файлов.
# Аргументы: имена утилит. Возвращает 2, если чего-то не хватает.
require_cmd() {
    local missing=()
    local name

    for name in "$@"; do
        command -v "$name" > /dev/null 2>&1 || missing+=("$name")
    done

    if (( ${#missing[@]} > 0 )); then
        console_fatal "Не найдены обязательные утилиты: ${missing[*]}"
        console_fatal "Установите их и повторите запуск."
        return 2
    fi
    return 0
}

require_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    if testmode_enabled; then
        log_debug 'Права root не требуются в тестовом режиме.'
        return 0
    fi
    console_fatal 'Шаг требует прав root. Запустите через sudo или от имени root.'
    return 2
}

# Проверяет, что семейство ОС поддерживается шагом.
# Аргументы: ожидаемые семейства (debian rhel suse alpine).
require_family() {
    local family expected
    family="$(pkg_family)"

    for expected in "$@"; do
        [[ "$family" == "$expected" ]] && return 0
    done

    log_warn "Семейство ОС '${family}' не входит в поддерживаемые ($*) - шаг будет пропущён."
    return 1
}

# Общая предполётная проверка запуска.
require_preflight() {
    require_bash || return 2
    require_cmd jq sed grep awk find mktemp date || return 2
    return 0
}
