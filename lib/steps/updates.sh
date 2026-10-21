#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг updates: автоматические обновления безопасности, needrestart, старые ядра.
#
# DESCRIPTION
#     Три независимые проблемы, которые шаг закрывает вместе, потому что по отдельности
#     они не решаются:
#
#     1. unattended-upgrades установлен в образах Ubuntu/Debian, но ОТКЛЮЧЁН:
#        пакет есть, таймеры есть, а periodic-конфигурация пустая. Без явного
#        20auto-upgrades обновления безопасности не ставятся никогда.
#
#     2. needrestart в интерактивном режиме спрашивает "какие службы перезапустить"
#        и блокирует apt навсегда. В автоматическом прогоне (cron, CI, этот скрипт)
#        это гарантированный hang, поэтому режим ставится в 'a' (auto) отдельным
#        drop-in. Именно поэтому needrestart входит в список пакетов шага packages.
#
#     3. AutomaticReboot включает перезагрузку в заданное время. Без неё обновление
#        ядра накапливается, но не применяется: машина месяцами работает на старом
#        ядре с непатчеными CVE, а `uname -r` расходится с установленным.
#
#     AllowedOrigins хранится в конфигурации, а не зашивается: на Debian и Ubuntu
#     различаются и имена origin'ов, и наличие ESM-веток. Значения вида
#     "${distro_id}:${distro_codename}" подставляются самим unattended-upgrades,
#     поэтому в файле они обязаны остаться ЛИТЕРАЛОМ - path_expand_tokens здесь
#     намеренно не применяется.
#
#     Updates.UpgradeNow запускает полный dist-upgrade немедленно. По умолчанию
#     выключен: обновление ста пакетов на одноядерной машине занимает минуты,
#     и решать, делать ли это сейчас, должен оператор, а не конфигурация по умолчанию.

step_updates() {
    if ! config_section_enabled Updates; then
        step_skipped 'Updates.Enabled = false'
        return $?
    fi

    local family
    family="$(pkg_family)"

    if [[ "$family" != debian ]]; then
        step_skipped "unattended-upgrades настраивается для Debian/Ubuntu, обнаружено семейство '${family}'"
        return $?
    fi

    local -a done_parts=()

    updates_configure_needrestart && done_parts+=('needrestart=auto')

    if config_get_bool '.Updates.ConfigureUnattendedUpgrades' true; then
        if ! pkg_is_installed unattended-upgrades; then
            pkg_install unattended-upgrades || log_warn 'unattended-upgrades не установился.'
        fi

        if updates_write_periodic && updates_write_unattended; then
            done_parts+=('unattended-upgrades')
        else
            step_failed 'не удалось записать конфигурацию unattended-upgrades'
            return $?
        fi

        run_quiet systemctl enable unattended-upgrades || true
        run_quiet systemctl enable --now apt-daily.timer apt-daily-upgrade.timer || true
    fi

    if config_get_bool '.Updates.UpgradeNow' false; then
        if ! confirm_step_action 'пакетная база' 'Полный dist-upgrade сейчас (может занять минуты)' High; then
            local rc=$?
            if (( rc == 2 )); then done_parts+=('upgrade=whatif'); else done_parts+=('upgrade=отменён'); fi
        else
            log_info 'Запускаю dist-upgrade. На одноядерной машине это может занять несколько минут.'
            if updates_run_upgrade; then
                done_parts+=('upgrade=выполнен')
            else
                done_parts+=('upgrade=с ошибками')
            fi
        fi
    fi

    if config_get_bool '.Updates.PurgeOldKernels' true; then
        updates_purge_old_kernels "$(config_get_int '.Cleanup.KeepKernels' 2)" && done_parts+=('kernels=очищены')
    fi

    step_ok "$(IFS=', '; echo "${done_parts[*]}")"
    return $?
}

# needrestart: автоматический перезапуск служб вместо интерактивного вопроса.
updates_configure_needrestart() {
    local dir='/etc/needrestart/conf.d'
    local mode
    mode="$(config_get '.Updates.NeedrestartMode' 'a')"

    fs_ensure_dir "$dir" 755
    fs_write "${dir}/99-linuxconfigurator.conf" "# Managed by LinuxConfigurator ${LCFG_VERSION}
# Режим 'a' (auto): без него apt при обновлении библиотек задаёт интерактивный
# вопрос о перезапуске служб и автоматический прогон зависает навсегда.
# kernelhints=-1 убирает напоминание о перезагрузке из каждого вывода apt.
\$nrconf{restart} = '${mode}';
\$nrconf{kernelhints} = -1;
" 644 root:root
}

