#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг time: часовой пояс, локаль и синхронизация времени.
#
# DESCRIPTION
#     Расхождение часов ломает TLS-рукопожатия (сертификат "ещё не действителен"),
#     Kerberos, репликацию БД и сравнение меток в логах, поэтому шаг идёт вторым -
#     до установки пакетов, которые могут ходить в сеть по HTTPS.
#
#     NTP: предпочтительный демон берётся из Time.Ntp.Preferred, но если он недоступен
#     в репозитории или не установлен, шаг переключается на systemd-timesyncd
#     (Time.Ntp.FallbackToTimesyncd). Молча оставить машину без синхронизации хуже,
#     чем поставить не тот демон, которого просили.
#
#     Локаль задаётся через /etc/default/locale, а не только через localectl: на образах
#     без systemd-localed (контейнеры, минимальные cloud-образы) localectl не работает,
#     а файл читается PAM при любом раскладе.
#
#     Явно устанавливается LANG, но НЕ LC_ALL: LC_ALL перекрывает все остальные
#     переменные категории и его установка на уровне системы ломает программы,
#     которые рассчитывают на собственную локаль вывода.

step_time() {
    if ! config_section_enabled Time; then
        step_skipped 'Time.Enabled = false'
        return $?
    fi

    local -a done_parts=()
    local tz locale ntp_result

    tz="$(config_get '.Time.Timezone' 'UTC')"
    locale="$(config_get '.Time.Locale' 'C.UTF-8')"

    if time_apply_timezone "$tz"; then
        done_parts+=("tz=${tz}")
    else
        step_failed "failed to set timezone '${tz}'"
        return $?
    fi

    if time_apply_locale "$locale"; then
        done_parts+=("locale=${locale}")
    else
        log_warn "Locale '${locale}' was not applied (genlocale missing or file unavailable); continuing."
    fi

    if config_get_bool '.Time.Ntp.Enabled' true; then
        ntp_result="$(time_apply_ntp)"
        case "$ntp_result" in
            '')          step_failed 'failed to enable time synchronization' ; return $? ;;
            skipped)     done_parts+=('ntp=skipped') ;;
            *)           done_parts+=("ntp=${ntp_result}") ;;
        esac
    else
        done_parts+=('ntp=disabled')
    fi

    step_ok "$(IFS=', '; echo "${done_parts[*]}")"
    return $?
}

time_apply_timezone() {
    local tz="$1"

    # Проверка по базе zoneinfo, а не на глаз: опечатка вроде Europe/Helsinky
    # прошла бы через timedatectl на части дистрибутивов и оставила машину в UTC.
    if [[ ! -f "/usr/share/zoneinfo/${tz}" ]]; then
        log_error "Timezone '${tz}' is missing from /usr/share/zoneinfo."
        return 1
    fi

    if [[ "$(cat /etc/timezone 2>/dev/null || true)" == "$tz" ]]; then
        log_debug "Timezone is already '${tz}'."
        return 0
    fi

    if run_has timedatectl; then
        run_cmd timedatectl set-timezone "$tz" && return 0
        log_warn 'timedatectl failed; falling back to writing /etc/localtime directly.'
    fi

    fs_write '/etc/timezone' "${tz}"$'\n' 644 root:root
    run_cmd ln -sfn "/usr/share/zoneinfo/${tz}" /etc/localtime
}

time_apply_locale() {
    local locale="$1"

    if fs_is_file '/etc/default/locale' && [[ "$(fs_read /etc/default/locale)" == *"LANG=${locale}"* ]]; then
        log_debug "Locale is already ${locale}."
        return 0
    fi

    fs_write '/etc/default/locale' "LANG=${locale}"$'\n' 644 root:root

    if run_has locale-gen; then
        # Генерация доступна только для локалей из /etc/locale.gen; C.UTF-8 встроена
        # в glibc и генерации не требует, поэтому её пропускаем.
        if [[ "$locale" != C.UTF-8 && "$locale" != POSIX ]]; then
            fs_append_unique '/etc/locale.gen' "$locale UTF-8"
            run_quiet locale-gen || log_warn "locale-gen failed; locale '${locale}' may be unavailable."
        fi
    fi

    if run_has update-locale; then
        run_quiet update-locale "LANG=${locale}" || true
    fi

    return 0
}

# Возвращает имя включённого демона, 'skipped' или пустую строку при ошибке.
time_apply_ntp() {
    local preferred fallback use_chrony=false

    preferred="$(config_get '.Time.Ntp.Preferred' 'chrony')"
    # Статус, а не строка: см. комментарий в users.sh.
    if config_get_bool '.Time.Ntp.FallbackToTimesyncd' true; then fallback=true; else fallback=false; fi

    if [[ "$preferred" == chrony ]]; then
        if pkg_is_installed chrony || run_has chronyd; then
            use_chrony=true
        elif pkg_install chrony; then
            use_chrony=true
        fi
    fi

    if [[ "$use_chrony" == true ]]; then
        run_quiet systemctl enable chrony 2>/dev/null || run_quiet systemctl enable chronyd 2>/dev/null || true
        run_quiet systemctl restart chrony 2>/dev/null || run_quiet systemctl restart chronyd 2>/dev/null || true
        printf 'chrony'
        return 0
    fi

    if [[ "$preferred" == ntpd ]] && pkg_is_installed ntp; then
        run_quiet systemctl enable --now ntp || true
        printf 'ntpd'
        return 0
    fi

    if [[ "$fallback" == true ]] && run_has systemctl; then
        if run_quiet systemctl enable --now systemd-timesyncd; then
            printf 'systemd-timesyncd'
            return 0
        fi
    fi

    if [[ "$preferred" == systemd-timesyncd && "$fallback" != true ]]; then
        printf 'skipped'
        return 0
    fi

    printf ''
}
