#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг users: администратор, группы, sudoers и SSH-ключи.
#
# DESCRIPTION
#     Шаг ОБЯЗАН выполняться до шага ssh: ssh отключает вход по паролю, и если к тому
#     моменту не создан пользователь с ключом, машина теряет единственный канал
#     управления. Порядок закреплён в реестре шагов и в General.DefaultSteps.
#
#     Три меры против потери доступа:
#       1. ключ ставится и администратору, и root - если с учётной записью что-то
#          пойдёт не так, остаётся второй вход;
#       2. sudoers-фрагмент сначала пишется во временный файл и проверяется
#          `visudo -cf`, и только валидный попадает в /etc/sudoers.d/. Синтаксическая
#          ошибка в sudoers.d ломает sudo целиком, включая возможность это починить,
#          поэтому проверка обязательна, а не желательна;
#       3. при отсутствии ключа в секрете он генерируется на машине, приватная половина
#          сохраняется в файл с правами 600. В консоль и в журнал печатается ПУТЬ
#          к файлу, но не содержимое: ключ не должен попасть ни в лог, ни в отчёт
#          тестового режима.
#
#     Значением секрета authorized_keys может быть как сам ключ ("ssh-ed25519 ..."),
#     так и путь к файлу с ключами - разбираются обе формы, чтобы не заставлять
#     передавать многострочное содержимое через переменную окружения.

step_users() {
    if ! config_section_enabled Users; then
        step_skipped 'Users.Enabled = false'
        return $?
    fi

    local name shell create_home
    name="$(config_get '.Users.Admin.Name' '')"

    if [[ -z "$name" ]]; then
        step_failed 'Users.Admin.Name не задан'
        return $?
    fi

    shell="$(config_get '.Users.Admin.Shell' '/bin/bash')"
    # config_get_bool возвращает СТАТУС, а не строку: присваивание через $(...)
    # дало бы пустое значение, и домашний каталог не создавался бы никогда.
    if config_get_bool '.Users.Admin.CreateHome' true; then create_home=true; else create_home=false; fi

    if ! confirm_step_action "пользователь ${name}" "Создать/настроить учётную запись и sudo" High; then
        local rc=$?
        if (( rc == 2 )); then step_skipped '--what-if: пользователи не изменялись'; return $?; fi
        step_skipped 'пользователь отказался менять учётные записи'
        return $?
    fi

    local -a done_parts=()
    local -a groups=()
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] && groups+=("$line")
    done < <(config_get_array '.Users.Admin.Groups')

    if users_ensure_account "$name" "$shell" "$create_home" "${groups[@]}"; then
        done_parts+=("user=${name}")
    else
        step_failed "не удалось создать или настроить пользователя '${name}'"
        return $?
    fi

    if config_get_bool '.Users.Admin.PasswordlessSudo' true; then
        if users_write_sudoers_dropin "$name"; then
            done_parts+=('sudo=nopasswd')
        else
            step_failed 'sudoers-фрагмент не прошёл проверку visudo и не установлен'
            return $?
        fi
    fi

    local key_report
    if key_report="$(users_install_keys "$name")"; then
        [[ -n "$key_report" ]] && done_parts+=("$key_report")
        # Флаг ставится ЗДЕСЬ, а не внутри users_install_keys: та вызывается через
        # $(...) ради возврата строки отчёта, то есть в подоболочке, и любые
        # изменения LCFG_VALUES в ней исчезают вместе с ней.
        #
        # Флаг читает шаг ssh. Его защита от локаута проверяет наличие ключей, а в
        # тестовом режиме users пишет их в песочницу, поэтому сканирование реальной
        # файловой системы ключей не видит. Без флага два шага одного прогона
        # расходились в представлениях о состоянии машины: users ключи «установил»,
        # а ssh считал, что их нет, и отказывался отключать вход по паролю. На уже
        # настроенной машине расхождение не проявлялось — там ключи лежат в
        # /root/.ssh/authorized_keys, — и поймать его удалось только на чистом стенде.
        if [[ -n "$key_report" ]]; then
            runtime_set_value users_keys_installed true
        fi
    else
        step_failed 'не удалось установить SSH-ключи'
        return $?
    fi

    step_ok "$(IFS=', '; echo "${done_parts[*]}")"
    return $?
}

# Отсеивает несуществующие группы: useradd -G с неизвестной группой падает,
# оставляя пользователя созданным наполовину.
users_filter_existing_groups() {
    local group
    USERS_VALID_GROUPS=()
    USERS_MISSING_GROUPS=()

    for group in "$@"; do
        [[ -n "$group" ]] || continue
        if getent group "$group" > /dev/null 2>&1; then
            USERS_VALID_GROUPS+=("$group")
        else
            USERS_MISSING_GROUPS+=("$group")
        fi
    done
}

