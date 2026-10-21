#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг sysctl: drop-in с параметрами ядра и их немедленное применение.
#
# DESCRIPTION
#     Параметры пишутся отдельным файлом в /etc/sysctl.d/, а не правкой /etc/sysctl.conf:
#     drop-in переживает обновления дистрибутива (conffile может быть заменён),
#     его видно целиком и его удаление полностью откатывает шаг.
#
#     Применение идёт ПО КЛЮЧУ, а не одним `sysctl --system`. Причина: часть ключей
#     отсутствует в конкретном ядре или появляется только после загрузки модуля -
#     например, net.bridge.* существуют лишь при загруженном br_netfilter. Пакетное
#     применение либо падает целиком, либо печатает простыню ошибок, в которой не видно,
#     что реально применилось. Поключевое применение даёт точный счётчик
#     "применено N, пропущено M" и не роняет шаг из-за одного отсутствующего ключа.
#
#     Модуль br_netfilter подгружается заранее, если в списке есть net.bridge.*:
#     без него эти параметры недоступны, а они критичны для Docker - при
#     bridge-nf-call-iptables=1 трафик между контейнерами в одной сети уходит
#     в netfilter и ломается.
#
#     Значения в drop-in сортируются: файл диффится глазами и глазами же проверяется
#     при разборе инцидента, а порядок ключей в JSON-объекте не определён.

step_sysctl() {
    if ! config_section_enabled Sysctl; then
        step_skipped 'Sysctl.Enabled = false'
        return $?
    fi

    local drop_in values_json count
    drop_in="$(config_get '.Sysctl.DropInPath' '/etc/sysctl.d/99-linuxconfigurator.conf')"
    values_json="$(config_get_object '.Sysctl.Values')"
    count="$(printf '%s' "$values_json" | jq 'length')"

    if (( count == 0 )); then
        step_skipped 'Sysctl.Values пуст'
        return $?
    fi

    if ! run_has sysctl; then
        step_skipped 'sysctl отсутствует в системе'
        return $?
    fi

    sysctl_maybe_load_modules "$values_json"

    local header content
    header="# Managed by LinuxConfigurator ${LCFG_VERSION} ($(date '+%Y-%m-%d %H:%M:%S'))
# Источник: config.json -> Sysctl.Values. Правьте конфигурацию, а не этот файл:
# при следующем прогоне файл перезаписывается целиком."

    content="${header}"$'\n\n'
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || continue
        content+="${key} = ${value}"$'\n'
    done < <(printf '%s' "$values_json" | jq -r 'to_entries | sort_by(.key) | .[] | "\(.key)\t\(.value)"')

    if ! confirm_step_action "$drop_in" "Записать ${count} параметров ядра" Medium; then
        local rc=$?
        if (( rc == 2 )); then step_skipped '--what-if: параметры не записывались'; return $?; fi
        step_skipped 'пользователь отказался менять параметры ядра'
        return $?
    fi

    fs_write "$drop_in" "$content" 644 root:root

    if ! config_get_bool '.Sysctl.ApplyImmediately' true; then
        step_ok "записано ${count} параметров в ${drop_in} (применятся при загрузке)"
        return $?
    fi

    local applied=0 skipped=0 key value
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || continue
        if run_quiet sysctl -w "${key}=${value}"; then
            ((applied++)) || true
        else
            ((skipped++)) || true
            log_debug "Параметр ${key} не применился (нет в этом ядре или нужен модуль)."
        fi
    done < <(printf '%s' "$values_json" | jq -r 'to_entries | sort_by(.key) | .[] | "\(.key)\t\(.value)"')

    step_ok "записано ${count}, применено ${applied}, пропущено ${skipped}"
    return $?
}

# Подгружает модули, от которых зависит наличие параметров в /proc/sys.
sysctl_maybe_load_modules() {
    local values_json="$1"

    if printf '%s' "$values_json" | jq -e 'keys[] | select(startswith("net.bridge."))' > /dev/null 2>&1; then
        if [[ ! -d /proc/sys/net/bridge ]] && ! testmode_enabled; then
            run_quiet modprobe br_netfilter || log_debug 'br_netfilter не загрузился - параметры net.bridge.* будут пропущены.'
        fi
    fi

    if printf '%s' "$values_json" | jq -e 'keys[] | select(startswith("net.netfilter."))' > /dev/null 2>&1; then
        if [[ ! -d /proc/sys/net/netfilter ]] && ! testmode_enabled; then
            run_quiet modprobe nf_conntrack || true
        fi
    fi
}
