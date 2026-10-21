#!/usr/bin/env bash
#
# SYNOPSIS
#     Факты о машине: ОС, ядро, ресурсы, виртуализация, признак ожидаемой перезагрузки.
#
# DESCRIPTION
#     Читает систему напрямую и одинаково работает в тестовом режиме: решения шагов
#     должны приниматься по РЕАЛЬНОМУ состоянию машины, иначе тестовый прогон пойдёт
#     по другим веткам и перестанет что-либо доказывать.
#
#     Значения кэшируются в переменных после первого обращения: os-release и meminfo
#     не меняются в течение прогона, а шаги опрашивают их многократно.

declare -g LCFG_SYS_CACHED=false
# OS_ID/OS_VERSION/OS_LIKE собираются для sys_os_pretty и для решений шагов
# по семейству дистрибутива; отдельных аксессоров для них нет намеренно -
# неиспользуемая публичная функция быстро перестаёт соответствовать реальности.
declare -g LCFG_SYS_OS_ID='' LCFG_SYS_OS_VERSION='' LCFG_SYS_OS_LIKE=''
declare -g LCFG_SYS_KERNEL='' LCFG_SYS_ARCH='' LCFG_SYS_VIRT=''
declare -g LCFG_SYS_MEM_MB=0 LCFG_SYS_SWAP_MB=0 LCFG_SYS_CPU=0
declare -g LCFG_SYS_HOSTNAME=''

sys_collect() {
    [[ "$LCFG_SYS_CACHED" == true ]] && return 0

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        LCFG_SYS_OS_ID="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
        LCFG_SYS_OS_VERSION="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
        LCFG_SYS_OS_LIKE="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
    else
        LCFG_SYS_OS_ID='unknown'
    fi

    LCFG_SYS_KERNEL="$(uname -r)"
    LCFG_SYS_ARCH="$(uname -m)"
    LCFG_SYS_HOSTNAME="$(hostname)"

    if command -v systemd-detect-virt > /dev/null 2>&1; then
        LCFG_SYS_VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
    else
        LCFG_SYS_VIRT='unknown'
    fi

    LCFG_SYS_MEM_MB="$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 ))"
    LCFG_SYS_SWAP_MB="$(( $(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 ))"
    LCFG_SYS_CPU="$(nproc 2>/dev/null || echo 1)"

    LCFG_SYS_CACHED=true
}

sys_kernel()     { sys_collect; printf '%s' "$LCFG_SYS_KERNEL"; }
sys_arch()       { sys_collect; printf '%s' "$LCFG_SYS_ARCH"; }
sys_virt()       { sys_collect; printf '%s' "$LCFG_SYS_VIRT"; }
sys_memory_mb()  { sys_collect; printf '%s' "$LCFG_SYS_MEM_MB"; }
sys_swap_mb()    { sys_collect; printf '%s' "$LCFG_SYS_SWAP_MB"; }
sys_cpu_count()  { sys_collect; printf '%s' "$LCFG_SYS_CPU"; }
sys_hostname()   { sys_collect; printf '%s' "$LCFG_SYS_HOSTNAME"; }

sys_os_pretty() {
    [[ -r /etc/os-release ]] || { printf 'unknown'; return 0; }
    # shellcheck disable=SC1091
    (. /etc/os-release && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")
}

# Признак того, что установлена более новая версия ядра, чем загружена,
# либо система сама просит перезагрузку.
sys_reboot_pending() {
    if [[ -f /var/run/reboot-required ]]; then
        printf 'reboot-required'
        return 0
    fi

    # Глоб вместо `ls -1`: ls печатает имена в столбик и ломается на именах
    # с пробелами, а незакрытый глоб оставляет литерал "/boot/vmlinuz-*",
    # который пришлось бы отсеивать отдельно.
    local newest=''
    newest="$(for f in /boot/vmlinuz-*; do
                  [[ -e "$f" ]] || continue
                  printf '%s\n' "${f#/boot/vmlinuz-}"
              done | sort -V | tail -1)"
    if [[ -n "$newest" && "$newest" != "$(sys_kernel)" ]]; then
        printf 'kernel %s -> %s' "$(sys_kernel)" "$newest"
        return 0
    fi

    printf ''
}

sys_disk_free_mb() {
    local mount="${1:-/}"
    df -Pm "$mount" 2>/dev/null | awk 'NR==2 {print $4}'
}

sys_disk_used_percent() {
    local mount="${1:-/}"
    df -P "$mount" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}'
}

# Однострочное описание машины - уходит в журнал и в итоговый отчёт.
sys_describe() {
    printf '%s | %s | kernel %s | %s vCPU | %s MiB RAM | %s MiB swap | virt=%s' \
        "$(sys_hostname)" "$(sys_os_pretty)" "$(sys_kernel)" \
        "$(sys_cpu_count)" "$(sys_memory_mb)" "$(sys_swap_mb)" "$(sys_virt)"
}
