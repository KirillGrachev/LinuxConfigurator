#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг limits: лимиты дескрипторов для systemd-юнитов и для PAM-сессий.
#
# DESCRIPTION
#     Две разные настройки, которые часто путают и из-за этого получают
#     "Too many open files" несмотря на якобы поднятый лимит:
#
#       1. DefaultLimitNOFILE в /etc/systemd/system.conf.d/ - действует на процессы,
#          запущенные systemd (то есть на все сервисы, включая Java-приложения);
#       2. /etc/security/limits.d/ - действует на процессы, вошедшие через PAM
#          (ssh-сессия, su, sudo), и на сервисы НЕ влияет вовсе.
#
#     Нужны обе: без первой сервис упрётся в 1024 дескриптора, без второй то же
#     самое произойдёт при запуске jar руками из ssh-сессии.
#
#     Изменение system.conf.d требует `systemctl daemon-reexec`, чтобы PID 1 перечитал
#     конфигурацию; без него новые лимиты получат только сервисы, запущенные после
#     перезагрузки. Шаг делает daemon-reexec явно - это дёшево и не рвёт сессии.
#
#     DefaultTasksMax задаётся строкой ("infinity") или числом: systemd принимает оба
#     варианта, поэтому значение передаётся как есть без приведения к int.

step_limits() {
    if ! config_section_enabled Limits; then
        step_skipped 'Limits.Enabled = false'
        return $?
    fi

    local -a applied=()
    local nofile soft hard scope

    nofile="$(config_get_int '.Limits.SystemdDefaultLimitNOFILE' 1048576)"
    soft="$(config_get_int '.Limits.Nofile.Soft' 65536)"
    hard="$(config_get_int '.Limits.Nofile.Hard' 65536)"
    scope="$(config_get '.Limits.Nofile.Scope' '*')"

    # systemd: DefaultLimitNOFILE + DefaultTasksMax
    if [[ -d /etc/systemd/system.conf.d ]] || fs_ensure_dir /etc/systemd/system.conf.d 755; then
        local systemd_dropin='/etc/systemd/system.conf.d/99-linuxconfigurator.conf'
        local tasks_max
        tasks_max="$(config_get '.Limits.SystemdDefaultTasksMax' 'infinity')"

        fs_write "$systemd_dropin" "# Managed by LinuxConfigurator ${LCFG_VERSION}
# Лимиты по умолчанию для всех юнитов. Требует daemon-reexec или перезагрузки.
[Manager]
DefaultLimitNOFILE=${nofile}
DefaultTasksMax=${tasks_max}
" 644 root:root
        applied+=("systemd:NOFILE=${nofile}")

        run_quiet systemctl daemon-reexec || log_warn 'systemctl daemon-reexec не выполнен - лимиты применятся после перезагрузки.'
    fi

    # PAM: limits.d
    local pam_dropin
    pam_dropin="$(config_get '.Limits.PamDropInPath' '/etc/security/limits.d/99-linuxconfigurator.conf')"
    if [[ -d /etc/security/limits.d ]] || fs_ensure_dir /etc/security/limits.d 755; then
        fs_write "$pam_dropin" "# Managed by LinuxConfigurator ${LCFG_VERSION}
# Действует на сессии через PAM (ssh, su, sudo). На systemd-сервисы НЕ влияет -
# для них есть DefaultLimitNOFILE в /etc/systemd/system.conf.d/.
# <домен> <тип> <элемент> <значение>
${scope} soft nofile ${soft}
${scope} hard nofile ${hard}
root soft nofile ${hard}
root hard nofile ${hard}
" 644 root:root
        applied+=("pam:nofile=${soft}/${hard}")
    else
        log_warn '/etc/security/limits.d отсутствует - PAM-лимиты не настроены.'
    fi

    if (( ${#applied[@]} == 0 )); then
        step_failed 'не удалось применить ни один лимит'
        return $?
    fi

    step_ok "$(IFS=', '; echo "${applied[*]}")"
    return $?
}
