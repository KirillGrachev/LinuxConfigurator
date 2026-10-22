#!/usr/bin/env bats
#
# Валидация конфигурации по схеме.
#
# Проверяется не "валидатор отвечает true/false", а что каждый класс ошибки
# распознаётся и что путь к полю в сообщении корректен: сообщение "$.Ssh.MaxAuthTries:
# значение 99 больше допустимого максимума 10" позволяет починить конфиг за секунды,
# а "config invalid" - нет.

setup() {
    load test_helper
    LCFG_SCHEMA="$LCFG_ROOT/config/config.schema.json"
    LCFG_VALIDATOR="$LCFG_ROOT/lib/config/validate-schema.jq"
}

# Прогоняет изменённый конфиг через валидатор.
# $1 - jq-выражение, $2 - исходный конфиг (необязательно)
validate_modified() {
    local filter="$1" source_cfg="${2:-$LCFG_ROOT/config/config.json}"
    jq "$filter" "$source_cfg" > /tmp/lcfg-validate-$$.json
    jq -f "$LCFG_VALIDATOR" --argjson config "$(cat /tmp/lcfg-validate-$$.json)" "$LCFG_SCHEMA"
}

@test "the shipped config.json passes validation" {
    run validate_modified '.'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.valid' <<< "$output")" = "true" ]
    [ "$(jq -r '.errorCount' <<< "$output")" = "0" ]
}

@test "a wrong value type is rejected" {
    run validate_modified '.General.StepDelaySeconds = "fast"'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("General.StepDelaySeconds.*expected type integer"))' <<< "$output" > /dev/null
}

@test "an out-of-range value is rejected" {
    run validate_modified '.Ssh.MaxAuthTries = 99'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("MaxAuthTries.*exceeds the allowed maximum"))' <<< "$output" > /dev/null
}

@test "a negative value is rejected" {
    run validate_modified '.Swap.SizeMegabytes = -5'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("below the allowed minimum"))' <<< "$output" > /dev/null
}

@test "a value outside the enum is rejected" {
    run validate_modified '.Ssh.PermitRootLogin = "maybe"'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("PermitRootLogin.*not in the allowed list"))' <<< "$output" > /dev/null
}

@test "all valid PermitRootLogin values are accepted" {
    local v
    for v in yes no prohibit-password without-password forced-commands-only; do
        run validate_modified ".Ssh.PermitRootLogin = \"$v\""
        [ "$(jq -r '.valid' <<< "$output")" = "true" ] || { echo "a valid value was rejected: $v"; return 1; }
    done
}

@test "a pattern violation is rejected with the pattern shown" {
    run validate_modified '.Updates.AutomaticRebootTime = "25:99"'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("AutomaticRebootTime.*does not match pattern"))' <<< "$output" > /dev/null
}

@test "an invalid hostname is rejected" {
    local bad
    for bad in 'bad host' 'host!' '-leading' 'trailing-' 'a.b'; do
        run validate_modified ".Hostname.Name = \"$bad\""
        [ "$(jq -r '.valid' <<< "$output")" = "false" ] || { echo "an invalid name was accepted: '$bad'"; return 1; }
    done
}

@test "a valid hostname is accepted" {
    local good
    for good in 'a' 'web-01' 'host01' 'a-b-c' 'ABC123'; do
        run validate_modified ".Hostname.Name = \"$good\""
        [ "$(jq -r '.valid' <<< "$output")" = "true" ] || { echo "a valid name was rejected: '$good'"; return 1; }
    done
}

@test "a port outside 1..65535 is rejected with the element index" {
    run validate_modified '.Firewall.AllowedTcpPorts = [22, 99999]'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    # Путь обязан указывать ИНДЕКС элемента, иначе в списке из 20 портов
    # невозможно понять, какой именно неверен.
    jq -e '.errors[] | select(test("AllowedTcpPorts\\[1\\]"))' <<< "$output" > /dev/null
}

@test "a missing required field in an array element is rejected" {
    run validate_modified '.Logrotate.Rules = [{"Rotate": 3}]'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("Logrotate.Rules\\[0\\].*required field .Path. is missing"))' <<< "$output" > /dev/null
}

