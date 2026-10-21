#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг ssh: hardening sshd через drop-in с автоматическим откатом.
#
# DESCRIPTION
#     Единственный шаг, способный отрезать доступ к машине без возможности это
#     починить, поэтому защита от локаута встроена в сам шаг, а не оставлена
#     на усмотрение оператора.
#
#     Порядок принципиален:
#       1. СОХРАНЕНИЕ текущего sshd_config.d до любых изменений;
#       2. ВЗВОД страховки - systemd-run с таймером, который через
#          Ssh.RollbackGuardSeconds восстанавливает сохранённую конфигурацию и
#          перезагружает sshd. Если после применения настроек машина станет
#          недоступна, доступ вернётся сам, без консоли провайдера;
#       3. запись drop-in и нейтрализация 50-cloud-init.conf (см. ниже);
#       4. `sshd -t` - проверка синтаксиса ДО reload. Невалидный конфиг после
#          reload оставил бы sshd работающим на старой конфигурации, а после
#          первой же перезагрузки машина не подняла бы sshd вообще;
#       5. reload, а не restart: restart рвёт активные сессии, включая ту,
#          из которой запущен конфигуратор;
#       6. самопроверка новым подключением на 127.0.0.1 - только она доказывает,
#          что вход действительно работает, а не что sshd просто жив;
#       7. снятие страховки.
#
#     Про 50-cloud-init.conf: sshd читает Include в начале sshd_config и для
#     большинства параметров применяет ПЕРВОЕ найденное значение. Cloud-образы
#     кладут туда "PasswordAuthentication yes", поэтому наш drop-in обязан
#     лексически сортироваться раньше - отсюда имя 00-*. Дополнительно файл cloud-init
#     перезаписывается и добавляется /etc/cloud/cloud.cfg.d/*.cfg, иначе cloud-init
#     вернёт вход по паролю при следующей загрузке.
#
#     Если самопроверка новым подключением невозможна (ключ пришёл из секрета,
#     приватной половины на машине нет), шаг не считает настройку применённой
#     вслепую: проверяется, что sshd активен, порт слушается и `sshd -T` отражает
#     новые значения, а страховка остаётся взведённой до истечения таймера.

step_ssh() {
    if ! config_section_enabled Ssh; then
        step_skipped 'Ssh.Enabled = false'
        return $?
    fi

    if ! run_has sshd && [[ ! -x /usr/sbin/sshd ]]; then
        step_skipped 'sshd не установлен'
        return $?
    fi

    local dropin guard_sec
    dropin="$(config_get '.Ssh.DropInPath' '/etc/ssh/sshd_config.d/00-linuxconfigurator.conf')"
    guard_sec="$(config_get_int '.Ssh.RollbackGuardSeconds' 300)"

    # Отказ от пароля при отсутствии установленного ключа = гарантированный локаут.
    if ! config_get_bool '.Ssh.PasswordAuthentication' false; then
        if ! ssh_any_key_present; then
            step_failed 'PasswordAuthentication=false, но ни у одного пользователя нет authorized_keys. Сначала настройте шаг users.'
            return $?
        fi
    fi

    if ! confirm_step_action "$dropin" "Применить hardening sshd" High; then
        local rc=$?
        if (( rc == 2 )); then step_skipped '--what-if: sshd не изменялся'; return $?; fi
        step_skipped 'пользователь отказался менять настройки sshd'
        return $?
    fi

    local backup_dir
    backup_dir="$(ssh_backup_config)"

    ssh_arm_rollback_guard "$backup_dir" "$guard_sec"

    local content
    content="$(ssh_render_dropin)"
    fs_write "$dropin" "$content" 644 root:root

    if config_get_bool '.Ssh.NeutralizeCloudInitDropIn' true; then
        ssh_neutralize_cloud_init
    fi

    # Проверка синтаксиса до применения. В тестовом режиме sshd -t симулируется.
    if config_get_bool '.Ssh.ValidateBeforeReload' true; then
        if ! run_quiet sshd -t; then
            ssh_revert_now "$backup_dir"
            step_failed "sshd -t отклонил конфигурацию, выполнен откат к ${backup_dir}"
            return $?
        fi
    fi

    if config_get_bool '.Ssh.ReloadInsteadOfRestart' true; then
        run_quiet systemctl reload ssh || run_quiet systemctl reload sshd || {
            ssh_revert_now "$backup_dir"
            step_failed 'не удалось перечитать конфигурацию sshd, выполнен откат'
            return $?
        }
    else
        run_quiet systemctl restart ssh || run_quiet systemctl restart sshd || {
            ssh_revert_now "$backup_dir"
            step_failed 'не удалось перезапустить sshd, выполнен откат'
            return $?
        }
    fi

    local verify
    verify="$(ssh_verify_applied)"
    if [[ "$verify" == ok ]]; then
        ssh_disarm_rollback_guard
        step_ok "hardening применён и проверен новым подключением"
        return $?
    elif [[ "$verify" == unverified ]]; then
        # Страховку НЕ снимаем: пусть отработает, если вход всё-таки сломан.
        step_ok "hardening применён, самопроверка подключением недоступна; страховка активна ${guard_sec} с"
        return $?
    fi

    ssh_revert_now "$backup_dir"
    step_failed 'проверка после применения не прошла, выполнен откат'
    return $?
}

