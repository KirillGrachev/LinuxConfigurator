#!/usr/bin/env bash
#
# SYNOPSIS
#     Подтверждение действия шага с учётом --what-if, --yes и ConfirmImpact.
#
# DESCRIPTION
#     Аналог Confirm-StepAction из WindowsConfigurator. Возвращает не "да/нет",
#     а одно из трёх состояний, потому что шаг должен различать их в сводке:
#
#       0 - выполнять;
#       1 - пропустить (пользователь отказался) -> статус Skipped;
#       2 - не выполнять, действие только показано -> статус WhatIf.
#
#     Поведение по источнику сигнала:
#       --what-if        всегда 2, никаких вопросов;
#       --test-mode      всегда 0: логика шага должна пройти целиком, иначе тест
#                        не покроет ветки, которые выполняются после подтверждения;
#       --yes            всегда 0;
#       stdin не терминал всегда 0 с предупреждением - интерактивный запрос в CI
#                        или в конвейере подвесил бы запуск навсегда;
#       иначе             запрос на терминале, при отказе 1.
#
#     General.ConfirmImpact из конфигурации ("Low"/"Medium"/"High") определяет,
#     спрашивать ли вообще: для Low подтверждение не запрашивается.

declare -g LCFG_CONFIRM_IMPACT='Medium'

confirm_set_impact() {
    LCFG_CONFIRM_IMPACT="$1"
}

confirm_impact_weight() {
    case "$1" in
        Low)    printf '1' ;;
        Medium) printf '2' ;;
        High)   printf '3' ;;
        *)      printf '2' ;;
    esac
}

# Аргументы:
#   $1 - цель действия (что изменяется), например "sshd_config"
#   $2 - описание действия, например "Отключить вход по паролю"
#   $3 - уровень риска действия (необязательно, по умолчанию LCFG_CONFIRM_IMPACT)
confirm_step_action() {
    local target="$1"
    local action="$2"
    local impact="${3:-$LCFG_CONFIRM_IMPACT}"

    if runtime_flag what_if; then
        console_dry "${action}: ${target}"
        return 2
    fi

    if testmode_enabled; then
        testmode_journal confirm simulate "${target}" "${action}"
        return 0
    fi

    if runtime_flag assume_yes; then
        return 0
    fi

    if (( $(confirm_impact_weight "$impact") <= 1 )); then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_warn "Подтверждение запрошено для '${action}', но stdin не терминал - выполняю без запроса."
        return 0
    fi

    local answer
    printf '%s%s%s %s [%s]? (y/N) ' \
        "$LCFG_C_YELLOW" '?' "$LCFG_C_RESET" "$action" "$target" >&2
    read -r answer || answer=''

    case "${answer,,}" in
        y|yes|д|да) return 0 ;;
        *)          return 1 ;;
    esac
}
