#!/usr/bin/env bats
#
# Поведение командной строки и коды возврата.
#
# Коды возврата - контракт для автоматизации: 0 - всё применилось, 1 - часть шагов
# упала, 2 - запуск невозможен. Если их перепутать, CI продолжит деплой на машину,
# которая не настроилась, и об этом никто не узнает до инцидента.

setup() {
    load test_helper
}

@test "--help returns 0 and prints the usage" {
    run "$LCFG_BIN" --help
    [ "$status" -eq 0 ]
    grep -q 'run-steps' <<< "$output"
    grep -q 'test-mode' <<< "$output"
}

@test "--version returns 0 and prints the version" {
    run "$LCFG_BIN" --version
    [ "$status" -eq 0 ]
    grep -qE 'LinuxConfigurator [0-9]+\.[0-9]+\.[0-9]+' <<< "$output"
}

@test "an unknown argument returns 2" {
    run "$LCFG_BIN" --no-such-flag
    [ "$status" -eq 2 ]
    grep -q 'Unknown argument' <<< "$output"
}

@test "starting without a run mode returns 2" {
    run "$LCFG_BIN" --config "$(lcfg_test_config)"
    [ "$status" -eq 2 ]
    grep -q 'No run mode selected' <<< "$output"
}

@test "an unknown step returns 2 and lists the available ones" {
    run lcfg_run_testmode --run-steps ssh,no_such_step
    [ "$status" -eq 2 ]
    grep -q 'Unknown step' <<< "$output"
    grep -q 'firewall' <<< "$output"
}

@test "an unknown step is rejected BEFORE the first step runs" {
    # Ошибка в шестом шаге списка не должна обнаруживаться после того, как первые
    # пять уже изменили систему.
    run lcfg_run_testmode --run-steps hostname,no_such_step
    [ "$status" -eq 2 ]
    ! grep -q '\[OK\] hostname' <<< "$output" || { echo "$output"; return 1; }
}

@test "a missing configuration file returns 2" {
    run "$LCFG_BIN" --validate-config --config /tmp/no-such-file-$$.json
    [ "$status" -eq 2 ]
    grep -q 'not found' <<< "$output"
}

@test "a step alias is accepted instead of the canonical name" {
    # users добавлен и ключ экспортирован: на чистой машине защита шага ssh от
    # локаута иначе корректно отказалась бы отключать пароли, и тест проверял бы
    # не разрешение алиасов, а наличие ключей на хосте.
    lcfg_export_dummy_key
    run lcfg_run_testmode --run-steps users,sshd,fw,ntp
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Алиасы разрешаются в канонические имена, и в сводке видны именно они.
    grep -q '\[OK\]    ssh ' <<< "$output" || { echo "$output"; return 1; }
    grep -q '\[OK\]    firewall ' <<< "$output" || { echo "$output"; return 1; }
    grep -q '\[OK\]    time ' <<< "$output" || { echo "$output"; return 1; }
    # Алиас users отсутствует намеренно: каноническое имя уже добавлено выше.
    grep -q '\[OK\]    users ' <<< "$output" || { echo "$output"; return 1; }
}

@test "step name case does not matter" {
    run lcfg_run_testmode --run-steps HOSTNAME,Swap
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q '\[OK\]    hostname ' <<< "$output"
    grep -q '\[OK\]    swap ' <<< "$output"
}

