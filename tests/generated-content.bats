#!/usr/bin/env bats
#
# Содержимое генерируемых конфигурационных файлов.
#
# Здесь закреплены решения, каждое из которых стоит сломанного сервера. Тесты
# намеренно проверяют не "файл создан", а конкретные свойства содержимого:
# именно их нарушение приводит к потере сети, потере доступа или к незапускающемуся
# сервису при следующей загрузке.

setup() {
    load test_helper
    # Ключ экспортируется явно: тесты не должны зависеть от того, есть ли на
    # машине authorized_keys. Шаг users идёт первым, чтобы ssh увидел ключи.
    lcfg_export_dummy_key
    LCFG_OUT="$(lcfg_run_testmode --run-steps users,ssh,firewall,logging,limits,docker,motd)"
    LCFG_SB="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$LCFG_OUT" | head -1)"
    [ -n "$LCFG_SB" ] || { echo "песочница не найдена: $LCFG_OUT"; false; }
}

@test "nftables.conf НЕ содержит flush ruleset" {
    # Глобальный flush сносит таблицы Docker (ip/ip6 nat и filter) и fail2ban
    # (inet f2b-table). Стандартный /etc/nftables.conf из пакета начинается именно
    # с него, и его слепое включение рвёт сеть контейнеров.
    local conf="$LCFG_SB/etc/nftables.conf"
    [ -f "$conf" ]
    # Проверяются только значимые строки: в самом файле есть поясняющий комментарий
    # "ЗДЕСЬ НАМЕРЕННО НЕТ flush ruleset", и grep по всему файлу давал ложное
    # срабатывание на тексте комментария.
    ! grep -vE '^[[:space:]]*#' "$conf" | grep -q 'flush[[:space:]]+ruleset' || {
        echo "в nftables.conf обнаружен flush ruleset - он уничтожит таблицы Docker и fail2ban"
        grep -vE '^[[:space:]]*#' "$conf" | grep -n 'flush'
        return 1
    }
}

@test "nftables пересоздаёт только свою таблицу" {
    local conf="$LCFG_SB/etc/nftables.conf"
    grep -q '^table inet fw$' "$conf"
    grep -q '^delete table inet fw$' "$conf"
    # Чужие таблицы не затрагиваются ни одной значимой строкой (комментарии,
    # объясняющие причину, упоминать их могут и должны).
    local code_only
    code_only="$(grep -vE '^[[:space:]]*#' "$conf")"
    ! grep -qE 'delete table (ip|ip6) (nat|filter)' <<< "$code_only"
    ! grep -q 'f2b-table' <<< "$code_only"
    # Наша таблица пересоздаётся парой table/delete table.
    grep -qE '^table inet fw$' <<< "$code_only"
    grep -qE '^delete table inet fw$' <<< "$code_only"
}

@test "nftables не объявляет цепочку forward" {
    # Трафик в опубликованные порты контейнеров идёт через FORWARD. Политика drop
    # в нашей таблице полностью порвала бы сеть Docker.
    local conf="$LCFG_SB/etc/nftables.conf"
    ! grep -q 'hook forward' "$conf" || {
        echo "объявлена цепочка forward - она конфликтует с Docker"
        return 1
    }
}

@test "nftables разрешает DHCP в обе стороны" {
    # Облачные провайдеры выдают публичный адрес по DHCP. Заблокировав 67/68,
    # машина теряет адрес при продлении аренды и становится недоступной навсегда.
    local conf="$LCFG_SB/etc/nftables.conf"
    grep -q 'udp sport 67 udp dport 68 accept' "$conf"
    grep -q 'udp sport 68 udp dport 67 accept' "$conf"
}

@test "nftables разрешает loopback и established" {
    local conf="$LCFG_SB/etc/nftables.conf"
    grep -q 'iifname "lo" accept' "$conf"
    grep -q 'ct state established,related accept' "$conf"
    grep -q 'ct state invalid counter drop' "$conf"
}

