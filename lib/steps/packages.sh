#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг packages: установка и удаление пакетов по спискам для семейства ОС.
#
# DESCRIPTION
#     Списки разделены на Common (одинаковые имена во всех семействах) и
#     Debian/Rhel/Suse/Alpine, потому что имена пакетов расходятся: dnsutils против
#     bind-utils, iputils-ping против iputils, policycoreutils-python-utils только в RHEL.
#     Хранить один общий список и угадывать имена - значит получать падение на половине
#     парка машин.
#
#     Установка идёт одним вызовом на весь список, а не по пакету: разрешение
#     зависимостей - самая дорогая часть apt-get, и N отдельных вызовов на одноядерной
#     машине занимают минуты вместо секунд.
#
#     Уже установленные пакеты отсеиваются до вызова менеджера (см. pkg_install),
#     поэтому повторный прогон не тратит время и остаётся идемпотентным.
#
#     needrestart ставится в список Debian-пакетов намеренно: без него apt при
#     обновлении библиотек задаёт интерактивный вопрос "какие службы перезапустить",
#     и автоматический прогон зависает навсегда. Конфигурация needrestart
#     выставляется шагом updates.
#
#     Ошибка установки НЕ прерывает прогон целиком: шаг возвращает Failed с перечнем
#     неустановленных пакетов, а остальные шаги (ssh, firewall) важнее и должны
#     выполниться - иначе машина останется с открытым портом и паролем вместо
#     недостающего htop.

step_packages() {
    if ! config_section_enabled Packages; then
        step_skipped 'Packages.Enabled = false'
        return $?
    fi

    if ! pkg_supported; then
        step_skipped "пакетный менеджер не определён (семейство '$(pkg_family)')"
        return $?
    fi

    local family
    family="$(pkg_family)"

    local -a install_list=()
    local -a remove_list=()
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] && install_list+=("$line")
    done < <(pkg_names_for_family Install)

    while IFS= read -r line; do
        [[ -n "$line" ]] && remove_list+=("$line")
    done < <(pkg_names_for_family Remove)

    if (( ${#install_list[@]} == 0 && ${#remove_list[@]} == 0 )); then
        step_skipped "списки пакетов для семейства '${family}' пусты"
        return $?
    fi

    if ! confirm_step_action "пакетная база" "Установить ${#install_list[@]}, удалить ${#remove_list[@]} пакетов" Medium; then
        local rc=$?
        if (( rc == 2 )); then step_skipped '--what-if: пакеты не изменялись'; return $?; fi
        step_skipped 'пользователь отказался менять набор пакетов'
        return $?
    fi

    local -a failed=()
    local installed_count=0 removed_count=0

    if (( ${#remove_list[@]} > 0 )); then
        if pkg_remove "${remove_list[@]}"; then
            removed_count="${#remove_list[@]}"
        else
            log_warn "Не удалось удалить часть пакетов: ${remove_list[*]}"
        fi
    fi

    if (( ${#install_list[@]} > 0 )); then
        if pkg_install "${install_list[@]}"; then
            installed_count="${#install_list[@]}"
        else
            # Проверяем постфактум, какие пакеты всё-таки встали: менеджер мог
            # упасть на одном имени из списка, установив остальные.
            local name
            for name in "${install_list[@]}"; do
                if pkg_is_installed "$name"; then
                    ((installed_count++)) || true
                else
                    failed+=("$name")
                fi
            done
        fi
    fi

    if config_get_bool '.Packages.Autoremove' false; then
        pkg_autoremove || log_warn 'autoremove завершился ошибкой.'
    fi

    if (( ${#failed[@]} > 0 )); then
        step_failed "не установлены: ${failed[*]} (установлено ${installed_count}, удалено ${removed_count})"
        return $?
    fi

    step_ok "семейство ${family}: установлено ${installed_count}, удалено ${removed_count}"
    return $?
}
