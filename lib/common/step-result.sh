#!/usr/bin/env bash
#
# SYNOPSIS
#     Контракт возврата шага: единый результат, как New-StepResult в WindowsConfigurator.
#
# DESCRIPTION
#     Шаг сообщает итог кодом возврата, а человекочитаемое сообщение кладёт в
#     LCFG_STEP_MESSAGE. Оркестратор не разбирает вывод шага и не парсит строки:
#     код возврата однозначен, сообщение отдельное, поэтому сводка корректна даже
#     когда шаг печатает многострочный лог.
#
#     Коды возврата функции шага:
#       0 - Success  действие выполнено (или уже было выполнено ранее - идемпотентность);
#       1 - Failed   действие не выполнено, причина в сообщении;
#       3 - Skipped  шаг неприменим к этой машине (другое семейство ОС, нет пакета,
#                    отключён в конфигурации, пользователь отказался).
#
#     Код 2 намеренно НЕ используется шагами: он зарезервирован под критические
#     ошибки запуска в точке входа, и смешение смыслов привело бы к тому, что
#     "шаг пропущен" читался бы как "конфигурация невалидна".
#
#     Шаг обязан использовать эти три функции вместо голого return: только они
#     пишут в журнал и устанавливают сообщение.

declare -g LCFG_STEP_MESSAGE=''
declare -g LCFG_STEP_DATA=''

readonly LC_RC_SUCCESS=0
readonly LC_RC_FAILED=1
readonly LC_RC_SKIPPED=3

step_reset_message() {
    LCFG_STEP_MESSAGE=''
    LCFG_STEP_DATA=''
}

step_ok() {
    LCFG_STEP_MESSAGE="${1:-выполнено}"
    LCFG_STEP_DATA="${2:-}"
    log_info "${LCFG_STEP_NAME:-step}: ${LCFG_STEP_MESSAGE}"
    return "$LC_RC_SUCCESS"
}

step_failed() {
    LCFG_STEP_MESSAGE="${1:-ошибка}"
    LCFG_STEP_DATA="${2:-}"
    log_error "${LCFG_STEP_NAME:-step}: ${LCFG_STEP_MESSAGE}"
    return "$LC_RC_FAILED"
}

step_skipped() {
    LCFG_STEP_MESSAGE="${1:-пропущено}"
    LCFG_STEP_DATA="${2:-}"
    log_debug "${LCFG_STEP_NAME:-step}: ${LCFG_STEP_MESSAGE}"
    return "$LC_RC_SKIPPED"
}
