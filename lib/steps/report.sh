#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг report: сводка фактического состояния машины после настройки.
#
# DESCRIPTION
#     Последний шаг, и единственный, который НИЧЕГО не меняет. Его задача - показать
#     не "что конфигуратор собирался сделать", а "что получилось по факту": разница
#     между ними и есть источник всех неприятных сюрпризов.
#
#     Проверяются именно применившиеся значения, а не содержимое конфигов:
#       - sshd -T, а не текст drop-in (другой drop-in может перекрывать наш);
#       - nft list set, а не файл правил (таблица могла не загрузиться);
#       - swapon --show, а не запись в /etc/fstab (запись есть, а подкачка не поднялась);
#       - systemctl --failed, а не "мы включили сервис".
#
#     Отдельно сообщается о pending reboot: после обновления ядра применённые настройки
#     действуют не полностью, и без явного напоминания машина месяцами работает
#     на старом ядре, а оператор уверен, что всё обновлено.
#
#     Report.FilePath сохраняет сводку в файл (в формате обычного текста, а не JSON:
#     её читают глазами при разборе инцидента, а для машинной обработки есть
#     testmode-report.json).

step_report() {
    if ! config_section_enabled Report; then
        step_skipped 'Report.Enabled = false'
        return $?
    fi

    local report
    report="$(report_collect)"

    if config_get_bool '.Report.PrintToConsole' true; then
        printf '%s\n' "$report"
    fi

    local path
    path="$(config_get '.Report.FilePath' '')"
    if [[ -n "$path" ]]; then
        path="$(path_expand_tokens "$path")"
        fs_write "$path" "${report}"$'\n' 640 root:root
        log_info "Summary saved: ${path}"
    fi

    local reboot_hint
    reboot_hint="$(sys_reboot_pending)"
    if [[ -n "$reboot_hint" ]]; then
        step_ok "summary collected; REBOOT REQUIRED (${reboot_hint})"
        return $?
    fi

    step_ok 'summary collected, no reboot required'
    return $?
}

report_collect() {
    local out=''
    local pending

    out+="=========> Machine State <========="$'\n'
    out+="$(printf '  %-16s %s' 'host:'      "$(sys_hostname)")"$'\n'
    out+="$(printf '  %-16s %s' 'os:'        "$(sys_os_pretty)")"$'\n'
    out+="$(printf '  %-16s %s' 'kernel:'      "$(sys_kernel)")"$'\n'
    out+="$(printf '  %-16s %s' 'arch:' "$(sys_arch)")"$'\n'
    out+="$(printf '  %-16s %s' 'virtualization:' "$(sys_virt)")"$'\n'
    out+="$(printf '  %-16s %s' 'CPU/RAM:'   "$(sys_cpu_count) vCPU / $(sys_memory_mb) MiB")"$'\n'
    out+="$(printf '  %-16s %s' 'swap:'      "$(report_swap)")"$'\n'
    out+="$(printf '  %-16s %s' 'disk /:'    "$(report_disk)")"$'\n'
    out+="$(printf '  %-16s %s' 'time:'     "$(date '+%Y-%m-%d %H:%M:%S %Z')")"$'\n'

    if config_get_bool '.Report.IncludeFailedUnits' true; then
        out+="$(printf '  %-16s %s' 'failed units:' "$(report_failed_units)")"$'\n'
    fi

    out+=''
    out+="$(printf '  %-16s %s' 'sshd:'      "$(report_ssh_effective)")"$'\n'
    out+="$(printf '  %-16s %s' 'firewall:'  "$(report_firewall_state)")"$'\n'
    out+="$(printf '  %-16s %s' 'fail2ban:'  "$(report_fail2ban_state)")"$'\n'
    out+="$(printf '  %-16s %s' 'updates:'   "$(report_updates_state)")"$'\n'

    if config_get_bool '.Report.IncludeOpenPorts' true; then
        out+=''
        out+="  Open TCP ports:"$'\n'
        out+="$(report_listening)"$'\n'
    fi

    pending="$(sys_reboot_pending)"
    if [[ -n "$pending" ]] && config_get_bool '.Report.IncludeRebootHint' true; then
        out+=''
        out+="  WARNING: reboot required (${pending})."$'\n'
        out+="  Some updates stay inactive until reboot."$'\n'
    fi

    out+='=========================================================='
    printf '%s' "$out"
}

