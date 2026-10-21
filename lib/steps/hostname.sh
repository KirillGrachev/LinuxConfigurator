#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг hostname: имя машины и запись в /etc/hosts.
#
# DESCRIPTION
#     Имя машины влияет на всё, что пишется в журналы после этого момента, поэтому шаг
#     выполняется первым.
#
#     /etc/hosts правится обязательно: без записи 127.0.1.1 <имя> sudo на Debian/Ubuntu
#     тратит несколько секунд на безуспешное разрешение имени и печатает
#     "unable to resolve host", а часть сервисов (Postfix, некоторые Java-библиотеки,
#     определяющие каноническое имя) получает неожиданный результат.
#
#     Существующая строка 127.0.1.1 удаляется перед добавлением новой, а не дополняется:
#     иначе после переименования в hosts останутся две записи и разрешение имени
#     станет зависеть от порядка строк.
#
#     Старое имя сохраняется алиасом в той же строке (Hostname.KeepOldNameAsAlias),
#     чтобы мониторинг и скрипты, обращающиеся по прежнему имени, не сломались сразу.

step_hostname() {
    if ! config_section_enabled Hostname; then
        step_skipped 'Hostname.Enabled = false'
        return $?
    fi

    local want current hosts_path='/etc/hosts'
    want="$(config_get '.Hostname.Name' '')"
    current="$(sys_hostname)"

    if [[ -z "$want" ]]; then
        step_failed 'Hostname.Name не задан в конфигурации'
        return $?
    fi

    # Значение-заглушка из примера не должно молча стать именем боевой машины.
    if [[ "$want" == changeme-host || "$want" == localhost ]]; then
        step_failed "Hostname.Name = '${want}' похоже на заглушку, задайте реальное имя"
        return $?
    fi

    if [[ "$current" == "$want" ]]; then
        # Идемпотентность: повторный прогон не должен ничего менять,
        # но запись в /etc/hosts всё равно проверяется - её могло не быть.
        if hosts_has_entry "$hosts_path" "$want"; then
            step_ok "имя уже '${want}', /etc/hosts в порядке"
            return $?
        fi
        log_info "Имя уже '${want}', но в ${hosts_path} нет записи - добавляю."
    fi

    if confirm_step_action "$hosts_path" "Установить имя машины '${want}'" High; then
        :
    else
        local rc=$?
        if (( rc == 2 )); then step_skipped '--what-if: имя не менялось'; return $?; fi
        step_skipped 'пользователь отказался менять имя машины'
        return $?
    fi

    local aliases="$want"
    if config_get_bool '.Hostname.KeepOldNameAsAlias' true && [[ -n "$current" && "$current" != "$want" ]]; then
        aliases="${want} ${current}"
    fi

    if ! run_cmd hostnamectl set-hostname "$want"; then
        step_failed 'hostnamectl set-hostname завершился ошибкой'
        return $?
    fi

    if config_get_bool '.Hostname.UpdateHostsFile' true; then
        hosts_rewrite_loopback "$hosts_path" "$aliases" || {
            step_failed "не удалось обновить ${hosts_path}"
            return $?
        }
    fi

    step_ok "'${current}' -> '${want}'" "$(hostname)"
    return $?
}

# Проверяет, есть ли в /etc/hosts строка 127.0.1.1 с указанным именем.
hosts_has_entry() {
    local path="$1" name="$2"
    fs_is_file "$path" || return 1
    fs_read "$path" | awk -v n="$name" '
        $1 == "127.0.1.1" { for (i = 2; i <= NF; i++) if ($i == n) found = 1 }
        END { exit(found ? 0 : 1) }'
}

# Заменяет строку 127.0.1.1 на актуальную, сохраняя остальные записи без изменений.
hosts_rewrite_loopback() {
    local path="$1" aliases="$2"
    local current=''

    if fs_is_file "$path"; then
        current="$(fs_read "$path")"
    else
        current="127.0.0.1 localhost"$'\n'"::1 localhost ip6-localhost ip6-loopback"
    fi

    local updated
    updated="$(printf '%s\n' "$current" | awk -v a="$aliases" '
        $1 == "127.0.1.1" { next }
        { print }
        END { printf "127.0.1.1 %s\n", a }')"

    fs_write "$path" "${updated}"$'\n' 644 root:root
}
