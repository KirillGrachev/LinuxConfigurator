#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг cleanup: autoremove, очистка кэша пакетов, вакуум журнала, временные файлы.
#
# DESCRIPTION
#     Запускается предпоследним, после всех шагов, которые могли что-то установить:
#     autoremove до установки пакетов удалил бы только что поставленные зависимости.
#
#     /boot требует отдельного внимания. На образах облачных провайдеров под /boot
#     выносится маленький раздел (часто 500 МБ - 1 ГБ), и каждое новое ядро занимает
#     около 100 МБ. Через несколько обновлений раздел заполняется, после чего
#     update-initramfs падает, а машина перестаёт загружаться с новым ядром -
#     причём проявляется это только при следующей перезагрузке, то есть в самый
#     неподходящий момент. Поэтому шаг сообщает о заполненности /boot, а не молчит.
#
#     Cleanup.RemoveTempFiles по умолчанию false: удаление содержимого /tmp на
#     работающей машине может сломать процессы, которые держат там сокеты или
#     lock-файлы. Включается только для провижининга "с нуля".
#
#     Собственные артефакты конфигуратора (страховки rollback, песочницы тестового
#     режима старше суток) удаляются всегда: они нужны только на время прогона.

step_cleanup() {
    if ! config_section_enabled Cleanup; then
        step_skipped 'Cleanup.Enabled = false'
        return $?
    fi

    local -a done_parts=()

    if config_get_bool '.Cleanup.Autoremove' true; then
        if pkg_autoremove; then
            done_parts+=('autoremove')
        else
            log_warn 'autoremove завершился ошибкой - продолжаю.'
        fi
    fi

    if config_get_bool '.Cleanup.AptClean' true && [[ "$(pkg_family)" == debian ]]; then
        run_quiet apt-get autoclean && done_parts+=('apt autoclean')
    fi

    local vacuum
    vacuum="$(config_get '.Cleanup.JournalVacuumSize' '400M')"
    if [[ -n "$vacuum" ]] && run_has journalctl; then
        if run_quiet journalctl --vacuum-size="$vacuum"; then
            done_parts+=("journal<=${vacuum}")
        fi
    fi

    if config_get_bool '.Cleanup.PurgeOldKernels' true; then
        cleanup_report_boot_usage && done_parts+=('/boot проверен')
    fi

    if config_get_bool '.Cleanup.RemoveTempFiles' false; then
        cleanup_temp_files && done_parts+=('tmp очищен')
    fi

    cleanup_own_artifacts
    done_parts+=('артефакты конфигуратора')

    if (( ${#done_parts[@]} == 0 )); then
        step_skipped 'нечего очищать'
        return $?
    fi

    step_ok "$(IFS=', '; echo "${done_parts[*]}")"
    return $?
}

# Сообщает о заполненности /boot: порог 80% - повод действовать, а не наблюдать.
cleanup_report_boot_usage() {
    local used_pct free_mb

    if ! testmode_enabled; then
        if ! mountpoint -q /boot 2>/dev/null; then
            log_debug '/boot не является отдельным разделом - контроль заполненности не нужен.'
            return 0
        fi
        used_pct="$(sys_disk_used_percent /boot)"
        free_mb="$(sys_disk_free_mb /boot)"
    else
        testmode_journal command check-boot '/boot' 'контроль заполненности'
        return 0
    fi

    if [[ -n "$used_pct" ]] && (( used_pct >= 80 )); then
        log_warn "/boot заполнен на ${used_pct}% (свободно ${free_mb} MiB). При следующем обновлении ядра раздел может переполниться, и update-initramfs упадёт."
        log_warn "Уменьшите Cleanup.KeepKernels или удалите старые linux-image-* вручную."
    else
        log_debug "/boot: занято ${used_pct:-?}%, свободно ${free_mb:-?} MiB."
    fi
    return 0
}

cleanup_temp_files() {
    if testmode_enabled; then
        testmode_journal command clean-tmp '/tmp' 'старше 7 дней'
        return 0
    fi
    # Только файлы старше 7 дней: свежее содержимое /tmp может принадлежать
    # работающим процессам (сокеты, lock-файлы, кэши сборки).
    find /tmp -mindepth 1 -maxdepth 1 -mtime +7 ! -name 'systemd-private-*' \
        -exec rm -rf {} + 2>/dev/null || true
    return 0
}

# Удаляет то, что конфигуратор создал для своей работы.
cleanup_own_artifacts() {
    if testmode_enabled; then
        testmode_journal command cleanup-own '/tmp/LCFG-TestMode-*' 'старше 24 часов'
        return 0
    fi

    # Песочницы тестового режима старше суток: текущая не трогается,
    # её путь известен и она ещё нужна для отчёта.
    local current=''
    current="$(testmode_sandbox)"
    local d
    for d in /tmp/LCFG-TestMode-*; do
        [[ -e "$d" ]] || continue
        [[ "$d" == "$current" ]] && continue
        find "$d" -maxdepth 0 -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
    done

    # Страховки rollback, которые не были сняты (прогон завершился аварийно).
    rm -f /usr/local/sbin/lcfg-sshd-revert.sh /usr/local/sbin/lcfg-fw-revert.sh 2>/dev/null || true
    systemctl reset-failed lcfg-sshd-revert.service lcfg-fw-revert.service > /dev/null 2>&1 || true
}
