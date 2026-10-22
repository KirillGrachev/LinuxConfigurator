#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг motd: информационное сообщение при входе.
#
# DESCRIPTION
#     Генерируется ИСПОЛНЯЕМЫЙ скрипт в /etc/update-motd.d/, а не статический текст:
#     цифры (свободное место, занятая память, версия ядра) устаревают в первый же день,
#     а статический баннер начинает врать и перестаёт читаться.
#
#     Скрипт motd пишется через heredoc с одинарными кавычками, поэтому все $-переменные
#     в нём остаются литералами и раскрываются при КАЖДОМ входе, а не один раз
#     в момент настройки. Это частая ошибка: сгенерированный motd с подставленными
#     значениями показывает состояние машины на дату установки.
#
#     motd обязан быть отказоустойчивым: он выполняется при каждом входе, включая вход
#     в аварийном режиме, и его падение не должно мешать получению сессии. Поэтому
#     все вызовы защищены, а сам скрипт завершается кодом 0 безусловно.
#
#     Предупреждения о pending reboot и о failed units выводятся в motd намеренно:
#     это два состояния, которые легко пропустить и которые означают, что применённые
#     обновления ещё не действуют.

step_motd() {
    if ! config_section_enabled Motd; then
        step_skipped 'Motd.Enabled = false'
        return $?
    fi

    local path
    path="$(config_get '.Motd.Path' '/etc/update-motd.d/99-linuxconfigurator')"

    if [[ ! -d /etc/update-motd.d ]]; then
        step_skipped '/etc/update-motd.d is missing (not Debian/Ubuntu, or pam_motd disabled)'
        return $?
    fi

    fs_ensure_dir "$(dirname "$path")" 755
    fs_write "$path" "$(motd_render_script)" 755 root:root

    # Проверка, что сгенерированный скрипт хотя бы синтаксически корректен и
    # не падает при выполнении: ошибка здесь показывалась бы при каждом входе.
    if ! testmode_enabled; then
        if ! bash -n "$path" 2>/dev/null; then
            log_error "Generated ${path} failed the syntax check; removing it."
            fs_remove "$path"
            step_failed 'the motd script is syntactically invalid'
            return $?
        fi
        if ! "$path" > /dev/null 2>&1; then
            log_warn "Generated ${path} returned a non-zero code; check the login output."
        fi
    fi

    step_ok "${path}"
    return $?
}

motd_render_script() {
    local show_kernel show_memory show_disk show_failed show_reboot custom
    show_kernel="$(config_get_bool '.Motd.ShowKernel' true && echo 1 || echo 0)"
    show_memory="$(config_get_bool '.Motd.ShowMemory' true && echo 1 || echo 0)"
    show_disk="$(config_get_bool '.Motd.ShowDisk' true && echo 1 || echo 0)"
    show_failed="$(config_get_bool '.Motd.ShowFailedUnits' true && echo 1 || echo 0)"
    show_reboot="$(config_get_bool '.Motd.ShowRebootPending' true && echo 1 || echo 0)"
    custom="$(config_get '.Motd.CustomText' '')"

    # Одинарные кавычки в разделителе heredoc: содержимое записывается буквально,
    # переменные раскроются при выполнении motd, а не сейчас.
    cat <<MOTD
#!/bin/sh
# Managed by LinuxConfigurator ${LCFG_VERSION}. Генерируется шагом motd.
# Выполняется при каждом входе, поэтому обязан завершаться кодом 0.

printf '\\n\\033[1m %s\\033[0m  %s\\n' "\$(hostname 2>/dev/null || echo '?')" \\
    "\$( (. /etc/os-release 2>/dev/null && printf '%s' "\${PRETTY_NAME:-Linux}") 2>/dev/null || echo Linux)"

if [ "${show_kernel}" = 1 ]; then
    printf '   %-12s %s\\n' "kernel:" "\$(uname -r 2>/dev/null)"
fi

if [ "${show_memory}" = 1 ] && command -v free > /dev/null 2>&1; then
    printf '   %-12s %s\\n' "memory:" \\
        "\$(free -h 2>/dev/null | awk '/Mem:/{printf "%s used / %s total", \$3, \$2}')"
    if command -v swapon > /dev/null 2>&1; then
        SWAP="\$(swapon --show=SIZE --noheadings 2>/dev/null | head -1)"
        [ -n "\$SWAP" ] && printf '   %-12s %s\\n' "swap:" "\$SWAP"
    fi
fi

if [ "${show_disk}" = 1 ] && command -v df > /dev/null 2>&1; then
    printf '   %-12s %s\\n' "disk /:" \\
        "\$(df -h / 2>/dev/null | awk 'NR==2{printf "%s used / %s (%s)", \$3, \$2, \$5}')"
fi

if [ "${show_failed}" = 1 ] && command -v systemctl > /dev/null 2>&1; then
    FAILED="\$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
    if [ "\$FAILED" != 0 ]; then
        printf '   \\033[31m!! %s failed unit(s): systemctl --failed\\033[0m\\n' "\$FAILED"
    fi
fi

if [ "${show_reboot}" = 1 ]; then
    if [ -f /var/run/reboot-required ]; then
        printf '   \\033[33m* reboot required: %s\\033[0m\\n' \\
            "\$(cat /var/run/reboot-required.pkgs 2>/dev/null | head -3 | paste -sd, -)"
    else
        RUNNING="\$(uname -r 2>/dev/null)"
        NEWEST=""
        for f in /boot/vmlinuz-*; do
            [ -e "\$f" ] || continue
            NEWEST="\${f#/boot/vmlinuz-}"
        done
        if [ -n "\$NEWEST" ] && [ "\$NEWEST" != "\$RUNNING" ]; then
            printf '   \\033[33m* kernel %s installed, %s running; reboot required\\033[0m\\n' \\
                "\$NEWEST" "\$RUNNING"
        fi
    fi
fi
MOTD

    if [[ -n "$custom" ]]; then
        printf '\nprintf '"'"'\\n%%s\\n'"'"' %s\n' "'${custom}'"
    fi

    printf '\nexit 0\n'
}
