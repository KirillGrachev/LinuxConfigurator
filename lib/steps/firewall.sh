#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг firewall: nftables-таблица с политикой drop на INPUT, безопасная для Docker.
#
# DESCRIPTION
#     Четыре решения, каждое из которых стоит сломанного сервера, если его не принять:
#
#     1. В конфигурации НЕТ `flush ruleset`. Docker владеет таблицами ip/ip6 nat и filter,
#        fail2ban владеет inet f2b-table. Стандартный /etc/nftables.conf из пакета
#        начинается с `flush ruleset`, и его включение сносит чужие таблицы: контейнеры
#        теряют сеть, fail2ban перестаёт банить. Шаг пересоздаёт ТОЛЬКО свою таблицу
#        (`table inet fw; delete table inet fw`), остальные не трогает.
#
#     2. Цепочка FORWARD не создаётся вовсе. Трафик в опубликованные порты контейнеров
#        идёт через DNAT в PREROUTING и далее через FORWARD, то есть мимо INPUT.
#        Поставив здесь policy drop на forward, можно полностью порвать сеть Docker.
#        Фильтрацией forwarded-трафика владеет сам Docker (цепочка DOCKER-USER).
#
#     3. DHCP разрешён явно (udp 67/68 в обе стороны). У облачных провайдеров публичный
#        адрес выдаётся по DHCP; заблокировав его, машина теряет адрес при следующем
#        продлении аренды и становится недоступной навсегда - уже без шанса починить
#        по сети.
#
#     4. Правила проверяются `nft -c -f` ДО применения, а до применения взводится
#        страховка через systemd-run. Синтаксическая ошибка в загруженном конфиге
#        оставила бы машину без фаервола при следующей загрузке.
#
#     Отдельная ловушка nft: пустой набор `elements = { }` - синтаксическая ошибка.
#     Для пустого множества строку elements не пишут вообще, и этот случай здесь
#     обрабатывается явно.
#
#     ProtectSshPort=true не даёт применить набор портов без порта sshd: это самая
#     частая причина самоблокировки при правке фаервола.

step_firewall() {
    if ! config_section_enabled Firewall; then
        step_skipped 'Firewall.Enabled = false'
        return $?
    fi

    if ! run_has nft; then
        step_skipped 'nft не установлен - шаг пропущен (установите nftables или используйте Docker.Enabled)'
        return $?
    fi

    local table conf_path include_dir ports_file ssh_port
    table="$(config_get '.Firewall.TableName' 'fw')"
    conf_path="$(config_get '.Firewall.ConfigPath' '/etc/nftables.conf')"
    include_dir="$(config_get '.Firewall.IncludeDir' '/etc/nftables.d')"
    ports_file="${include_dir}/allowed-tcp.txt"
    ssh_port="$(firewall_detect_ssh_port)"

    local -a tcp_ports=()
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] && tcp_ports+=("$line")
    done < <(config_get_array '.Firewall.AllowedTcpPorts')

    # Защита от самоблокировки: sshd-порт обязан быть открыт.
    if config_get_bool '.Firewall.ProtectSshPort' true; then
        local has_ssh=false p
        for p in ${tcp_ports[@]+"${tcp_ports[@]}"}; do
            [[ "$p" == "$ssh_port" ]] && has_ssh=true
        done
        if [[ "$has_ssh" != true ]]; then
            step_failed "Firewall.AllowedTcpPorts не содержит порт sshd (${ssh_port}) - applying policy drop отрезало бы доступ"
            return $?
        fi
    fi

    if ! confirm_step_action "$conf_path" "Включить nftables с policy drop (открыты: ${tcp_ports[*]:-нет})" High; then
        local rc=$?
        if (( rc == 2 )); then step_skipped '--what-if: фаервол не изменялся'; return $?; fi
        step_skipped 'пользователь отказался включать фаервол'
        return $?
    fi

    local backup_dir
    backup_dir="$(config_get '.Backup.DirectoryPath' '/var/backups/linuxconfigurator')/nftables-$(date '+%Y%m%d-%H%M%S')"
    firewall_backup "$conf_path" "$include_dir" "$backup_dir"

    local guard_sec
    guard_sec="$(config_get_int '.Firewall.RollbackGuardSeconds' 180)"
    firewall_arm_guard "$guard_sec" "$conf_path" "$include_dir" "$backup_dir"

    fs_ensure_dir "$include_dir" 755
    firewall_write_ports_file "$ports_file" ${tcp_ports[@]+"${tcp_ports[@]}"}

    local -a udp_ports=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && udp_ports+=("$line")
    done < <(config_get_array '.Firewall.AllowedUdpPorts')

    # Порядок важен: include-файл с множествами должен существовать до проверки
    # основного конфига, иначе `nft -c -f` не найдёт @allowed_tcp.
    firewall_write_sets_file "$include_dir" "$table" \
        ${tcp_ports[@]+"${tcp_ports[@]}"} -- ${udp_ports[@]+"${udp_ports[@]}"}
    fs_write "$conf_path" "$(firewall_render_config "$table" "$include_dir")" 644 root:root

    # Синтаксическая проверка до применения.
    if ! run_quiet nft -c -f "$conf_path"; then
        firewall_revert "$conf_path" "$include_dir" "$backup_dir"
        step_failed "nft -c отклонил сгенерированную конфигурацию, выполнен откат"
        return $?
    fi

    if ! run_quiet nft -f "$conf_path"; then
        firewall_revert "$conf_path" "$include_dir" "$backup_dir"
        step_failed 'nft -f не смог применить правила, выполнен откат'
        return $?
    fi

    run_quiet systemctl enable nftables || true

    if ! firewall_verify "$table" "$ssh_port"; then
        firewall_revert "$conf_path" "$include_dir" "$backup_dir"
        step_failed 'проверка после применения не прошла, выполнен откат'
        return $?
    fi

    firewall_disarm_guard

    local extra=''
    if firewall_docker_present; then
        extra='; Docker-таблицы не затронуты, опубликованные порты контейнеров фильтруются через DOCKER-USER'
    fi

    step_ok "inet ${table} policy drop, открыто TCP: ${tcp_ports[*]}${extra}"
    return $?
}