@test "nftables разрешает ICMP discovery (path MTU)" {
    # Без destination-unreachable и packet-too-big ломаются соединения через
    # туннели: пакеты большего размера молча теряются, а TCP висит до таймаута.
    local conf="$LCFG_SB/etc/nftables.conf"
    grep -q 'destination-unreachable' "$conf"
    grep -q 'packet-too-big' "$conf"
    # IPv6 neighbour discovery не ограничивается по скорости - иначе адрес
    # перестаёт определяться и машина выпадает из сети.
    grep -q 'nd-neighbor-solicit' "$conf"
}

@test "nftables включает rate limit на новые SSH-соединения" {
    local conf="$LCFG_SB/etc/nftables.conf"
    grep -qE 'tcp dport @allowed_tcp ct state new limit rate [0-9]+/minute burst [0-9]+ packets accept' "$conf"
}

@test "nftables логирует дропы с ограничением частоты" {
    # Без limit каждое сканирование порта забивает журнал тысячами строк.
    local conf="$LCFG_SB/etc/nftables.conf"
    grep -qE 'limit rate [0-9]+/minute log prefix' "$conf"
}

@test "пустое множество портов не порождает elements = { }" {
    # `elements = { }` - синтаксическая ошибка nft, из-за которой не загрузится
    # ВЕСЬ ruleset, а не только это множество.
    local ports="$LCFG_SB/etc/nftables.d/10-linuxconfigurator-ports.nft"
    ! grep -q 'elements = { *}' "$ports" || {
        echo "пустое множество записано как 'elements = { }' - nft это отклонит"
        return 1
    }
}

