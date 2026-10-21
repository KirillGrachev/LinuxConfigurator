#!/usr/bin/env bats
#
# Изоляция тестового режима: главный тест проекта.
#
# TestMode существует ради одного обещания - "прогнать весь сценарий на живой машине
# без единого изменения". Если это обещание нарушается, инструмент становится опаснее
# отсутствия инструмента: оператор привыкает прогонять --test-mode на бою и однажды
# получает применённый ssh-hardening на машине, где ключ ещё не установлен.
#
# Проверяется тремя способами, потому что каждый ловит свой класс утечки:
#   1. отпечатки критичных конфигов до и после (ловит перезапись существующих файлов);
#   2. отсутствие новых файлов и каталогов по известным путям (ловит создание);
#   3. содержимое песочницы (ловит "логика прошла, но записала не туда").

setup() {
    load test_helper
    LCFG_FINGERPRINT_BEFORE="$(lcfg_system_fingerprint)"
    LCFG_SANDBOXES_BEFORE="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'LCFG-TestMode-*' | sort)"
}

@test "полный прогон всех шагов в test-mode завершается кодом 0" {
    run lcfg_run_testmode --run-all
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "test-mode не изменяет ни один системный файл" {
    run lcfg_run_testmode --run-all
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    local after
    after="$(lcfg_system_fingerprint)"
    [ "$after" = "$LCFG_FINGERPRINT_BEFORE" ] || {
        echo "системные файлы изменились:"
        diff <(printf '%s\n' "$LCFG_FINGERPRINT_BEFORE") <(printf '%s\n' "$after") || true
        return 1
    }
}

@test "test-mode не создаёт приватный ключ на настоящей ФС" {
    # В реальном прогоне шаг users генерирует пару и оставляет приватную половину
    # на диске. Путь берётся из тестового конфига (TMPDIR), чтобы проверка не
    # зависела от прав на /root - в CI тесты идут от обычного пользователя.
    local keypath
    keypath="$(jq -r '.Users.PrivateKeyOutputPath' "$(lcfg_test_config)")"
    rm -f "$keypath" "${keypath}.pub" 2>/dev/null || true

    run lcfg_run_testmode --run-steps users,ssh
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    [ ! -e "$keypath" ]     || { echo "test-mode создал реальный приватный ключ"; return 1; }
    [ ! -e "${keypath}.pub" ] || { echo "test-mode создал реальный публичный ключ"; return 1; }
}

@test "test-mode не создаёт и не перезаписывает sudoers-фрагмент" {
    local dropin='/etc/sudoers.d/10-linuxconfigurator-admin'
    local existed_before=false
    [ -e "$dropin" ] && existed_before=true

    run lcfg_run_testmode --run-steps users
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    if [ "$existed_before" = false ]; then
        [ ! -e "$dropin" ] || { echo "создан реальный $dropin"; return 1; }
    fi
}

@test "test-mode не применяет правила nftables" {
    local table_before table_after
    table_before="$(nft list tables 2>/dev/null | sort)"
    run lcfg_run_testmode --run-steps firewall
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    table_after="$(nft list tables 2>/dev/null | sort)"
    [ "$table_before" = "$table_after" ] || {
        echo "набор таблиц nft изменился:"
        diff <(printf '%s\n' "$table_before") <(printf '%s\n' "$table_after") || true
        return 1
    }
}

@test "test-mode не взводит реальных systemd-таймеров отката" {
    run lcfg_run_testmode --run-steps ssh,firewall
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run systemctl list-timers --all --no-legend
    ! grep -q 'lcfg-sshd-revert\|lcfg-fw-revert' <<< "$output" || {
        echo "в системе остался таймер авто-отката"
        return 1
    }
    [ ! -e /usr/local/sbin/lcfg-sshd-revert.sh ]
    [ ! -e /usr/local/sbin/lcfg-fw-revert.sh ]
}

@test "test-mode создаёт песочницу с правильными путями" {
    local out sandbox
    out="$(lcfg_run_testmode --run-steps limits,users,ssh,firewall,logging)"
    sandbox="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out" | head -1)"

    [ -n "$sandbox" ] || { echo "песочница не найдена в выводе: $out"; return 1; }
    [ -d "$sandbox" ] || { echo "песочница $sandbox не существует"; return 1; }

    # Пути внутри песочницы повторяют абсолютные пути системы: именно это позволяет
    # логике read-modify-write видеть собственные записи.
    [ -f "$sandbox/etc/ssh/sshd_config.d/00-linuxconfigurator.conf" ] || {
        echo "в песочнице нет sshd drop-in"; find "$sandbox" -type f; return 1; }
    [ -f "$sandbox/etc/nftables.conf" ]
    [ -f "$sandbox/etc/systemd/journald.conf.d/99-linuxconfigurator.conf" ]
    [ -f "$sandbox/journal.tsv" ]
    [ -f "$sandbox/testmode-report.json" ]
}

