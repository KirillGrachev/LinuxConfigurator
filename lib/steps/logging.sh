#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг logging: ограничение journald и правила logrotate.
#
# DESCRIPTION
#     Журнал по умолчанию растёт до 10% размера файловой системы и не ограничен по
#     времени. На диске в 40 ГБ это 4 ГБ, которые незаметно съедаются за недели работы
#     шумного сервиса, а заканчивается место всегда в самый неудобный момент - обычно
#     это выглядит как внезапно перешедшая в read-only файловая система.
#
#     Ограничение задаётся drop-in в journald.conf.d, а не правкой journald.conf:
#     файл пакета заменяется при обновлении systemd, drop-in - нет.
#
#     ForwardToSyslog по умолчанию выключен: при включённом rsyslog каждая запись
#     journald дублируется в /var/log/syslog, то есть журнал занимает вдвое больше
#     места. Дублирование включается явно, только если логи действительно собирает
#     внешний syslog-сервер.
#
#     Правила logrotate генерируются из массива Logrotate.Rules, чтобы одно правило
#     на несколько путей или нестандартная частота не требовали правки кода шага.

step_logging() {
    if ! config_section_enabled Journald && ! config_section_enabled Logrotate; then
        step_skipped 'Journald и Logrotate отключены'
        return $?
    fi

    local -a done_parts=()

    if config_section_enabled Journald; then
        if logging_configure_journald; then
            done_parts+=("journald=$(config_get '.Journald.SystemMaxUse' '400M')")
        else
            step_failed 'не удалось применить настройки journald'
            return $?
        fi
    fi

    if config_section_enabled Logrotate; then
        local rules_count
        rules_count="$(logging_configure_logrotate)"
        if [[ -n "$rules_count" ]]; then
            done_parts+=("logrotate=${rules_count} правил(а)")
        fi
    fi

    if (( ${#done_parts[@]} == 0 )); then
        step_skipped 'нечего настраивать'
        return $?
    fi

    step_ok "$(IFS=', '; echo "${done_parts[*]}")"
    return $?
}

logging_configure_journald() {
    local dropin
    dropin="$(config_get '.Journald.DropInPath' '/etc/systemd/journald.conf.d/99-linuxconfigurator.conf')"

    local bool_directive
    bool_directive() { [[ "$1" == true ]] && printf 'true' || printf 'false'; }

    fs_ensure_dir "$(dirname "$dropin")" 755
    fs_write "$dropin" "# Managed by LinuxConfigurator ${LCFG_VERSION}
# Ограничение журнала по объёму и по сроку: без него journald растёт до 10% ФС.
[Journal]
SystemMaxUse=$(config_get '.Journald.SystemMaxUse' '400M')
SystemMaxFileSize=$(config_get '.Journald.SystemMaxFileSize' '50M')
RuntimeMaxUse=$(config_get '.Journald.RuntimeMaxUse' '64M')
MaxRetentionSec=$(config_get '.Journald.MaxRetentionSec' '14day')
Compress=$(bool_directive "$(config_get_bool '.Journald.Compress' true && echo true || echo false)")
ForwardToSyslog=$(bool_directive "$(config_get_bool '.Journald.ForwardToSyslog' false && echo true || echo false)")
" 644 root:root

    run_quiet systemctl restart systemd-journald || {
        log_warn 'systemd-journald не перезапущен, настройки применятся при следующей загрузке.'
    }
    return 0
}

# Возвращает число записанных правил.
logging_configure_logrotate() {
    local conf rules_json count
    conf="$(config_get '.Logrotate.ConfigPath' '/etc/logrotate.d/linuxconfigurator')"
    rules_json="$(config_get_object '.Logrotate.Rules')"
    count="$(printf '%s' "$rules_json" | jq 'if type == "array" then length else 0 end')"

    if (( count == 0 )); then
        printf ''
        return 0
    fi

    local content="# Managed by LinuxConfigurator ${LCFG_VERSION}
# Источник: config.json -> Logrotate.Rules.
"
    local i path rotate
    for ((i = 0; i < count; i++)); do
        path="$(printf '%s' "$rules_json" | jq -r ".[${i}].Path")"
        rotate="$(printf '%s' "$rules_json" | jq -r ".[${i}].Rotate")"

        content+=$'\n'"${path} {"$'\n'
        content+="    rotate ${rotate}"$'\n'
        content+="    $(printf '%s' "$rules_json" | jq -r ".[${i}].Frequency // \"daily\"")"$'\n'

        local max_size
        max_size="$(printf '%s' "$rules_json" | jq -r ".[${i}].MaxSize // empty")"
        [[ -n "$max_size" ]] && content+="    maxsize ${max_size}"$'\n'

        local flag directive
        for flag in Compress:compress DelayCompress:delaycompress MissingOk:missingok \
                    NotIfEmpty:notifempty CopyTruncate:copytruncate; do
            directive="${flag#*:}"
            if [[ "$(printf '%s' "$rules_json" | jq -r ".[${i}].${flag%:*} // false")" == true ]]; then
                content+="    ${directive}"$'\n'
            fi
        done

        content+='}'$'\n'
    done

    fs_write "$conf" "$content" 644 root:root

    # Проверка синтаксиса: невалидное правило в /etc/logrotate.d ломает ротацию
    # ВСЕХ журналов в системе, а не только своего, поэтому лучше откатить.
    if ! testmode_enabled && run_has logrotate; then
        if ! logrotate -d "$conf" > /dev/null 2>&1; then
            log_error "logrotate отклонил ${conf}:"
            logrotate -d "$conf" 2>&1 | head -3 | while IFS= read -r l; do log_error "  ${l}"; done
            fs_remove "$conf"
            printf ''
            return 1
        fi
    fi

    printf '%s' "$count"
}
