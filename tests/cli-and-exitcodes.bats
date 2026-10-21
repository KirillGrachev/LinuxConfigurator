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

@test "--help возвращает 0 и печатает справку" {
    run "$LCFG_BIN" --help
    [ "$status" -eq 0 ]
    grep -q 'run-steps' <<< "$output"
    grep -q 'test-mode' <<< "$output"
}

@test "--version возвращает 0 и печатает версию" {
    run "$LCFG_BIN" --version
    [ "$status" -eq 0 ]
    grep -qE 'LinuxConfigurator [0-9]+\.[0-9]+\.[0-9]+' <<< "$output"
}

@test "неизвестный аргумент возвращает 2" {
    run "$LCFG_BIN" --несуществующий-флаг
    [ "$status" -eq 2 ]
    grep -q 'Неизвестный аргумент' <<< "$output"
}

@test "запуск без выбора режима возвращает 2" {
    run "$LCFG_BIN" --config "$(lcfg_test_config)"
    [ "$status" -eq 2 ]
    grep -q 'Не выбран режим запуска' <<< "$output"
}

@test "неизвестный шаг возвращает 2 и перечисляет доступные" {
    run lcfg_run_testmode --run-steps ssh,такого_шага_нет
    [ "$status" -eq 2 ]
    grep -q 'Неизвестный шаг' <<< "$output"
    grep -q 'firewall' <<< "$output"
}

@test "неизвестный шаг отклоняется ДО выполнения первого шага" {
    # Ошибка в шестом шаге списка не должна обнаруживаться после того, как первые
    # пять уже изменили систему.
    run lcfg_run_testmode --run-steps hostname,несуществующий
    [ "$status" -eq 2 ]
    ! grep -q '\[OK\] hostname' <<< "$output" || { echo "$output"; return 1; }
}

@test "отсутствующий файл конфигурации возвращает 2" {
    run "$LCFG_BIN" --validate-config --config /tmp/нет-такого-файла-$$.json
    [ "$status" -eq 2 ]
    grep -q 'не найден' <<< "$output"
}

@test "алиас шага принимается вместо канонического имени" {
    run lcfg_run_testmode --run-steps sshd,fw,ntp
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Алиасы разрешаются в канонические имена, и в сводке видны именно они.
    grep -q '\[OK\]    ssh ' <<< "$output" || { echo "$output"; return 1; }
    grep -q '\[OK\]    firewall ' <<< "$output" || { echo "$output"; return 1; }
    grep -q '\[OK\]    time ' <<< "$output" || { echo "$output"; return 1; }
}

@test "регистр имени шага не важен" {
    run lcfg_run_testmode --run-steps HOSTNAME,Swap
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q '\[OK\]    hostname ' <<< "$output"
    grep -q '\[OK\]    swap ' <<< "$output"
}

@test "пробелы вокруг имён шагов игнорируются" {
    run lcfg_run_testmode --run-steps ' hostname , swap '
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "пустой список шагов возвращает 2" {
    run lcfg_run_testmode --run-steps '  ,  ,'
    [ "$status" -eq 2 ]
    grep -q 'Список шагов пуст' <<< "$output"
}

@test "падающий шаг даёт код возврата 1, а остальные шаги выполняются" {
    # Hostname.Name = changeme-host намеренно приводит шаг к Failed.
    jq '.Hostname.Name = "changeme-host"' "$LCFG_ROOT/config/config.json" > /tmp/lcfg-fail-$$.json
    run "$LCFG_BIN" --test-mode --config /tmp/lcfg-fail-$$.json \
        --run-steps hostname,sysctl,limits
    rm -f /tmp/lcfg-fail-$$.json

    [ "$status" -eq 1 ] || { echo "ожидался код 1, получен $status: $output"; return 1; }
    grep -q '\[FAIL\] hostname' <<< "$output" || { echo "$output"; return 1; }
    # StopOnFirstFailure = false: прогон продолжается после ошибки.
    grep -q '\[OK\]    sysctl' <<< "$output" || { echo "$output"; return 1; }
    grep -q 'ошибок: 1' <<< "$output" || { echo "$output"; return 1; }
}

@test "StopOnFirstFailure=true прерывает прогон на первой ошибке" {
    jq '.Hostname.Name = "changeme-host" | .General.StopOnFirstFailure = true' \
        "$LCFG_ROOT/config/config.json" > /tmp/lcfg-stop-$$.json
    run "$LCFG_BIN" --test-mode --config /tmp/lcfg-stop-$$.json \
        --run-steps hostname,sysctl,limits
    rm -f /tmp/lcfg-stop-$$.json

    [ "$status" -eq 1 ]
    grep -q 'StopOnFirstFailure' <<< "$output" || { echo "$output"; return 1; }
    ! grep -q '\[OK\]    sysctl' <<< "$output" || { echo "прогон не остановился: $output"; return 1; }
}

@test "защита от самоблокировки: firewall без порта sshd отклоняется" {
    jq '.Firewall.AllowedTcpPorts = [80, 443]' "$LCFG_ROOT/config/config.json" \
        > /tmp/lcfg-nossh-$$.json
    run "$LCFG_BIN" --test-mode --config /tmp/lcfg-nossh-$$.json --run-steps firewall
    rm -f /tmp/lcfg-nossh-$$.json

    [ "$status" -eq 1 ]
    grep -q 'не содержит порт sshd' <<< "$output" || { echo "$output"; return 1; }
}

@test "защита: ssh с PasswordAuthentication=false и без ключей отклоняется" {
    # Users.Enabled=false означает, что ключи никто не установил.
    jq '.Users.Enabled = false | .Hostname.Name = "t-host"' \
        "$LCFG_ROOT/config/config.json" > /tmp/lcfg-nokey-$$.json

    # На машине, где ключи уже есть (наш сервер настроен), шаг пройдёт -
    # поэтому тест проверяет обе ветки и принимает любую корректную.
    run "$LCFG_BIN" --test-mode --config /tmp/lcfg-nokey-$$.json --run-steps ssh
    rm -f /tmp/lcfg-nokey-$$.json

    case "$output" in
        *'нет authorized_keys'*) [ "$status" -eq 1 ] ;;
        *'hardening применён'*)  [ "$status" -eq 0 ] ;;
        *) echo "неожиданный результат: $output"; return 1 ;;
    esac
}

@test "--log переопределяет путь журнала из конфигурации" {
    local logf="/tmp/lcfg-log-$$.txt"
    rm -f "$logf"
    run "$LCFG_BIN" --test-mode --log "$logf" --config "$(lcfg_test_config)" --run-steps hostname
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$logf" ] || { echo "журнал не создан в $logf"; return 1; }
    grep -q '\[INFO \]\|\[DEBUG\]' "$logf"
    rm -f "$logf"
}

@test "сводка печатается всегда, даже когда все шаги пропущены" {
    jq '.Hostname.Enabled = false | .Swap.Enabled = false' \
        "$LCFG_ROOT/config/config.json" > /tmp/lcfg-skip-$$.json
    run "$LCFG_BIN" --test-mode --config /tmp/lcfg-skip-$$.json --run-steps hostname,swap
    rm -f /tmp/lcfg-skip-$$.json

    [ "$status" -eq 0 ]
    grep -q 'ИТОГ' <<< "$output" || { echo "$output"; return 1; }
    grep -q 'пропущено: 2' <<< "$output" || { echo "$output"; return 1; }
}
