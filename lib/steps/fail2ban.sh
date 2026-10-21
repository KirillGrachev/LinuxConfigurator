#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг fail2ban: установка и jail-конфигурация.
#
# DESCRIPTION
#     Работает в паре с шагом ssh: ssh отключает вход по паролю, а fail2ban закрывает
#     оставшийся вектор - перебор по словарю и flood на сам порт. Даже при аутентификации
#     по ключу публичный sshd получает сотни попыток в сутки, и без fail2ban весь этот
#     мусор остаётся в auth.log, размывая реальную картину.
#
#     Конфигурация пишется отдельным файлом в jail.d, а не правкой jail.conf: файл
#     пакета при обновлении заменяется (conffile), а drop-in переживает обновления.
#
#     Backend по умолчанию "auto", а не "systemd": systemd-backend требует python3-systemd,
#     которого может не оказаться, и jail тогда не стартует вовсе. "auto" сам выбирает
#     доступный источник (/var/log/auth.log при установленном rsyslog либо journald).
#
#     ignoreip обязательно содержит loopback: без него локальная самопроверка шага ssh
#     (подключение на 127.0.0.1) может быть расценена как неудачная попытка входа,
#     и конфигуратор сам себя забанит.

step_fail2ban() {
    if ! config_section_enabled Fail2ban; then
        step_skipped 'Fail2ban.Enabled = false'
        return $?
    fi

    if ! pkg_is_installed fail2ban && ! run_has fail2ban-client; then
        if config_get_bool '.Fail2ban.Install' true; then
            pkg_install fail2ban || {
                step_failed 'fail2ban не установился'
                return $?
            }
        else
            step_skipped 'fail2ban не установлен, Fail2ban.Install = false'
            return $?
        fi
    fi

    if ! run_has fail2ban-client; then
        step_skipped 'fail2ban-client недоступен'
        return $?
    fi

    local dropin backend
    dropin="$(config_get '.Fail2ban.JailDropInPath' '/etc/fail2ban/jail.d/linuxconfigurator.local')"
    backend="$(config_get '.Fail2ban.Backend' 'auto')"

    local content
    content="$(fail2ban_render_jails "$backend")"

    if ! confirm_step_action "$dropin" "Применить jail-конфигурацию fail2ban" Medium; then
        local rc=$?
        if (( rc == 2 )); then step_skipped '--what-if: fail2ban не изменялся'; return $?; fi
        step_skipped 'пользователь отказался менять настройки fail2ban'
        return $?
    fi

    fs_ensure_dir "$(dirname "$dropin")" 755
    fs_write "$dropin" "$content" 644 root:root

    run_quiet systemctl enable fail2ban || true
    if ! run_quiet systemctl restart fail2ban; then
        step_failed 'fail2ban не запустился после применения конфигурации'
        return $?
    fi

    # Небольшая задержка: fail2ban поднимает jail'ы асинхронно, и немедленный
    # status возвращает пустой список, который выглядит как ошибка.
    runtime_flag test_mode || sleep 2

    local banned=''
    if ! testmode_enabled; then
        banned="$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2}')"
    fi

    local jails
    jails="$(printf '%s' "$content" | grep -cE '^\[' || true)"
    step_ok "jail-секций: ${jails}, backend=${backend}, в бане: ${banned:-0}"
    return $?
}

# Собирает содержимое drop-in из Fail2ban.Jails (объект с произвольными именами jail'ов).
fail2ban_render_jails() {
    local backend="$1"
    local out def_ban def_find def_retry
    local jail

    def_ban="$(config_get '.Fail2ban.DefaultBanTime' '1h')"
    def_find="$(config_get '.Fail2ban.DefaultFindTime' '10m')"
    def_retry="$(config_get_int '.Fail2ban.DefaultMaxRetry' 3)"

    out="### Managed by LinuxConfigurator ${LCFG_VERSION}
### Источник: config.json -> Fail2ban. Правки здесь будут перезаписаны.

[DEFAULT]
bantime  = ${def_ban}
findtime = ${def_find}
maxretry = ${def_retry}
backend  = ${backend}
ignoreip = $(config_get_array '.Fail2ban.IgnoreIp' | paste -sd' ' -)
"

    while IFS= read -r jail; do
        [[ -n "$jail" ]] || continue

        if [[ "$(config_get ".Fail2ban.Jails.\"${jail}\".Enabled" true)" != true ]]; then
            continue
        fi

        out+=$'\n'"[${jail}]"$'\n'
        out+="enabled = true"$'\n'

        # Директивы пишутся только если заданы в конфигурации: пустое значение
        # в jail-файле fail2ban воспринимает как литерал, а не как "не задано".
        local key value
        for key in Mode Port LogPath MaxRetry FindTime BanTime; do
            value="$(fail2ban_jail_value "$jail" "$key")"
            [[ -n "$value" ]] && out+="$(fail2ban_directive_name "$key") = ${value}"$'\n'
        done
    done < <(printf '%s' "$(config_get_object '.Fail2ban.Jails')" | jq -r 'keys[]')

    printf '%s' "$out"
}

fail2ban_jail_value() {
    local jail="$1" key="$2"
    local value
    value="$(config_get ".Fail2ban.Jails.\"${jail}\".${key}" '')"
    if [[ -n "$value" ]]; then
        printf '%s' "$value"
        return 0
    fi
    # Наследование значений по умолчанию для общих параметров.
    case "$key" in
        MaxRetry) config_get_int '.Fail2ban.DefaultMaxRetry' 3 ;;
        FindTime) config_get '.Fail2ban.DefaultFindTime' '10m' ;;
        BanTime)  config_get '.Fail2ban.DefaultBanTime' '1h' ;;
        *)        printf '' ;;
    esac
}

# Имена в конфигурации - PascalCase (как весь config.json), в fail2ban - lowercase.
fail2ban_directive_name() {
    case "$1" in
        Mode)     printf 'mode' ;;
        Port)     printf 'port' ;;
        LogPath)  printf 'logpath' ;;
        MaxRetry) printf 'maxretry' ;;
        FindTime) printf 'findtime' ;;
        BanTime)  printf 'bantime' ;;
        *)        printf '%s' "${1,,}" ;;
    esac
}