updates_write_periodic() {
    local list_interval='0' upgrade_interval='0' autoclean
    autoclean="$(config_get_int '.Updates.AutocleanIntervalDays' 7)"

    if config_get_bool '.Updates.UpdatePackageListsDaily' true; then list_interval='1'; fi
    if config_get_bool '.Updates.ConfigureUnattendedUpgrades' true; then upgrade_interval='1'; fi

    fs_write '/etc/apt/apt.conf.d/20auto-upgrades' "APT::Periodic::Update-Package-Lists \"${list_interval}\";
APT::Periodic::Unattended-Upgrade \"${upgrade_interval}\";
APT::Periodic::AutocleanInterval \"${autoclean}\";
" 644 root:root
}

updates_write_unattended() {
    local origins='' origin reboot reboot_time
    local remove_unused syslog_enable

    while IFS= read -r origin; do
        [[ -n "$origin" ]] || continue
        # Литерал: ${distro_id} раскрывает сам unattended-upgrades, не оболочка.
        origins+="    \"${origin}\";"$'\n'
    done < <(config_get_array '.Updates.AllowedOrigins')

    if [[ -z "$origins" ]]; then
        # Одинарные кавычки намеренно: ${distro_id} и ${distro_codename} раскрывает
        # сам unattended-upgrades при чтении своего конфига. Раскрытие их оболочкой
        # записало бы в файл уже подставленные значения текущего дистрибутива,
        # и конфиг перестал бы быть переносимым.
        # shellcheck disable=SC2016
        origins='    "${distro_id}:${distro_codename}-security";'$'\n'
    fi

    reboot='false'
    config_get_bool '.Updates.AutomaticReboot' true && reboot='true'
    reboot_time="$(config_get '.Updates.AutomaticRebootTime' '04:30')"

    remove_unused='false'
    config_get_bool '.Updates.RemoveUnusedDependencies' true && remove_unused='true'
    syslog_enable='false'
    config_get_bool '.Updates.SyslogEnable' true && syslog_enable='true'

    # Директива Mail пишется только при непустом адресе: `Mail "";` приводит
    # к предупреждению unattended-upgrades на каждом прогоне.
    local maintainer mail_directive=''
    maintainer="$(config_get '.Meta.Maintainer' '')"
    if [[ -n "$maintainer" ]]; then
        mail_directive="Unattended-Upgrade::Mail \"${maintainer}\";"$'\n'
    fi

    fs_write '/etc/apt/apt.conf.d/51linuxconfigurator' "# Managed by LinuxConfigurator ${LCFG_VERSION}
Unattended-Upgrade::Allowed-Origins {
${origins}};
Unattended-Upgrade::Remove-Unused-Dependencies \"${remove_unused}\";
Unattended-Upgrade::Automatic-Reboot \"${reboot}\";
Unattended-Upgrade::Automatic-Reboot-Time \"${reboot_time}\";
Unattended-Upgrade::SyslogEnable \"${syslog_enable}\";
${mail_directive}" 644 root:root
}

updates_run_upgrade() {
    # --force-confold: при конфликте конфигурационных файлов сохраняется действующий,
    # иначе dpkg задаёт интерактивный вопрос и прогон зависает.
    DEBIAN_FRONTEND=noninteractive run_cmd apt-get -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        --no-install-recommends dist-upgrade
}

# Удаляет старые ядра, оставляя N последних и НИКОГДА не трогая загруженное.
updates_purge_old_kernels() {
    local keep="$1"
    local running
    running="$(sys_kernel)"

    if testmode_enabled; then
        testmode_journal command purge-kernels 'autoremove --purge' "keep=${keep}, running=${running}"
        return 0
    fi

    # autoremove сам не удаляет ядро, которое помечено как установленное вручную
    # или является текущим; дополнительная защита - явная проверка имени.
    local -a installed=()
    local k

    while IFS= read -r k; do
        [[ -n "$k" ]] && installed+=("$k")
    done < <(dpkg -l 2>/dev/null | awk '/^ii  linux-image-[0-9]/{print $2}' | sed 's/^linux-image-//' | sort -V)

    if (( ${#installed[@]} <= keep )); then
        log_debug "Установлено ядер: ${#installed[@]}, порог ${keep} - удалять нечего."
        return 0
    fi

    run_quiet apt-get -y autoremove --purge || log_warn 'autoremove завершился ошибкой.'

    if ! dpkg -l "linux-image-${running}" > /dev/null 2>&1; then
        log_warn "Текущее ядро ${running} не найдено в списке пакетов - очистка ядер пропущена."
    fi
    return 0
}
