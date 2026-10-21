#!/usr/bin/env bash
#
# SYNOPSIS
#     Единственная точка запуска внешних команд.
#
# DESCRIPTION
#     Все шаги вызывают внешние утилиты (apt-get, systemctl, sysctl, nft, sshd, useradd)
#     только через run_cmd / run_capture. Благодаря этому:
#
#       - в тестовом режиме команда не исполняется: точная командная строка уходит в журнал,
#         а вывод и код возврата берутся из фикстуры. Тест проверяет, ЧТО именно скрипт
#         собирался выполнить, а не только что он не упал;
#       - в режиме --what-if команда не исполняется и не подбирается фикстура - действие
#         просто показывается;
#       - каждая команда попадает в журнал одной и той же строкой формата, поэтому
#         прогон можно разбирать grep'ом и воспроизводить вручную.
#
#     Коды возврата:
#       run_cmd     - код возврата команды (в тестовом режиме - из фикстуры, по умолчанию 0)
#       run_capture - то же, но stdout возвращается через вывод функции
#
#     ВАЖНО: функции не глотают ошибки намеренно. Шаг решает, критичен ли провал:
#     где-то нужен немедленный Failed (sshd -t перед reload), а где-то достаточно
#     предупреждения (apt-get autoremove).

# Исполняет команду. Аргументы передаются как есть, без склейки в строку,
# поэтому значения с пробелами и кавычками не требуют экранирования от вызывающего.
run_cmd() {
    local display="$*"

    if runtime_flag what_if; then
        console_dry "$display"
        testmode_journal whatif command "$display"
        return 0
    fi

    if testmode_enabled; then
        testmode_journal command exec "$display"
        local fixture output rc
        if fixture="$(testmode_get_fixture "$display")"; then
            output="${fixture%%$'\x1f'*}"
            rc="${fixture##*$'\x1f'}"
        else
            output=''
            rc=0
        fi
        [[ -n "$output" ]] && printf '%s\n' "$output"
        return "$rc"
    fi

    log_debug "EXEC: ${display}"
    "$@"
}

# Исполняет команду и возвращает её stdout. stderr проходит насквозь,
# чтобы ошибки diagnostics не терялись.
run_capture() {
    local display="$*"

    if runtime_flag what_if; then
        console_dry "$display"
        testmode_journal whatif capture "$display"
        return 0
    fi

    if testmode_enabled; then
        testmode_journal command capture "$display"
        local fixture output
        if fixture="$(testmode_get_fixture "$display")"; then
            output="${fixture%%$'\x1f'*}"
            printf '%s' "$output"
        fi
        return 0
    fi

    log_debug "CAPTURE: ${display}"
    "$@" 2>/dev/null
}

# Исполняет команду, подавляя весь вывод. Возвращает код возврата.
run_quiet() {
    local display="$*"

    if runtime_flag what_if || testmode_enabled; then
        run_cmd "$@" > /dev/null
        return $?
    fi

    log_debug "QUIET: ${display}"
    "$@" > /dev/null 2>&1
}

# Проверяет доступность исполняемого файла (учитывает тестовый режим: там команда
# могла бы быть симулирована, но отсутствие бинарника всё равно говорит о том,
# что шаг на этой машине неприменим).
run_has() {
    command -v "$1" > /dev/null 2>&1
}