firewall_detect_ssh_port() {
    local port=''
    if ! testmode_enabled; then
        port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
    fi
    if [[ -z "$port" ]]; then
        port="$(awk '/^[[:space:]]*Port[[:space:]]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
    fi
    printf '%s' "${port:-22}"
}

firewall_docker_present() {
    testmode_enabled && return 1
    nft list tables 2>/dev/null | grep -qE 'table (ip|ip6|inet) (nat|filter)$' && \
        command -v docker > /dev/null 2>&1
}

firewall_backup() {
    local conf_path="$1" include_dir="$2" backup_dir="$3"

    if testmode_enabled; then
        testmode_journal backup snapshot "$conf_path" "$backup_dir"
        return 0
    fi

    mkdir -p "$backup_dir" 2>/dev/null || true
    if [[ -f "$conf_path" ]]; then
        cp -a "$conf_path" "$backup_dir"/ 2>/dev/null || true
    fi
    if [[ -d "$include_dir" ]]; then
        cp -a "$include_dir" "$backup_dir"/include 2>/dev/null || true
    fi
}

firewall_arm_guard() {
    local guard_sec="$1"
    local conf_path="$2"
    local include_dir="$3"
    local backup_dir="$4"

    (( guard_sec > 0 )) || return 0

    local script='/usr/local/sbin/lcfg-fw-revert.sh'
    # Присваивание отделено от local: внутри шаблона есть $(basename), и
    # `local x="$(...)"` вернуло бы статус local, скрыв сбой подстановки.
    local content
    content="#!/bin/bash
# Автоматический откат фаервола, созданный LinuxConfigurator.
if [[ -d '${backup_dir}' ]]; then
    cp -a '${backup_dir}'/$(basename "$conf_path") '${conf_path}' 2>/dev/null || true
    [[ -d '${backup_dir}/include' ]] && cp -a '${backup_dir}/include/. '${include_dir}/' 2>/dev/null || true
fi
nft delete table inet $(config_get '.Firewall.TableName' 'fw') 2>/dev/null || true
systemctl restart nftables 2>/dev/null || true
"

    if testmode_enabled; then
        testmode_journal guard arm "$script" "on-active=${guard_sec}s"
        return 0
    fi

    printf '%s' "$content" > "$script"
    chmod 700 "$script"
    systemctl stop lcfg-fw-revert.timer > /dev/null 2>&1 || true
    systemd-run --on-active="$guard_sec" --unit=lcfg-fw-revert "$script" > /dev/null 2>&1 || {
        log_warn 'Страховку фаервола взвести не удалось - продолжаю без неё.'
        return 1
    }
    log_info "Страховка фаервола взведена: авто-откат через ${guard_sec} с."
}

firewall_disarm_guard() {
    if testmode_enabled; then
        testmode_journal guard disarm 'lcfg-fw-revert.timer'
        return 0
    fi
    systemctl stop lcfg-fw-revert.timer > /dev/null 2>&1 || true
    systemctl reset-failed lcfg-fw-revert.service lcfg-fw-revert.timer > /dev/null 2>&1 || true
    rm -f /usr/local/sbin/lcfg-fw-revert.sh
}