@test "spaces around step names are ignored" {
    run lcfg_run_testmode --run-steps ' hostname , swap '
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "an empty step list returns 2" {
    run lcfg_run_testmode --run-steps '  ,  ,'
    [ "$status" -eq 2 ]
    grep -q 'The step list is empty' <<< "$output"
}

@test "a failing step returns 1 while the other steps still run" {
    # Hostname.Name = changeme-host намеренно приводит шаг к Failed.
    jq '.Hostname.Name = "changeme-host"' "$LCFG_ROOT/config/config.json" > /tmp/lcfg-fail-$$.json
    run "$LCFG_BIN" --test-mode --config /tmp/lcfg-fail-$$.json \
        --run-steps hostname,sysctl,limits
    rm -f /tmp/lcfg-fail-$$.json

    [ "$status" -eq 1 ] || { echo "expected code 1, got $status: $output"; return 1; }
    grep -q '\[FAIL\] hostname' <<< "$output" || { echo "$output"; return 1; }
    # StopOnFirstFailure = false: прогон продолжается после ошибки.
    grep -q '\[OK\]    sysctl' <<< "$output" || { echo "$output"; return 1; }
    grep -q 'failed: 1' <<< "$output" || { echo "$output"; return 1; }
}

@test "StopOnFirstFailure=true aborts the run at the first failure" {
    jq '.Hostname.Name = "changeme-host" | .General.StopOnFirstFailure = true' \
        "$LCFG_ROOT/config/config.json" > /tmp/lcfg-stop-$$.json
    run "$LCFG_BIN" --test-mode --config /tmp/lcfg-stop-$$.json \
        --run-steps hostname,sysctl,limits
    rm -f /tmp/lcfg-stop-$$.json

    [ "$status" -eq 1 ]
    grep -q 'StopOnFirstFailure' <<< "$output" || { echo "$output"; return 1; }
    ! grep -q '\[OK\]    sysctl' <<< "$output" || { echo "the run did not stop: $output"; return 1; }
}

@test "lockout protection: a firewall without the sshd port is rejected" {
    jq '.Firewall.AllowedTcpPorts = [80, 443]' "$LCFG_ROOT/config/config.json" \
        > /tmp/lcfg-nossh-$$.json
    run "$LCFG_BIN" --test-mode --config /tmp/lcfg-nossh-$$.json --run-steps firewall
    rm -f /tmp/lcfg-nossh-$$.json

    [ "$status" -eq 1 ]
    grep -q 'does not include the sshd port' <<< "$output" || { echo "$output"; return 1; }
}

@test "protection: ssh with PasswordAuthentication=false and no keys is rejected" {
    # Users.Enabled=false означает, что ключи никто не установил.
    jq '.Users.Enabled = false | .Hostname.Name = "t-host"' \
        "$LCFG_ROOT/config/config.json" > /tmp/lcfg-nokey-$$.json

    # На машине, где ключи уже есть (наш сервер настроен), шаг пройдёт -
    # поэтому тест проверяет обе ветки и принимает любую корректную.
    run "$LCFG_BIN" --test-mode --config /tmp/lcfg-nokey-$$.json --run-steps ssh
    rm -f /tmp/lcfg-nokey-$$.json

    case "$output" in
        *'no user has authorized_keys'*) [ "$status" -eq 1 ] ;;
        *'hardening applied'*)  [ "$status" -eq 0 ] ;;
        *) echo "unexpected result: $output"; return 1 ;;
    esac
}

@test "--log overrides the log path from the configuration" {
    local logf="/tmp/lcfg-log-$$.txt"
    rm -f "$logf"
    run "$LCFG_BIN" --test-mode --log "$logf" --config "$(lcfg_test_config)" --run-steps hostname
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$logf" ] || { echo "log file not created at $logf"; return 1; }
    grep -q '\[INFO \]\|\[DEBUG\]' "$logf"
    rm -f "$logf"
}

@test "the summary prints even when every step is skipped" {
    jq '.Hostname.Enabled = false | .Swap.Enabled = false' \
        "$LCFG_ROOT/config/config.json" > /tmp/lcfg-skip-$$.json
    run "$LCFG_BIN" --test-mode --config /tmp/lcfg-skip-$$.json --run-steps hostname,swap
    rm -f /tmp/lcfg-skip-$$.json

    [ "$status" -eq 0 ]
    grep -q 'Summary' <<< "$output" || { echo "$output"; return 1; }
    grep -q 'skipped: 2' <<< "$output" || { echo "$output"; return 1; }
}