users_ensure_account() {
    local name="$1" shell="$2" create_home="$3"
    shift 3
    local -a useradd_args=(-s "$shell")

    [[ "$create_home" == true ]] && useradd_args+=(-m)

    users_filter_existing_groups "$@"
    if (( ${#USERS_MISSING_GROUPS[@]} > 0 )); then
        log_warn "Группы не существуют и будут пропущены: ${USERS_MISSING_GROUPS[*]}"
    fi
    if (( ${#USERS_VALID_GROUPS[@]} > 0 )); then
        useradd_args+=(-G "$(IFS=,; echo "${USERS_VALID_GROUPS[*]}")")
    fi

    if id "$name" > /dev/null 2>&1; then
        log_debug "Пользователь '${name}' уже существует."
        local group
        for group in ${USERS_VALID_GROUPS[@]+"${USERS_VALID_GROUPS[@]}"}; do
            if ! id -nG "$name" 2>/dev/null | tr ' ' '\n' | grep -qxF "$group"; then
                run_quiet usermod -aG "$group" "$name" || log_warn "Не удалось добавить '${name}' в группу '${group}'."
            fi
        done
        return 0
    fi

    if run_cmd useradd "${useradd_args[@]}" "$name"; then
        log_info "Создан пользователь '${name}'."
        return 0
    fi

    log_error "useradd не смог создать пользователя '${name}'."
    return 1
}

# Пишет sudoers-фрагмент через временный файл с обязательной проверкой visudo.
users_write_sudoers_dropin() {
    local name="$1"
    local dropin tmp
    dropin="$(config_get '.Users.SudoersDropInPath' "/etc/sudoers.d/10-linuxconfigurator-${name}")"

    local content="# Managed by LinuxConfigurator ${LCFG_VERSION}
# Вход только по SSH-ключу, поэтому пароль для sudo не запрашивается.
# Удалите этот файл, если требуется запрашивать пароль.
Defaults env_reset
${name} ALL=(ALL:ALL) NOPASSWD:ALL
"

    tmp="${dropin}.tmp.$$"

    if testmode_enabled; then
        fs_write "$dropin" "$content" 440 root:root
        testmode_journal command validate "$tmp" "visudo -cf (симуляция)"
        return 0
    fi

    fs_ensure_dir "$(dirname "$dropin")" 750
    printf '%s' "$content" > "$tmp"
    chmod 440 "$tmp"

    if ! visudo -cf "$tmp" > /dev/null 2>&1; then
        log_error "Проверка visudo не прошла, фрагмент НЕ установлен:"
        visudo -cf "$tmp" 2>&1 | head -3 | while IFS= read -r l; do log_error "  ${l}"; done
        rm -f "$tmp"
        return 1
    fi

    # mv внутри одного каталога атомарен: sudo ни в какой момент не видит
    # наполовину записанный файл.
    mv -f "$tmp" "$dropin"
    chown root:root "$dropin" 2>/dev/null || true
    chmod 440 "$dropin"
    log_debug "Установлен ${dropin}"
    return 0
}

# Устанавливает authorized_keys администратору и root.
# Возвращает короткое описание для сводки ("keys=installed" или "keys=generated:<путь>").
users_install_keys() {
    local name="$1"
    local secret_name root_secret_name keys key_source='secret'
    local generated_path=''

    secret_init
    secret_name="$(config_get '.Users.AuthorizedKeysSecret' 'admin_authorized_keys')"
    root_secret_name="$(config_get '.Users.RootAuthorizedKeysSecret' '')"

    keys="$(secret_resolve "$secret_name" || true)"

    if [[ -z "$keys" ]] && config_get_bool '.Users.GenerateKeyIfSecretMissing' true; then
        generated_path="$(users_generate_keypair "$name")" || return 1
        keys="$(fs_read "${generated_path}.pub" 2>/dev/null || true)"
        key_source='generated'
    fi

    if [[ -z "$keys" ]]; then
        log_warn "Секрет '${secret_name}' пуст и генерация отключена - authorized_keys не изменялся."
        log_warn "ВНИМАНИЕ: если шаг ssh отключит вход по паролю, доступ останется только у root по существующим ключам."
        printf ''
        return 0
    fi

    # Значение секрета может быть путём к файлу - тогда читаем файл.
    if [[ ! "$keys" == ssh-* && ! "$keys" == ecdsa-* ]] && [[ -f "$keys" ]]; then
        keys="$(cat "$keys")"
    fi

    users_append_authorized_keys "/home/${name}" "$name" "$keys"
    users_append_authorized_keys "/root" "root" "$keys"

    if [[ -n "$root_secret_name" ]]; then
        local root_keys
        root_keys="$(secret_resolve "$root_secret_name" || true)"
        if [[ -n "$root_keys" ]]; then
            users_append_authorized_keys "/root" "root" "$root_keys"
        fi
    fi

    if [[ "$key_source" == generated ]]; then
        printf 'keys=generated:%s' "$generated_path"
    else
        printf 'keys=installed'
    fi
}

# Добавляет ключи в authorized_keys, не дублируя уже существующие.
users_append_authorized_keys() {
    local home="$1" owner="$2" keys="$3"
    local ssh_dir="${home}/.ssh"
    local auth="${ssh_dir}/authorized_keys"
    local existing='' added=0
    local line

    if testmode_enabled; then
        testmode_journal ssh-key install "$auth" "owner=${owner} keys=$(printf '%s\n' "$keys" | grep -c .)"
        return 0
    fi

    [[ -d "$home" ]] || { log_warn "Домашний каталог ${home} не существует - ключи для '${owner}' не установлены."; return 1; }

    install -d -m 700 -o "$owner" -g "$owner" "$ssh_dir" 2>/dev/null || {
        log_warn "Не удалось создать ${ssh_dir}."
        return 1
    }
    touch "$auth"
    existing="$(cat "$auth" 2>/dev/null || true)"

    while IFS= read -r line; do
        line="$(printf '%s' "$line" | sed -e 's/[[:space:]]*$//')"
        [[ -n "$line" ]] || continue
        [[ "$line" == \#* ]] && continue
        if ! printf '%s\n' "$existing" | grep -qxF -- "$line"; then
            printf '%s\n' "$line" >> "$auth"
            existing="${existing}"$'\n'"${line}"
            ((added++)) || true
        fi
    done <<< "$keys"

    chown -R "$owner:$owner" "$ssh_dir" 2>/dev/null || true
    chmod 700 "$ssh_dir"
    chmod 600 "$auth"
    log_debug "authorized_keys для '${owner}': добавлено ${added} ключ(ей)."
    return 0
}

# Генерирует ключевую пару на машине и возвращает путь к приватному ключу.
#
# Приватная половина никогда не печатается и не пишется в журнал: в консоль уходит
# только путь к файлу. Журнал конфигуратора попадает в отчёты и в testmode-report.json,
# а ключ в отчёте - это ключ в репозитории.
users_generate_keypair() {
    local name="$1"
    local out_dir out_path

    out_path="$(config_get '.Users.PrivateKeyOutputPath' '')"
    if [[ -z "$out_path" ]]; then
        out_dir="/root/lcfg-generated-keys"
        out_path="${out_dir}/${name}-ed25519"
    else
        out_dir="$(dirname "$out_path")"
    fi

    if ! run_has ssh-keygen; then
        log_error 'ssh-keygen не найден, сгенерировать ключ невозможно.'
        return 1
    fi

    if testmode_enabled; then
        testmode_journal ssh-key generate "$out_path" "ed25519, без пароля"
        # В песочницу кладётся образец публичного ключа: последующее чтение
        # "${out_path}.pub" в users_install_keys должно отработать так же, как
        # в реальном прогоне, иначе тест ушёл бы по ветке "ключей нет".
        fs_write "${out_path}.pub" \
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTMODEPLACEHOLDERKEYaaaaaaaaaaaa ${name}@testhost-lcfg"$'\n' \
            644 root:root
        printf '%s' "$out_path"
        return 0
    fi

    install -d -m 700 -o root -g root "$out_dir"

    if [[ -f "$out_path" ]]; then
        log_info "Ключ уже существует: ${out_path} - использую существующий."
    else
        # -a 100: число раундов KDF для ed25519. Значение по умолчанию (16)
        # перебирается заметно быстрее; 100 раундов стоят доли секунды при входе.
        if ! run_cmd ssh-keygen -t ed25519 -a 100 -N '' \
                 -C "${name}@$(hostname)-lcfg" -f "$out_path" -q; then
            log_error "ssh-keygen не смог создать ключ в ${out_path}."
            return 1
        fi
        chmod 600 "$out_path"
        chmod 644 "${out_path}.pub"
    fi

    console_warn "Сгенерирован приватный ключ: ${out_path}"
    console_warn "Заберите его на рабочую машину (scp) и удалите с сервера."
    printf '%s' "$out_path"
}