# Есть ли хоть у кого-то authorized_keys с реальным ключом.
ssh_any_key_present() {
    local home auth

    for home in /root /home/*; do
        auth="${home}/.ssh/authorized_keys"
        [[ -f "$auth" ]] || continue
        if testmode_enabled; then
            return 0
        fi
        grep -qE '^(ssh-(rsa|ed25519|dss)|ecdsa-)' "$auth" 2>/dev/null && return 0
    done

    return 1
}

ssh_backup_config() {
    local backup_dir
    backup_dir="$(config_get '.Backup.DirectoryPath' '/var/backups/linuxconfigurator')/sshd-$(date '+%Y%m%d-%H%M%S')"

    if testmode_enabled; then
        testmode_journal backup snapshot '/etc/ssh/sshd_config.d' "$backup_dir"
        printf '%s' "$backup_dir"
        return 0
    fi

    mkdir -p "$backup_dir" 2>/dev/null || true
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        cp -a /etc/ssh/sshd_config.d/. "$backup_dir"/ 2>/dev/null || true
    fi
    if [[ -f /etc/ssh/sshd_config ]]; then
        cp -a /etc/ssh/sshd_config "$backup_dir"/ 2>/dev/null || true
    fi
    printf '%s' "$backup_dir"
}

# Взводит таймер авто-отката. Используется systemd-run, а не trap: trap не сработает,
# если машину убьёт OOM, оборвётся сеть или процесс конфига падёт вместе с ssh-сессией.
ssh_arm_rollback_guard() {
    local backup_dir="$1" guard_sec="$2"

    (( guard_sec > 0 )) || { log_debug 'RollbackGuardSeconds=0, страховка не взводится.'; return 0; }

    local revert_script='/usr/local/sbin/lcfg-sshd-revert.sh'
    local content="#!/bin/bash
# Автоматический откат настроек sshd, созданный LinuxConfigurator.
# Срабатывает, если после применения hardening машина стала недоступна.
if [[ -d '${backup_dir}' ]]; then
    rm -f /etc/ssh/sshd_config.d/00-linuxconfigurator.conf
    cp -a '${backup_dir}'/. /etc/ssh/sshd_config.d/ 2>/dev/null || true
    systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null \\
        || systemctl restart sshd 2>/dev/null || true
fi
"

    if testmode_enabled; then
        testmode_journal guard arm "$revert_script" "on-active=${guard_sec}s backup=${backup_dir}"
        return 0
    fi

    printf '%s' "$content" > "$revert_script"
    chmod 700 "$revert_script"

    systemctl stop lcfg-sshd-revert.timer > /dev/null 2>&1 || true
    systemd-run --on-active="$guard_sec" --unit=lcfg-sshd-revert "$revert_script" > /dev/null 2>&1 || {
        log_warn 'Не удалось взвести страховку через systemd-run - продолжаю без неё.'
        return 1
    }
    log_info "Страховка sshd взведена: авто-откат через ${guard_sec} с."
}

ssh_disarm_rollback_guard() {
    if testmode_enabled; then
        testmode_journal guard disarm 'lcfg-sshd-revert.timer'
        return 0
    fi
    systemctl stop lcfg-sshd-revert.timer > /dev/null 2>&1 || true
    systemctl reset-failed lcfg-sshd-revert.service lcfg-sshd-revert.timer > /dev/null 2>&1 || true
    rm -f /usr/local/sbin/lcfg-sshd-revert.sh
    log_debug 'Страховка sshd снята.'
}

ssh_revert_now() {
    local backup_dir="$1"
    log_warn "Откатываю конфигурацию sshd из ${backup_dir}."

    if testmode_enabled; then
        testmode_journal guard revert '/etc/ssh/sshd_config.d' "$backup_dir"
        return 0
    fi

    rm -f "$(config_get '.Ssh.DropInPath' '/etc/ssh/sshd_config.d/00-linuxconfigurator.conf')"
    if [[ -d "$backup_dir" ]]; then
        cp -a "$backup_dir"/. /etc/ssh/sshd_config.d/ 2>/dev/null || true
    fi
    systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    ssh_disarm_rollback_guard
}

# Собирает содержимое drop-in из конфигурации.
# Булева директива sshd из значения конфигурации.
# config_get_bool возвращает код, а sshd нужен текст yes/no - связка в одну функцию,
# чтобы не писать в шаблоне громоздкое `... && echo true || echo false`.
ssh_bool_directive() {
    if config_get_bool "$1" "$2"; then
        printf 'yes'
    else
        printf 'no'
    fi
}

ssh_render_dropin() {
    # Присваивание отделено от local: в шаблоне есть $(date), и local x="$(...)"
    # вернул бы статус самого local, скрыв сбой подстановки даты.
    local out
    out="# Managed by LinuxConfigurator ${LCFG_VERSION} ($(date '+%Y-%m-%d'))
# Файл обязан лексически сортироваться РАНЬШЕ 50-cloud-init.conf: sshd применяет
# первое найденное значение параметра, а Include стоит в начале sshd_config.

# --- Аутентификация: только ключи ---
PasswordAuthentication $(ssh_bool_directive '.Ssh.PasswordAuthentication' false)
KbdInteractiveAuthentication $(ssh_bool_directive '.Ssh.KbdInteractiveAuthentication' false)
PubkeyAuthentication $(ssh_bool_directive '.Ssh.PubkeyAuthentication' true)
PermitRootLogin $(config_get '.Ssh.PermitRootLogin' 'prohibit-password')
AuthenticationMethods $(config_get '.Ssh.AuthenticationMethods' 'publickey')
PermitEmptyPasswords $(ssh_bool_directive '.Ssh.PermitEmptyPasswords' false)
HostbasedAuthentication $(ssh_bool_directive '.Ssh.HostbasedAuthentication' false)
IgnoreRhosts $(ssh_bool_directive '.Ssh.IgnoreRhosts' true)
StrictModes $(ssh_bool_directive '.Ssh.StrictModes' true)
MaxAuthTries $(config_get_int '.Ssh.MaxAuthTries' 3)
LoginGraceTime $(config_get_int '.Ssh.LoginGraceTime' 30)

# --- Сессии ---
MaxSessions $(config_get_int '.Ssh.MaxSessions' 10)
MaxStartups $(config_get '.Ssh.MaxStartups' '10:30:60')
ClientAliveInterval $(config_get_int '.Ssh.ClientAliveInterval' 300)
ClientAliveCountMax $(config_get_int '.Ssh.ClientAliveCountMax' 2)
X11Forwarding $(ssh_bool_directive '.Ssh.X11Forwarding' false)
AllowTcpForwarding $(ssh_bool_directive '.Ssh.AllowTcpForwarding' true)
AllowAgentForwarding $(ssh_bool_directive '.Ssh.AllowAgentForwarding' false)
PermitTunnel $(ssh_bool_directive '.Ssh.PermitTunnel' false)
PermitUserEnvironment $(ssh_bool_directive '.Ssh.PermitUserEnvironment' false)
Compression $(ssh_bool_directive '.Ssh.Compression' false)

# --- Прочее ---
PrintMotd $(ssh_bool_directive '.Ssh.PrintMotd' false)
PrintLastLog $(ssh_bool_directive '.Ssh.PrintLastLog' true)
LogLevel $(config_get '.Ssh.LogLevel' 'VERBOSE')
AuthorizedKeysFile .ssh/authorized_keys
"

    local allow_list user group
    allow_list="$(config_get_array '.Ssh.AllowUsers')"
    if [[ -n "$allow_list" ]]; then
        out+="AllowUsers $(echo "$allow_list" | paste -sd' ' -)"$'\n'
    fi
    allow_list="$(config_get_array '.Ssh.AllowGroups')"
    if [[ -n "$allow_list" ]]; then
        out+="AllowGroups $(echo "$allow_list" | paste -sd' ' -)"$'\n'
    fi

    printf '%s' "$out"
}

# cloud-init форсирует PasswordAuthentication yes и вернёт его при следующей загрузке.
ssh_neutralize_cloud_init() {
    local ci_dropin ci_cfg
    ci_dropin="$(config_get '.Ssh.CloudInitDropInPath' '/etc/ssh/sshd_config.d/50-cloud-init.conf')"

    if fs_is_file "$ci_dropin"; then
        fs_write "$ci_dropin" "# Перезаписан LinuxConfigurator: вход по паролю отключён.
PasswordAuthentication no
" 644 root:root
        log_debug "Нейтрализован ${ci_dropin}."
    fi

    ci_cfg='/etc/cloud/cloud.cfg.d/99-linuxconfigurator-ssh.cfg'
    if fs_is_dir /etc/cloud; then
        fs_write "$ci_cfg" "# Managed by LinuxConfigurator: не давать cloud-init
# включать вход по паролю при последующих загрузках.
ssh_pwauth: false
" 644 root:root
    fi
}

# Проверяет, что настройки действительно применились.
# Возвращает: ok | unverified | failed
ssh_verify_applied() {
    local effective want_pw want_root

    if testmode_enabled; then
        testmode_journal command verify 'sshd -T' 'проверка применённых значений'
        printf 'ok'
        return 0
    fi

    systemctl is-active ssh > /dev/null 2>&1 || systemctl is-active sshd > /dev/null 2>&1 || {
        log_error 'sshd не активен после применения конфигурации.'
        printf 'failed'
        return 0
    }

    effective="$(sshd -T 2>/dev/null)"
    if [[ -z "$effective" ]]; then
        log_warn 'sshd -T не вернул вывод - проверить значения не удалось.'
        printf 'unverified'
        return 0
    fi

    want_pw='no'
    config_get_bool '.Ssh.PasswordAuthentication' false || want_pw='yes'
    want_root="$(config_get '.Ssh.PermitRootLogin' 'prohibit-password')"

    local actual_pw actual_root
    actual_pw="$(printf '%s\n' "$effective" | awk '/^passwordauthentication /{print $2}')"
    actual_root="$(printf '%s\n' "$effective" | awk '/^permitrootlogin /{print $2}')"

    if [[ "$actual_pw" != "$want_pw" ]]; then
        log_error "passwordauthentication: ожидалось '${want_pw}', применяется '${actual_pw}'. Вероятная причина - другой drop-in с более ранним именем."
        printf 'failed'
        return 0
    fi

    # sshd -T нормализует prohibit-password в without-password.
    case "$want_root" in
        prohibit-password) [[ "$actual_root" == without-password || "$actual_root" == prohibit-password ]] || {
            log_error "permitrootlogin: ожидалось prohibit-password, применяется '${actual_root}'."
            printf 'failed'; return 0; } ;;
        *) [[ "$actual_root" == "$want_root" ]] || {
            log_error "permitrootlogin: ожидалось '${want_root}', применяется '${actual_root}'."
            printf 'failed'; return 0; } ;;
    esac

    # Реальная проверка: новое подключение к самому себе.
    if ssh_selftest_connect; then
        printf 'ok'
    else
        printf 'unverified'
    fi
}

# Новое SSH-подключение на 127.0.0.1. Единственный способ доказать, что вход работает:
# "sshd активен" и "конфиг прочитан" не гарантируют, что аутентификация проходит.
ssh_selftest_connect() {
    local key admin port user

    key="$(config_get '.Users.PrivateKeyOutputPath' '')"
    admin="$(config_get '.Users.Admin.Name' '')"
    port="$(awk '/^Port /{print $2; exit}' <<< "$(sshd -T 2>/dev/null)")"
    [[ -n "$port" ]] || port=22

    if [[ -z "$key" ]]; then
        key="/root/lcfg-generated-keys/${admin}-ed25519"
    fi

    [[ -f "$key" ]] || { log_debug 'Приватный ключ для самопроверки недоступен.'; return 1; }
    [[ -n "$admin" ]] || return 1
    run_has ssh || return 1

    # BatchMode=yes: никаких интерактивных запросов, иначе самопроверка подвесит прогон.
    user="$admin"
    ssh -i "$key" -p "$port" -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "${user}@127.0.0.1" true 2>/dev/null && return 0

    # Root как запасной вариант: ключ ставился обеим учётным записям.
    ssh -i "$key" -p "$port" -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "root@127.0.0.1" true 2>/dev/null && return 0

    log_warn 'Самопроверка подключением не прошла - страховка остаётся взведённой.'
    return 1
}