@test "сгенерированный nftables.conf проходит реальную проверку nft -c" {
    command -v nft >/dev/null || skip "nft не установлен"
    local tmp; tmp="$(mktemp -d)"
    cp -r "$LCFG_SB/etc/nftables.d" "$tmp/" 2>/dev/null || mkdir -p "$tmp/nftables.d"
    cp "$LCFG_SB/etc/nftables.d/"*.nft "$tmp/nftables.d/" 2>/dev/null || true
    sed "s|include \"/etc/nftables.d/\*.nft\"|include \"$tmp/nftables.d/*.nft\"|" \
        "$LCFG_SB/etc/nftables.conf" > "$tmp/nftables.conf"

    run nft -c -f "$tmp/nftables.conf"
    rm -rf "$tmp"
    # nft -c открывает netlink-сокет и требует CAP_NET_ADMIN: без прав проверка
    # невозможна в принципе, и это не ошибка сгенерированных правил.
    if grep -qiE 'operation not permitted|permission denied' <<< "$output"; then
        skip "nft -c требует CAP_NET_ADMIN"
    fi
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "sshd drop-in сортируется раньше 50-cloud-init.conf" {
    # sshd применяет ПЕРВОЕ найденное значение параметра, а Include стоит в начале
    # sshd_config. Файл 99-hardening.conf был бы перекрыт облачным 50-cloud-init.conf,
    # который форсирует PasswordAuthentication yes.
    local dropin="$LCFG_SB/etc/ssh/sshd_config.d/00-linuxconfigurator.conf"
    [ -f "$dropin" ]
    [[ "$(basename "$dropin")" < "50-cloud-init.conf" ]] || {
        echo "drop-in $(basename "$dropin") не перекрывает 50-cloud-init.conf"
        return 1
    }
}

@test "sshd drop-in проходит реальную проверку sshd -t" {
    command -v sshd >/dev/null || skip "sshd не установлен"
    # sshd -t требует каталог privilege separation и хост-ключи. На свежеустановленном
    # openssh-server, который ни разу не запускался, того и другого может не быть, и
    # падение в этом случае не связано с проверяемым конфигом. Создаём каталог, если
    # хватает прав, иначе честно пропускаем тест.
    if [ ! -d /run/sshd ]; then
        mkdir -p /run/sshd 2>/dev/null || skip "нет /run/sshd и прав его создать"
    fi

    run sshd -t -f "$LCFG_SB/etc/ssh/sshd_config.d/00-linuxconfigurator.conf"
    if grep -q 'Could not load host key' <<< "$output"; then
        skip "нет хост-ключей sshd"
    fi
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "sshd drop-in отключает вход по паролю и kbd-interactive" {
    local dropin="$LCFG_SB/etc/ssh/sshd_config.d/00-linuxconfigurator.conf"
    grep -q '^PasswordAuthentication no$' "$dropin"
    grep -q '^KbdInteractiveAuthentication no$' "$dropin"
    grep -q '^PermitRootLogin prohibit-password$' "$dropin"
    grep -q '^AuthenticationMethods publickey$' "$dropin"
}

@test "sshd drop-in ограничивает попытки и таймауты входа" {
    local dropin="$LCFG_SB/etc/ssh/sshd_config.d/00-linuxconfigurator.conf"
    grep -q '^MaxAuthTries 3$' "$dropin"
    grep -q '^LoginGraceTime 30$' "$dropin"
    grep -q '^ClientAliveInterval 300$' "$dropin"
    grep -q '^X11Forwarding no$' "$dropin"
    grep -q '^LogLevel VERBOSE$' "$dropin"
}

@test "cloud-init нейтрализован и не вернёт пароли при загрузке" {
    local ci="$LCFG_SB/etc/ssh/sshd_config.d/50-cloud-init.conf"
    local cfg="$LCFG_SB/etc/cloud/cloud.cfg.d/99-linuxconfigurator-ssh.cfg"
    [ -f "$ci" ] && grep -q '^PasswordAuthentication no$' "$ci"
    [ -f "$cfg" ] && grep -q '^ssh_pwauth: false$' "$cfg"
}

@test "sudoers-фрагмент проходит реальную проверку visudo" {
    command -v visudo >/dev/null || skip "visudo не установлен"
    local f="$LCFG_SB/etc/sudoers.d/10-linuxconfigurator-admin"
    [ -f "$f" ] || { echo "фрагмент не создан"; return 1; }
    # Синтаксическая ошибка в /etc/sudoers.d ломает sudo ЦЕЛИКОМ, включая
    # возможность это починить, поэтому проверка обязательна.
    run visudo -cf "$f"
    [ "$status" -eq 0 ] || { echo "$output"; cat "$f"; return 1; }
}

@test "journald drop-in ограничивает объём журнала" {
    local f="$LCFG_SB/etc/systemd/journald.conf.d/99-linuxconfigurator.conf"
    [ -f "$f" ]
    grep -q '^\[Journal\]$' "$f"
    grep -q '^SystemMaxUse=400M$' "$f"
    # Дублирование в syslog удваивает объём журнала на диске.
    grep -q '^ForwardToSyslog=false$' "$f"
}

@test "logrotate-конфиг проходит реальную проверку logrotate -d" {
    command -v logrotate >/dev/null || skip "logrotate не установлен"
    local f="$LCFG_SB/etc/logrotate.d/linuxconfigurator"
    [ -f "$f" ]
    run logrotate -d "$f"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "needrestart переведён в автоматический режим" {
    local f="$LCFG_SB/etc/needrestart/conf.d/99-linuxconfigurator.conf"
    run lcfg_run_testmode --run-steps updates
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local sb2; sb2="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$output" | head -1)"
    f="$sb2/etc/needrestart/conf.d/99-linuxconfigurator.conf"
    [ -f "$f" ] || { echo "drop-in needrestart не создан"; return 1; }
    # Без этого apt задаёт интерактивный вопрос и автоматический прогон виснет.
    grep -q "restart} = 'a'" "$f"
}

@test "unattended-upgrades: литералы distro_id не раскрыты оболочкой" {
    run lcfg_run_testmode --run-steps updates
    local sb2; sb2="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$output" | head -1)"
    local f="$sb2/etc/apt/apt.conf.d/51linuxconfigurator"
    [ -f "$f" ] || { echo "$output"; return 1; }
    # Значения ${distro_id} раскрывает сам unattended-upgrades. Если оболочка
    # раскроет их раньше, в файл попадут значения текущего дистрибутива
    # и конфиг перестанет быть переносимым.
    grep -q 'distro_id' "$f" || { echo "литералы раскрыты оболочкой:"; cat "$f"; return 1; }
}

@test "daemon.json является валидным JSON и содержит ротацию логов" {
    # Docker.Enabled и Docker.Install включаются в конфиге теста, а не берутся из
    # штатного: в штатном секция выключена, а без установленного docker шаг
    # завершился бы как Skipped. В тестовом режиме установка симулируется, поэтому
    # проверка не зависит от того, есть ли docker на хосте или на CI-раннере.
    local out sb2 f
    jq '.Docker.Enabled = true | .Docker.Install = true' "$(lcfg_test_config)" > /tmp/lcfg-dk-$$.json
    out="$("$LCFG_BIN" --test-mode --config /tmp/lcfg-dk-$$.json --run-steps docker 2>&1)"
    rm -f /tmp/lcfg-dk-$$.json
    sb2="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out" | head -1)"
    f="$sb2/etc/docker/daemon.json"
    [ -f "$f" ] || { echo "daemon.json не создан: $out"; return 1; }
    # Ошибка в daemon.json - это dockerd, который не стартует вовсе.
    jq -e . "$f" > /dev/null || { echo "daemon.json невалиден:"; cat "$f"; return 1; }
    [ "$(jq -r '."log-opts"."max-size"' "$f")" = "50m" ]
    [ "$(jq -r '."log-opts"."max-file"' "$f")" = "3" ]
    [ "$(jq -r '."userland-proxy"' "$f")" = "false" ]
}

