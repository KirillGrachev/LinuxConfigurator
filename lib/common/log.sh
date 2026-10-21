#!/usr/bin/env bash
#
# SYNOPSIS
#     Журналирование: файл + консоль, уровни, ротация по сроку хранения.
#
# DESCRIPTION
#     Путь журнала, уровень и срок хранения берутся из секции Logging конфигурации.
#     Инициализация намеренно читает JSON напрямую через jq, а не через config_load:
#     модуль конфигурации сам пишет в журнал, и обратная зависимость замкнула бы цикл
#     (log_init -> config_load -> log_write -> журнал ещё не инициализирован).
#
#     Запись в файл идёт через одиночный printf с перенаправлением >>: это атомарно
#     для строк короче PIPE_BUF, поэтому параллельные шаги не interleaved'ят журнал.
#
#     Ротация удаляет только файлы, подходящие под маску журнала в том же каталоге,
#     и только старше RetentionDays - чужие файлы не затрагиваются.

declare -g LCFG_LOG_FILE=''
declare -g LCFG_LOG_LEVEL='INFO'
declare -g LCFG_LOG_CONSOLE=true
declare -g LCFG_LOG_RETENTION_DAYS=30

# Числовой вес уровня: сообщение пишется, если его вес >= веса порога.
log_level_weight() {
    case "${1^^}" in
        DEBUG) printf '10' ;;
        INFO)  printf '20' ;;
        WARN)  printf '30' ;;
        ERROR) printf '40' ;;
        FATAL) printf '50' ;;
        *)     printf '20' ;;
    esac
}

log_init() {
    local config_path="${1:-}"
    local log_override="${2:-}"
    local level file retention console

    if [[ -n "$config_path" && -r "$config_path" ]]; then
        level="$(jq -r '.Logging.Level // "Info"' "$config_path" 2>/dev/null || echo Info)"
        file="$(jq -r '.Logging.FilePath // ""' "$config_path" 2>/dev/null || echo '')"
        retention="$(jq -r '.Logging.RetentionDays // 30' "$config_path" 2>/dev/null || echo 30)"
        console="$(jq -r '.Logging.WriteToConsole // true' "$config_path" 2>/dev/null || echo true)"
    else
        level='Info'; file=''; retention=30; console=true
    fi

    LCFG_LOG_LEVEL="${level^^}"
    LCFG_LOG_RETENTION_DAYS="$retention"
    LCFG_LOG_CONSOLE="$console"

    if runtime_flag verbose; then
        LCFG_LOG_LEVEL='DEBUG'
    fi

    if [[ -n "$log_override" ]]; then
        file="$log_override"
    fi

    # Пустой путь в конфигурации означает "только консоль".
    if [[ -n "$file" ]]; then
        file="$(path_expand_tokens "$file")"
        if mkdir -p "$(dirname "$file")" 2>/dev/null; then
            LCFG_LOG_FILE="$file"
            log_rotate
        else
            # Не роняем запуск из-за недоступного каталога журнала: диагностика
            # важнее самого журнала, поэтому уходим в консольный режим с предупреждением.
            console_warn "Каталог журнала '${file}' недоступен, журнал ведётся только в консоли."
            LCFG_LOG_FILE=''
        fi
    fi

    log_write 'DEBUG' "Журнал инициализирован: file='${LCFG_LOG_FILE}' level=${LCFG_LOG_LEVEL}"
}

log_write() {
    local level="${1^^}"
    local message="$2"
    local timestamp line

    if (( $(log_level_weight "$level") < $(log_level_weight "$LCFG_LOG_LEVEL") )); then
        return 0
    fi

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    line="${timestamp} [$(printf '%-5s' "$level")] ${message}"

    if [[ -n "$LCFG_LOG_FILE" ]]; then
        printf '%s\n' "$line" >> "$LCFG_LOG_FILE" 2>/dev/null || true
    fi

    # В консоль дублируются только предупреждения и ошибки: информационные строки
    # и так печатаются шагами через console_*, иначе вывод двоился бы.
    if [[ "$LCFG_LOG_CONSOLE" == true ]]; then
        case "$level" in
            WARN)  console_warn  "$message" ;;
            ERROR) console_fail  "$message" ;;
            FATAL) console_fatal "$message" ;;
            DEBUG) runtime_flag verbose && printf '%s%s%s\n' "$LCFG_C_GRAY" "$line" "$LCFG_C_RESET" ;;
        esac
    fi

    return 0
}

log_debug() { log_write DEBUG "$1"; }
log_info()  { log_write INFO  "$1"; }
log_warn()  { log_write WARN  "$1"; }
log_error() { log_write ERROR "$1"; }
log_fatal() { log_write FATAL "$1"; }

log_rotate() {
    local dir base
    [[ -n "$LCFG_LOG_FILE" ]] || return 0
    [[ "$LCFG_LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] || return 0
    (( LCFG_LOG_RETENTION_DAYS > 0 )) || return 0

    dir="$(dirname "$LCFG_LOG_FILE")"
    base="$(basename "$LCFG_LOG_FILE")"

    local removed=0
    while IFS= read -r -d '' stale; do
        # Не `rm -f && ((removed++))`: постинкремент возвращает ПРЕДЫДУЩЕЕ значение,
        # то есть при removed=0 выражение даёт код 1 и под set -e ротация
        # прервалась бы на первом же удалённом файле.
        if rm -f "$stale"; then
            removed=$((removed + 1))
        fi
    done < <(find "$dir" -maxdepth 1 -type f -name "${base}*" \
                    -mtime "+${LCFG_LOG_RETENTION_DAYS}" -print0 2>/dev/null)

    (( removed > 0 )) && log_debug "Ротация журнала: удалено файлов: ${removed}"
    return 0
}
