#!/usr/bin/env bash
#
# SYNOPSIS
#     Абстракция пакетного менеджера: apt, dnf, yum, zypper, apk.
#
# DESCRIPTION
#     Базовая настройка должна одинаково работать на Debian/Ubuntu и на RHEL-подобных,
#     поэтому имена пакетов в конфигурации задаются списками для каждого семейства
#     (Packages.Install.Debian / Packages.Install.Rhel), а выбор менеджера происходит
#     один раз при инициализации.
#
#     Команды идут через run_cmd, поэтому в тестовом режиме пакеты не устанавливаются,
#     а точные командные строки попадают в журнал и в отчёт.
#
#     Возвращаемые значения:
#       pkg_family  - debian | rhel | suse | alpine | unknown
#       pkg_is_installed - код 0, если пакет установлен

declare -g LCFG_PKG_FAMILY=''
declare -g LCFG_PKG_MANAGER=''
declare -g LCFG_PKG_UPDATED=false

pkg_detect() {
    if [[ -n "$LCFG_PKG_FAMILY" ]]; then
        printf '%s' "$LCFG_PKG_FAMILY"
        return 0
    fi

    if run_has apt-get; then
        LCFG_PKG_FAMILY='debian'; LCFG_PKG_MANAGER='apt-get'
    elif run_has dnf; then
        LCFG_PKG_FAMILY='rhel'; LCFG_PKG_MANAGER='dnf'
    elif run_has yum; then
        LCFG_PKG_FAMILY='rhel'; LCFG_PKG_MANAGER='yum'
    elif run_has zypper; then
        LCFG_PKG_FAMILY='suse'; LCFG_PKG_MANAGER='zypper'
    elif run_has apk; then
        LCFG_PKG_FAMILY='alpine'; LCFG_PKG_MANAGER='apk'
    else
        LCFG_PKG_FAMILY='unknown'; LCFG_PKG_MANAGER=''
    fi

    printf '%s' "$LCFG_PKG_FAMILY"
}

pkg_family() { pkg_detect > /dev/null; printf '%s' "$LCFG_PKG_FAMILY"; }

pkg_supported() {
    [[ -n "$(pkg_detect)" && "$LCFG_PKG_FAMILY" != unknown ]]
}

# Обновляет списки пакетов один раз за прогон: повторные вызовы из разных шагов
# не должны каждый раз тратить минуты на apt-get update.
pkg_update_index() {
    pkg_supported || return 0
    [[ "$LCFG_PKG_UPDATED" == true ]] && return 0

    case "$LCFG_PKG_FAMILY" in
        debian) run_quiet apt-get update -qq ;;
        rhel)   run_quiet "$LCFG_PKG_MANAGER" makecache -q ;;
        suse)   run_quiet zypper --non-interactive refresh ;;
        alpine) run_quiet apk update ;;
    esac

    LCFG_PKG_UPDATED=true
}

pkg_is_installed() {
    local name="$1"
    pkg_supported || return 1

    case "$LCFG_PKG_FAMILY" in
        debian) dpkg-query -W -f='${Status}' "$name" 2>/dev/null | grep -q 'install ok installed' ;;
        rhel)   rpm -q "$name" > /dev/null 2>&1 ;;
        suse)   rpm -q "$name" > /dev/null 2>&1 ;;
        alpine) apk info -e "$name" > /dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# Устанавливает пакеты. Уже установленные пропускаются, чтобы прогон оставался
# идемпотентным и не тратил время на повторное разрешение зависимостей.
pkg_install() {
    local -a wanted=()
    local name

    pkg_supported || { log_warn 'Пакетный менеджер не найден, установка пропущена.'; return 1; }

    for name in "$@"; do
        [[ -n "$name" ]] || continue
        if ! pkg_is_installed "$name"; then
            wanted+=("$name")
        fi
    done

    if (( ${#wanted[@]} == 0 )); then
        log_debug "Все пакеты уже установлены: $*"
        return 0
    fi

    pkg_update_index

    case "$LCFG_PKG_FAMILY" in
        debian)
            DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y -qq --no-install-recommends "${wanted[@]}"
            ;;
        rhel)   run_cmd "$LCFG_PKG_MANAGER" install -y -q "${wanted[@]}" ;;
        suse)   run_cmd zypper --non-interactive install --no-recommends -y "${wanted[@]}" ;;
        alpine) run_cmd apk add --no-cache "${wanted[@]}" ;;
    esac
}

pkg_remove() {
    local -a present=()
    local name

    pkg_supported || return 0

    for name in "$@"; do
        [[ -n "$name" ]] || continue
        pkg_is_installed "$name" && present+=("$name")
    done

    (( ${#present[@]} == 0 )) && return 0

    case "$LCFG_PKG_FAMILY" in
        debian) DEBIAN_FRONTEND=noninteractive run_cmd apt-get remove -y -qq --purge "${present[@]}" ;;
        rhel)   run_cmd "$LCFG_PKG_MANAGER" remove -y -q "${present[@]}" ;;
        suse)   run_cmd zypper --non-interactive remove -y "${present[@]}" ;;
        alpine) run_cmd apk del "${present[@]}" ;;
    esac
}

pkg_autoremove() {
    pkg_supported || return 0
    case "$LCFG_PKG_FAMILY" in
        debian) DEBIAN_FRONTEND=noninteractive run_quiet apt-get autoremove -y --purge ;;
        rhel)   run_quiet "$LCFG_PKG_MANAGER" autoremove -y ;;
        *)      return 0 ;;
    esac
}

# Возвращает имена пакетов из конфигурации для текущего семейства.
# Аргумент: Install | Remove
pkg_names_for_family() {
    local section="$1"
    local family_key
    case "$(pkg_family)" in
        debian) family_key='Debian' ;;
        rhel)   family_key='Rhel' ;;
        suse)   family_key='Suse' ;;
        alpine) family_key='Alpine' ;;
        *)      return 0 ;;
    esac

    config_get_array ".Packages.${section}.${family_key}"
    # Общие для всех семейств пакеты (Common) добавляются всегда.
    config_get_array ".Packages.${section}.Common"
}