@test "motd-скрипт синтаксически корректен и завершается кодом 0" {
    local out sb2 f
    out="$(lcfg_run_testmode --run-steps motd)"
    sb2="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out" | head -1)"
    f="$sb2/etc/update-motd.d/99-linuxconfigurator"
    [ -f "$f" ] || { echo "motd не создан: $out"; return 1; }
    # motd выполняется при КАЖДОМ входе: его падение видно всем и всегда.
    run bash -n "$f"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run sh "$f"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "motd содержит переменные, а не подставленные на момент настройки значения" {
    local out sb2 f
    out="$(lcfg_run_testmode --run-steps motd)"
    sb2="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out" | head -1)"
    f="$sb2/etc/update-motd.d/99-linuxconfigurator"
    # Если бы значения подставились при генерации, motd показывал бы состояние
    # машины на дату установки и врал бы с первого дня.
    grep -q '$(uname -r' "$f" || { echo "в motd подставлены статические значения"; return 1; }
    grep -q '$(hostname' "$f"
}

@test "лимиты заданы и для systemd, и для PAM" {
    local systemd_f="$LCFG_SB/etc/systemd/system.conf.d/99-linuxconfigurator.conf"
    local pam_f="$LCFG_SB/etc/security/limits.d/99-linuxconfigurator.conf"
    [ -f "$systemd_f" ] || { echo "нет drop-in systemd"; return 1; }
    [ -f "$pam_f" ] || { echo "нет drop-in PAM"; return 1; }
    grep -q '^DefaultLimitNOFILE=' "$systemd_f"
    grep -q '^\[Manager\]$' "$systemd_f"
    # PAM-лимиты на сервисы не действуют, и наоборот: нужны оба файла.
    grep -q 'soft nofile' "$pam_f"
    grep -q 'hard nofile' "$pam_f"
}

@test "sysctl drop-in содержит ключи и не содержит комментариев-значений" {
    local out sb2 f
    out="$(lcfg_run_testmode --run-steps sysctl)"
    sb2="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out" | head -1)"
    f="$sb2/etc/sysctl.d/99-linuxconfigurator.conf"
    [ -f "$f" ]
    grep -q '^vm.swappiness = ' "$f"
    grep -q '^fs.file-max = ' "$f"
    # Каждая непустая незакомментированная строка обязана быть парой key = value:
    # sysctl -p падает на строке без '=', и весь drop-in не применится.
    # В именах параметров sysctl встречаются дефисы (net.bridge.bridge-nf-call-iptables)
    # и слеши, поэтому класс символов шире, чем [a-z0-9._].
    local bad
    bad="$(grep -vE '^[[:space:]]*(#|$)' "$f" | grep -vE '^[A-Za-z0-9._/-]+ = ' || true)"
    [ -z "$bad" ] || { echo "строки не в формате 'key = value': $bad"; return 1; }
}
