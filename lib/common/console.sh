#!/usr/bin/env bash
#
# SYNOPSIS
#     Консольный вывод с едиными префиксами и цветами.
#
# DESCRIPTION
#     Префиксы совпадают с WindowsConfigurator, чтобы сводка двух конфигураторов
#     читалась одинаково: [OK] [WARN] [FAIL] [SKIP] [WHATIF] [FATAL].
#
#     Цвет включается только когда stdout - терминал: при перенаправлении в файл или
#     в CI-лог ESC-последовательности превратились бы в мусор, который невозможно
#     прочитать глазами и неудобно сравнивать в тестах.

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    readonly LCFG_C_RESET=$'\033[0m'
    readonly LCFG_C_GREEN=$'\033[32m'
    readonly LCFG_C_YELLOW=$'\033[33m'
    readonly LCFG_C_RED=$'\033[31m'
    readonly LCFG_C_CYAN=$'\033[36m'
    readonly LCFG_C_GRAY=$'\033[90m'
    readonly LCFG_C_MAGENTA=$'\033[35m'
else
    readonly LCFG_C_RESET=''
    readonly LCFG_C_GREEN=''
    readonly LCFG_C_YELLOW=''
    readonly LCFG_C_RED=''
    readonly LCFG_C_CYAN=''
    readonly LCFG_C_GRAY=''
    readonly LCFG_C_MAGENTA=''
fi

console_plain() { printf '%s\n' "$*"; }

console_ok()    { printf '%s[OK]%s %s\n'    "$LCFG_C_GREEN"  "$LCFG_C_RESET" "$*"; }
console_warn()  { printf '%s[WARN]%s %s\n'  "$LCFG_C_YELLOW" "$LCFG_C_RESET" "$*" >&2; }
console_fail()  { printf '%s[FAIL]%s %s\n'  "$LCFG_C_RED"    "$LCFG_C_RESET" "$*" >&2; }
console_skip()  { printf '%s[SKIP]%s %s\n'  "$LCFG_C_YELLOW" "$LCFG_C_RESET" "$*"; }
console_info()  { printf '%s[..]%s %s\n'    "$LCFG_C_CYAN"   "$LCFG_C_RESET" "$*"; }
console_fatal() { printf '%s[FATAL]%s %s\n' "$LCFG_C_RED"    "$LCFG_C_RESET" "$*" >&2; }

# Что будет сделано, но не делается (--what-if).
console_dry()   { printf '%s[WHATIF]%s %s\n' "$LCFG_C_GRAY" "$LCFG_C_RESET" "$*"; }

# Действие, которое в тестовом режиме симулировано, а не выполнено.
console_sim()   { printf '%s[TESTMODE]%s %s\n' "$LCFG_C_MAGENTA" "$LCFG_C_RESET" "$*"; }

# Строка сводки: имя шага, статус, сообщение, длительность.
console_result_line() {
    local name="$1" status="$2" message="$3" ms="${4:-0}"
    local mark color

    case "$status" in
        Success) mark='[OK]   '; color="$LCFG_C_GREEN" ;;
        Skipped) mark='[SKIP] '; color="$LCFG_C_YELLOW" ;;
        WhatIf)  mark='[WHATIF]'; color="$LCFG_C_GRAY" ;;
        *)       mark='[FAIL] '; color="$LCFG_C_RED" ;;
    esac

    printf '%s%s%s %-18s %s %s(%s ms)%s\n' \
        "$color" "$mark" "$LCFG_C_RESET" "$name" "$message" "$LCFG_C_GRAY" "$ms" "$LCFG_C_RESET"
}