@test "nested error paths are reported in full" {
    run validate_modified '.Time.Ntp.Preferred = "ntp4"'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(startswith("$.Time.Ntp.Preferred"))' <<< "$output" > /dev/null
}

@test "locales of all common formats are accepted" {
    local loc
    for loc in 'C' 'C.UTF-8' 'POSIX' 'en_US.UTF-8' 'ru_RU.UTF-8' 'en_US@euro'; do
        run validate_modified ".Time.Locale = \"$loc\""
        [ "$(jq -r '.valid' <<< "$output")" = "true" ] || { echo "a locale was rejected: $loc"; return 1; }
    done
}

@test "multiple errors are returned all at once" {
    run validate_modified '.Ssh.MaxAuthTries = 99 | .Swap.SizeMegabytes = -1 | .Hostname.Name = "bad host"'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    [ "$(jq -r '.errorCount' <<< "$output")" -ge 3 ] || { echo "$output"; return 1; }
}

@test "broken JSON is rejected with a clear message" {
    printf '{"Meta": {' > /tmp/lcfg-broken-$$.json
    run "$LCFG_BIN" --validate-config --config /tmp/lcfg-broken-$$.json
    rm -f /tmp/lcfg-broken-$$.json
    [ "$status" -eq 2 ]
    grep -q 'not valid JSON' <<< "$output" || { echo "$output"; return 1; }
}

@test "--validate-config returns 0 on a valid config" {
    run "$LCFG_BIN" --validate-config --config "$LCFG_ROOT/config/config.json"
    [ "$status" -eq 0 ]
    grep -q '\[OK\]' <<< "$output"
}

@test "--validate-config returns 2 on an invalid config" {
    jq '.Ssh.MaxAuthTries = 99' "$LCFG_ROOT/config/config.json" > /tmp/lcfg-invalid-$$.json
    run "$LCFG_BIN" --validate-config --config /tmp/lcfg-invalid-$$.json
    rm -f /tmp/lcfg-invalid-$$.json
    [ "$status" -eq 2 ]
    grep -q 'MaxAuthTries' <<< "$output"
}

@test "a warning about a placeholder Hostname.Name" {
    run "$LCFG_BIN" --validate-config --config "$LCFG_ROOT/config/config.json"
    # Штатный конфиг содержит changeme-host, и это должно быть видно сразу.
    grep -qi 'changeme-host\|placeholder' <<< "$output" || { echo "$output"; return 1; }
}

@test "a warning when PasswordAuthentication = true" {
    jq '.Ssh.PasswordAuthentication = true' "$LCFG_ROOT/config/config.json" > /tmp/lcfg-pw-$$.json
    run "$LCFG_BIN" --validate-config --config /tmp/lcfg-pw-$$.json
    rm -f /tmp/lcfg-pw-$$.json
    grep -q 'PasswordAuthentication' <<< "$output" || { echo "$output"; return 1; }
}

@test "a warning about an unknown step in DefaultSteps" {
    jq '.General.DefaultSteps = ["ssh", "no_such_step"]' "$LCFG_ROOT/config/config.json" > /tmp/lcfg-step-$$.json
    run "$LCFG_BIN" --validate-config --config /tmp/lcfg-step-$$.json
    rm -f /tmp/lcfg-step-$$.json
    grep -q 'no_such_step' <<< "$output" || { echo "$output"; return 1; }
}

@test "a warning when IsTestData = true" {
    jq '.Meta.IsTestData = true' "$LCFG_ROOT/config/config.json" > /tmp/lcfg-td-$$.json
    run "$LCFG_BIN" --validate-config --config /tmp/lcfg-td-$$.json
    rm -f /tmp/lcfg-td-$$.json
    grep -q 'IsTestData' <<< "$output" || { echo "$output"; return 1; }
}

@test "an unknown configuration field is not an error" {
    # additionalProperties намеренно не проверяется: конфиг должен переживать
    # появление новых полей в новой версии конфигуратора.
    run validate_modified '.MyOwnNote = "operator note"'
    [ "$(jq -r '.valid' <<< "$output")" = "true" ]
}