report_swap() {
    if testmode_enabled; then printf 'n/a (test mode)'; return 0; fi
    local line
    line="$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | head -1)"
    [[ -n "$line" ]] && printf '%s' "$line" || printf 'absent'
}

report_disk() {
    if testmode_enabled; then printf 'n/a (test mode)'; return 0; fi
    df -h / 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s used)", $3, $2, $5}'
}

report_failed_units() {
    if testmode_enabled; then printf 'n/a (test mode)'; return 0; fi
    local count
    count="$(systemctl --failed --no-legend 2>/dev/null | grep -c . || true)"
    if [[ "$count" == 0 ]]; then
        printf 'none'
    else
        printf '%s: %s' "$count" "$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' | paste -sd, -)"
    fi
}

report_ssh_effective() {
    if testmode_enabled; then printf 'n/a (test mode)'; return 0; fi
    command -v sshd > /dev/null 2>&1 || { printf 'sshd not installed'; return 0; }

    local eff pw root
    eff="$(sshd -T 2>/dev/null)" || { printf 'failed to read'; return 0; }
    pw="$(printf '%s\n' "$eff" | awk '/^passwordauthentication /{print $2}')"
    root="$(printf '%s\n' "$eff" | awk '/^permitrootlogin /{print $2}')"
    printf 'password=%s, root=%s, maxauthtries=%s' "$pw" "$root" \
        "$(printf '%s\n' "$eff" | awk '/^maxauthtries /{print $2}')"
}

report_firewall_state() {
    if testmode_enabled; then printf 'n/a (test mode)'; return 0; fi
    command -v nft > /dev/null 2>&1 || { printf 'nft not installed'; return 0; }

    local table
    table="$(config_get '.Firewall.TableName' 'fw')"
    if ! nft list table inet "$table" > /dev/null 2>&1; then
        printf 'table inet %s is not loaded' "$table"
        return 0
    fi

    local policy ports
    policy="$(nft list chain inet "$table" input 2>/dev/null | grep -oE 'policy [a-z]+' | head -1)"
    ports="$(nft list set inet "$table" allowed_tcp 2>/dev/null | grep -oE 'elements = \{[^}]*\}' | sed 's/elements = //')"
    printf '%s, TCP=%s, service=%s' "${policy:-policy ?}" "${ports:-?}" \
        "$(systemctl is-active nftables 2>/dev/null || echo '?')"
}

report_fail2ban_state() {
    if testmode_enabled; then printf 'n/a (test mode)'; return 0; fi
    command -v fail2ban-client > /dev/null 2>&1 || { printf 'not installed'; return 0; }

    local banned jails
    banned="$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2}')"
    jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{gsub(/^ +/,"",$2); print $2}')"
    printf 'active=%s, banned=%s, jails=%s' \
        "$(systemctl is-active fail2ban 2>/dev/null || echo '?')" "${banned:-0}" "${jails:-none}"
}

report_updates_state() {
    if testmode_enabled; then printf 'n/a (test mode)'; return 0; fi

    local uu='none' timers=''
    if systemctl is-enabled unattended-upgrades > /dev/null 2>&1; then
        uu="$(systemctl is-enabled unattended-upgrades)"
    fi
    timers="$(systemctl list-timers --no-legend apt-daily.timer apt-daily-upgrade.timer 2>/dev/null | grep -c . || true)"
    printf 'unattended-upgrades=%s, timers=%s' "$uu" "$timers"
}

report_listening() {
    if testmode_enabled; then printf '    n/a (test mode)'; return 0; fi
    command -v ss > /dev/null 2>&1 || { printf '    ss not installed'; return 0; }
    ss -tlnpH 2>/dev/null | awk '{printf "    %-6s %-26s %s\n", "tcp", $4, $6}' | sort -u
}