@test "журнал песочницы содержит точные командные строки" {
    local out sandbox journal
    out="$(lcfg_run_testmode --run-steps hostname,sysctl)"
    sandbox="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out" | head -1)"
    journal="$sandbox/journal.tsv"

    [ -f "$journal" ]
    # Смысл журнала - воспроизводимость: командная строка должна быть полной.
    grep -q 'hostnamectl' "$journal" || { echo "в журнале нет hostnamectl"; cat "$journal"; return 1; }
    grep -q 'sysctl' "$journal" || { echo "в журнале нет sysctl"; cat "$journal"; return 1; }
    # Формат TSV: категория, операция, цель, детали.
    awk -F'\t' 'NF < 3 { print "строка журнала не в формате TSV: " $0; bad = 1 } END { exit bad }' "$journal"
}

@test "testmode-report.json валиден и содержит счётчики" {
    local out sandbox report
    out="$(lcfg_run_testmode --run-steps hostname,limits,users,ssh,firewall)"
    sandbox="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out" | head -1)"
    report="$sandbox/testmode-report.json"

    jq -e . "$report" > /dev/null || { echo "отчёт не является JSON"; return 1; }
    [ "$(jq -r '.operationCount' "$report")" -gt 0 ]
    [ "$(jq -r '.counters.command' "$report")" -gt 0 ]
    [ "$(jq -r '.counters.file' "$report")" -gt 0 ]
    [ -n "$(jq -r '.generated' "$report")" ]
    # Приватные ключи не должны попадать в отчёт - только пути к ним.
    ! jq -r '.journal[].details' "$report" | grep -qE 'BEGIN (OPENSSH|RSA) PRIVATE KEY'
}

@test "what-if не выполняет ни одной команды" {
    local out
    out="$(lcfg_run_whatif --run-steps hostname,sysctl,swap,limits)"
    # В what-if журнал операций не ведётся как command exec - только как whatif.
    ! grep -q '^\[OK\] .*применён' <<< "$out" || { echo "$out"; return 1; }
    grep -qE '\[WHATIF\]|ИТОГ' <<< "$out" || { echo "$out"; return 1; }
}

@test "повторный прогон идемпотентен: второй запуск даёт тот же набор операций" {
    local out1 out2 sb1 sb2 n1 n2
    out1="$(lcfg_run_testmode --run-steps sysctl,limits,logging)"
    out2="$(lcfg_run_testmode --run-steps sysctl,limits,logging)"
    sb1="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out1" | head -1)"
    sb2="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out2" | head -1)"
    n1="$(jq -r '.operationCount' "$sb1/testmode-report.json")"
    n2="$(jq -r '.operationCount' "$sb2/testmode-report.json")"
    [ "$n1" = "$n2" ] || { echo "операций: первый прогон $n1, второй $n2"; return 1; }
}