firewall_revert() {
    local conf_path="$1" include_dir="$2" backup_dir="$3"
    log_warn "Откатываю конфигурацию фаервола из ${backup_dir}."

    if testmode_enabled; then
        testmode_journal guard revert "$conf_path" "$backup_dir"
        firewall_disarm_guard
        return 0
    fi

    if [[ -f "${backup_dir}/$(basename "$conf_path")" ]]; then
        cp -a "${backup_dir}/$(basename "$conf_path")" "$conf_path" 2>/dev/null || true
    fi
    if [[ -d "${backup_dir}/include" ]]; then
        cp -a "${backup_dir}/include/." "${include_dir}/" 2>/dev/null || true
    fi
    nft delete table inet "$(config_get '.Firewall.TableName' 'fw')" > /dev/null 2>&1 || true
    firewall_disarm_guard
}

firewall_write_ports_file() {
    local ports_file="$1"
    shift
    local content='# Managed by LinuxConfigurator: открытые TCP-порты, по одному в строке.
# Файл читается шагом firewall при каждом прогоне и преобразуется в nft-set.
'
    local p
    for p in "$@"; do
        content+="${p}"$'\n'
    done
    fs_write "$ports_file" "$content" 644 root:root
}

# Собирает /etc/nftables.conf. Множества портов вынесены в отдельный файл из
# include_dir, чтобы их можно было править без перегенерации основного конфига.
firewall_render_config() {
    local table="$1" include_dir="$2"
    local policy iface_line='' log_rule=''

    policy="$(config_get '.Firewall.InputPolicy' 'drop')"

    local -a tcp=() udp=()
    local line
    while IFS= read -r line; do [[ -n "$line" ]] && tcp+=("$line"); done < <(config_get_array '.Firewall.AllowedTcpPorts')
    while IFS= read -r line; do [[ -n "$line" ]] && udp+=("$line"); done < <(config_get_array '.Firewall.AllowedUdpPorts')

    # tcp/udp нужны только чтобы убедиться, что списки прочитаны; сами множества
    # портов генерирует firewall_write_sets_file.
    : "${#tcp[@]}" "${#udp[@]}"

    if config_get_bool '.Firewall.AllowContainerInterfaces' true; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            iface_line+="        iifname \"${line}\" accept"$'\n'
        done < <(config_get_array '.Firewall.ContainerInterfaceNames')
    fi

    if config_get_bool '.Firewall.LogDropped' true; then
        local prefix rate
        prefix="$(config_get '.Firewall.LogPrefix' 'nft-fw-drop: ')"
        rate="$(config_get_int '.Firewall.LogRatePerMinute' 5)"
        log_rule="        limit rate ${rate}/minute log prefix \"${prefix}\" level warn counter drop"
    fi

    local ssh_port rate burst
    ssh_port="$(firewall_detect_ssh_port)"
    rate="$(config_get_int '.Firewall.SshRateLimitPerMinute' 15)"
    burst="$(config_get_int '.Firewall.SshRateLimitBurst' 10)"

    cat <<EOF
#!/usr/sbin/nft -f
# Managed by LinuxConfigurator ${LCFG_VERSION} ($(date '+%Y-%m-%d'))
#
# ЗДЕСЬ НАМЕРЕННО НЕТ \`flush ruleset\`. Docker владеет таблицами ip/ip6 nat и filter,
# fail2ban - таблицей inet f2b-table. Глобальный flush снёс бы их и порвал сеть
# контейнеров. Файл пересоздаёт только таблицу inet ${table}.
#
# Область действия: только INPUT (сервисы самой машины). Трафик, который DNAT'ится
# в контейнеры, через INPUT не проходит - его ограничивают в цепочке DOCKER-USER.
# Цепочка FORWARD намеренно не объявлена: ею владеет Docker.

table inet ${table}
delete table inet ${table}

include "${include_dir}/*.nft"

table inet ${table} {

    chain input {
        type filter hook input priority filter; policy ${policy};

$(if config_get_bool '.Firewall.AllowLoopback' true; then
    printf '        iifname "lo" accept\n'
    printf '        iifname != "lo" ip daddr 127.0.0.0/8 drop\n'
    printf '        iifname != "lo" ip6 daddr ::1 drop\n'
fi)
$(if config_get_bool '.Firewall.AllowEstablished' true; then
    printf '        ct state established,related accept\n'
    printf '        ct state invalid counter drop\n'
fi)
${iface_line}$(if config_get_bool '.Firewall.AllowIcmp' true; then
    printf '        ip6 nexthdr icmpv6 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert,\n'
    printf '            nd-router-solicit, nd-router-advert } accept\n'
    printf '        ip6 nexthdr icmpv6 icmpv6 type { echo-request, echo-reply,\n'
    printf '            destination-unreachable, time-exceeded, parameter-problem,\n'
    printf '            packet-too-big } limit rate 20/second accept\n'
    printf '        ip protocol icmp icmp type { echo-reply, echo-request,\n'
    printf '            destination-unreachable, time-exceeded, parameter-problem }\n'
    printf '            limit rate 20/second accept\n'
fi)
$(if config_get_bool '.Firewall.AllowDhcp' true; then
    printf '        # DHCP: облачные провайдеры выдают публичный адрес по DHCP.\n'
    printf '        # Заблокировав эти порты, машина потеряет адрес при продлении аренды.\n'
    printf '        udp sport 67 udp dport 68 accept\n'
    printf '        udp sport 68 udp dport 67 accept\n'
fi)
        tcp dport @allowed_tcp ct state new limit rate ${rate}/minute burst ${burst} packets accept
        udp dport @allowed_udp ct state new limit rate 50/second accept
$(if [[ -n "$log_rule" ]]; then printf '%s\n' "$log_rule"; fi)
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

    # Множества портов пишутся отдельным файлом (см. firewall_write_sets_file),
    # который подключается через include выше. Здесь только чтение конфигурации.
    return 0
}

firewall_write_sets_file() {
    local include_dir="$1" table="$2"
    shift 2
    local -a tcp=() udp=()
    local mode='tcp' p

    # Аргументы: сначала TCP-порты, затем разделитель "--", затем UDP-порты.
    for p in "$@"; do
        if [[ "$p" == -- ]]; then mode='udp'; continue; fi
        [[ -n "$p" ]] || continue
        if [[ "$mode" == tcp ]]; then tcp+=("$p"); else udp+=("$p"); fi
    done

    local tcp_set='' udp_set=''
    # Пустое множество: строку elements писать НЕЛЬЗЯ - для nft это синтаксическая
    # ошибка ("unexpected '}'"). У множества без элементов просто нет этой строки.
    (( ${#tcp[@]} > 0 )) && tcp_set="        elements = { $(IFS=,; echo "${tcp[*]}") }"
    (( ${#udp[@]} > 0 )) && udp_set="        elements = { $(IFS=,; echo "${udp[*]}") }"

    local content="# Generated by LinuxConfigurator ${LCFG_VERSION}
# Множества открытых портов. Источник - Firewall.AllowedTcpPorts / AllowedUdpPorts
# в config.json; правки здесь будут перезаписаны при следующем прогоне.
table inet ${table} {
    set allowed_tcp {
        type inet_service
        flags interval
        comment \"public TCP ports\"
${tcp_set:+${tcp_set}
}    }
    set allowed_udp {
        type inet_service
        comment \"public UDP ports\"
${udp_set:+${udp_set}
}    }
}
"
    fs_write "${include_dir}/10-linuxconfigurator-ports.nft" "$content" 644 root:root
}

# Проверяет, что правила в ядре и ssh-порт достижим локально.
firewall_verify() {
    local table="$1" ssh_port="$2"

    if testmode_enabled; then
        testmode_journal command verify "nft list table inet ${table}" 'правила загружены'
        return 0
    fi

    if ! nft list table inet "$table" > /dev/null 2>&1; then
        log_error "Таблица inet ${table} не загрузилась в ядро."
        return 1
    fi

    if ! nft list chain inet "$table" input 2>/dev/null | grep -q "policy $(config_get '.Firewall.InputPolicy' 'drop')"; then
        log_error "Политика INPUT не соответствует ожидаемой."
        return 1
    fi

    # Локальное подключение к sshd: проверяет, что accept-правило для порта работает.
    if run_has nc; then
        if ! nc -z -w 5 127.0.0.1 "$ssh_port" > /dev/null 2>&1; then
            log_warn "Порт ${ssh_port} не отвечает локально (nc) - проверяю через /dev/tcp."
        fi
    fi
    if ! timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${ssh_port}" 2>/dev/null; then
        log_error "Порт sshd ${ssh_port} недоступен через loopback после применения правил."
        return 1
    fi

    # Docker не должен был пострадать.
    if firewall_docker_present; then
        if ! nft list tables 2>/dev/null | grep -q 'table ip filter'; then
            log_error 'Таблица Docker "ip filter" исчезла - правила задели чужие таблицы.'
            return 1
        fi
    fi

    log_debug "Проверка фаервола пройдена: таблица inet ${table}, порт ${ssh_port} доступен."
    return 0
}
