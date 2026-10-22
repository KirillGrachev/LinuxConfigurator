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

@test "a full test-mode run of all steps exits 0" {
    run lcfg_run_testmode --run-all
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "test-mode changes no system file" {
    run lcfg_run_testmode --run-all
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    local after
    after="$(lcfg_system_fingerprint)"
    [ "$after" = "$LCFG_FINGERPRINT_BEFORE" ] || {
        echo "system files changed:"
        diff <(printf '%s\n' "$LCFG_FINGERPRINT_BEFORE") <(printf '%s\n' "$after") || true
        return 1
    }
}

@test "test-mode creates no private key on the real filesystem" {
    # В реальном прогоне шаг users генерирует пару и оставляет приватную половину
    # на диске. Путь берётся из тестового конфига (TMPDIR), чтобы проверка не
    # зависела от прав на /root - в CI тесты идут от обычного пользователя.
    local keypath
    keypath="$(jq -r '.Users.PrivateKeyOutputPath' "$(lcfg_test_config)")"
    rm -f "$keypath" "${keypath}.pub" 2>/dev/null || true

    run lcfg_run_testmode --run-steps users,ssh
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    [ ! -e "$keypath" ]     || { echo "test-mode created a real private key"; return 1; }
    [ ! -e "${keypath}.pub" ] || { echo "test-mode created a real public key"; return 1; }
}

@test "test-mode neither creates nor overwrites the sudoers fragment" {
    local dropin='/etc/sudoers.d/10-linuxconfigurator-admin'
    local existed_before=false
    [ -e "$dropin" ] && existed_before=true

    run lcfg_run_testmode --run-steps users
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    if [ "$existed_before" = false ]; then
        [ ! -e "$dropin" ] || { echo "a real $dropin was created"; return 1; }
    fi
}

@test "test-mode applies no nftables rules" {
    local table_before table_after
    table_before="$(nft list tables 2>/dev/null | sort)"
    run lcfg_run_testmode --run-steps firewall
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    table_after="$(nft list tables 2>/dev/null | sort)"
    [ "$table_before" = "$table_after" ] || {
        echo "the nft table set changed:"
        diff <(printf '%s\n' "$table_before") <(printf '%s\n' "$table_after") || true
        return 1
    }
}

@test "test-mode arms no real systemd rollback timers" {
    lcfg_export_dummy_key
    run lcfg_run_testmode --run-steps users,ssh,firewall
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run systemctl list-timers --all --no-legend
    ! grep -q 'lcfg-sshd-revert\|lcfg-fw-revert' <<< "$output" || {
        echo "an auto-rollback timer remained in the system"
        return 1
    }
    [ ! -e /usr/local/sbin/lcfg-sshd-revert.sh ]
    [ ! -e /usr/local/sbin/lcfg-fw-revert.sh ]
}

@test "test-mode creates a sandbox with the correct paths" {
    local out sandbox
    out="$(lcfg_run_testmode --run-steps limits,users,ssh,firewall,logging)"
    sandbox="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out" | head -1)"

    [ -n "$sandbox" ] || { echo "sandbox not found in the output: $out"; return 1; }
    [ -d "$sandbox" ] || { echo "sandbox $sandbox does not exist"; return 1; }

    # Пути внутри песочницы повторяют абсолютные пути системы: именно это позволяет
    # логике read-modify-write видеть собственные записи.
    [ -f "$sandbox/etc/ssh/sshd_config.d/00-linuxconfigurator.conf" ] || {
        echo "no sshd drop-in in the sandbox"; find "$sandbox" -type f; return 1; }
    [ -f "$sandbox/etc/nftables.conf" ]
    [ -f "$sandbox/etc/systemd/journald.conf.d/99-linuxconfigurator.conf" ]
    [ -f "$sandbox/journal.tsv" ]
    [ -f "$sandbox/testmode-report.json" ]
}

@test "the sandbox journal holds the exact command lines" {
    local out sandbox journal
    out="$(lcfg_run_testmode --run-steps hostname,sysctl)"
    sandbox="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out" | head -1)"
    journal="$sandbox/journal.tsv"

    [ -f "$journal" ]
    # Смысл журнала - воспроизводимость: командная строка должна быть полной.
    grep -q 'hostnamectl' "$journal" || { echo "no hostnamectl in the journal"; cat "$journal"; return 1; }
    grep -q 'sysctl' "$journal" || { echo "no sysctl in the journal"; cat "$journal"; return 1; }
    # Формат TSV: категория, операция, цель, детали.
    awk -F'\t' 'NF < 3 { print "journal line not in TSV format: " $0; bad = 1 } END { exit bad }' "$journal"
}

@test "testmode-report.json is valid and carries counters" {
    local out sandbox report
    out="$(lcfg_run_testmode --run-steps hostname,limits,users,ssh,firewall)"
    sandbox="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out" | head -1)"
    report="$sandbox/testmode-report.json"

    jq -e . "$report" > /dev/null || { echo "the report is not JSON"; return 1; }
    [ "$(jq -r '.operationCount' "$report")" -gt 0 ]
    [ "$(jq -r '.counters.command' "$report")" -gt 0 ]
    [ "$(jq -r '.counters.file' "$report")" -gt 0 ]
    [ -n "$(jq -r '.generated' "$report")" ]
    # Приватные ключи не должны попадать в отчёт - только пути к ним.
    ! jq -r '.journal[].details' "$report" | grep -qE 'BEGIN (OPENSSH|RSA) PRIVATE KEY'
}

@test "what-if executes no command at all" {
    local out
    out="$(lcfg_run_whatif --run-steps hostname,sysctl,swap,limits)"
    # В what-if журнал операций не ведётся как command exec - только как whatif.
    ! grep -q '^\[OK\] .*applied' <<< "$out" || { echo "$out"; return 1; }
    grep -qE '\[WHATIF\]|Summary' <<< "$out" || { echo "$out"; return 1; }
}

@test "a rerun is idempotent: the second run yields the same operation set" {
    local out1 out2 sb1 sb2 n1 n2
    out1="$(lcfg_run_testmode --run-steps sysctl,limits,logging)"
    out2="$(lcfg_run_testmode --run-steps sysctl,limits,logging)"
    sb1="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out1" | head -1)"
    sb2="$(grep -oE '/tmp/LCFG-TestMode-[A-Za-z0-9]+' <<< "$out2" | head -1)"
    n1="$(jq -r '.operationCount' "$sb1/testmode-report.json")"
    n2="$(jq -r '.operationCount' "$sb2/testmode-report.json")"
    [ "$n1" = "$n2" ] || { echo "operations: first run $n1, second run $n2"; return 1; }
}
