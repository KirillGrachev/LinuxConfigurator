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

@test "штатный config.json проходит валидацию" {
    run validate_modified '.'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.valid' <<< "$output")" = "true" ]
    [ "$(jq -r '.errorCount' <<< "$output")" = "0" ]
}

@test "неверный тип значения отклоняется" {
    run validate_modified '.General.StepDelaySeconds = "быстро"'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("General.StepDelaySeconds.*ожидается тип integer"))' <<< "$output" > /dev/null
}

@test "выход за диапазон отклоняется" {
    run validate_modified '.Ssh.MaxAuthTries = 99'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("MaxAuthTries.*больше допустимого максимума"))' <<< "$output" > /dev/null
}

@test "отрицательное значение отклоняется" {
    run validate_modified '.Swap.SizeMegabytes = -5'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("меньше допустимого минимума"))' <<< "$output" > /dev/null
}

@test "значение вне enum отклоняется" {
    run validate_modified '.Ssh.PermitRootLogin = "возможно"'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("PermitRootLogin.*не входит в список"))' <<< "$output" > /dev/null
}

@test "все допустимые значения PermitRootLogin принимаются" {
    local v
    for v in yes no prohibit-password without-password forced-commands-only; do
        run validate_modified ".Ssh.PermitRootLogin = \"$v\""
        [ "$(jq -r '.valid' <<< "$output")" = "true" ] || { echo "отклонено допустимое значение: $v"; return 1; }
    done
}

@test "нарушение pattern отклоняется с указанием шаблона" {
    run validate_modified '.Updates.AutomaticRebootTime = "25:99"'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("AutomaticRebootTime.*не соответствует шаблону"))' <<< "$output" > /dev/null
}

@test "недопустимое имя хоста отклоняется" {
    local bad
    for bad in 'bad host' 'host!' '-leading' 'trailing-' 'a.b'; do
        run validate_modified ".Hostname.Name = \"$bad\""
        [ "$(jq -r '.valid' <<< "$output")" = "false" ] || { echo "принято недопустимое имя: '$bad'"; return 1; }
    done
}

@test "допустимое имя хоста принимается" {
    local good
    for good in 'a' 'fi-vmv3-pico' 'host01' 'a-b-c' 'ABC123'; do
        run validate_modified ".Hostname.Name = \"$good\""
        [ "$(jq -r '.valid' <<< "$output")" = "true" ] || { echo "отклонено допустимое имя: '$good'"; return 1; }
    done
}

@test "порт вне диапазона 1..65535 отклоняется с индексом элемента" {
    run validate_modified '.Firewall.AllowedTcpPorts = [22, 99999]'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    # Путь обязан указывать ИНДЕКС элемента, иначе в списке из 20 портов
    # невозможно понять, какой именно неверен.
    jq -e '.errors[] | select(test("AllowedTcpPorts\\[1\\]"))' <<< "$output" > /dev/null
}

@test "отсутствие обязательного поля в элементе массива отклоняется" {
    run validate_modified '.Logrotate.Rules = [{"Rotate": 3}]'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(test("Logrotate.Rules\\[0\\].*отсутствует обязательное поле .Path."))' <<< "$output" > /dev/null
}

@test "вложенные пути к ошибке указываются полностью" {
    run validate_modified '.Time.Ntp.Preferred = "ntp4"'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    jq -e '.errors[] | select(startswith("$.Time.Ntp.Preferred"))' <<< "$output" > /dev/null
}

@test "локали всех распространённых форматов принимаются" {
    local loc
    for loc in 'C' 'C.UTF-8' 'POSIX' 'en_US.UTF-8' 'ru_RU.UTF-8' 'en_US@euro'; do
        run validate_modified ".Time.Locale = \"$loc\""
        [ "$(jq -r '.valid' <<< "$output")" = "true" ] || { echo "отклонена локаль: $loc"; return 1; }
    done
}

@test "несколько ошибок возвращаются все сразу, а не по одной" {
    run validate_modified '.Ssh.MaxAuthTries = 99 | .Swap.SizeMegabytes = -1 | .Hostname.Name = "bad host"'
    [ "$(jq -r '.valid' <<< "$output")" = "false" ]
    [ "$(jq -r '.errorCount' <<< "$output")" -ge 3 ] || { echo "$output"; return 1; }
}

@test "небитый JSON отклоняется с понятным сообщением" {
    printf '{"Meta": {' > /tmp/lcfg-broken-$$.json
    run "$LCFG_BIN" --validate-config --config /tmp/lcfg-broken-$$.json
    rm -f /tmp/lcfg-broken-$$.json
    [ "$status" -eq 2 ]
    grep -q 'не является корректным JSON' <<< "$output" || { echo "$output"; return 1; }
}

@test "--validate-config на валидном конфиге возвращает 0" {
    run "$LCFG_BIN" --validate-config --config "$LCFG_ROOT/config/config.json"
    [ "$status" -eq 0 ]
    grep -q '\[OK\]' <<< "$output"
}

@test "--validate-config на невалидном конфиге возвращает 2" {
    jq '.Ssh.MaxAuthTries = 99' "$LCFG_ROOT/config/config.json" > /tmp/lcfg-invalid-$$.json
    run "$LCFG_BIN" --validate-config --config /tmp/lcfg-invalid-$$.json
    rm -f /tmp/lcfg-invalid-$$.json
    [ "$status" -eq 2 ]
    grep -q 'MaxAuthTries' <<< "$output"
}

@test "предупреждение о заглушке Hostname.Name" {
    run "$LCFG_BIN" --validate-config --config "$LCFG_ROOT/config/config.json"
    # Штатный конфиг содержит changeme-host, и это должно быть видно сразу.
    grep -qi 'changeme-host\|заглушк' <<< "$output" || { echo "$output"; return 1; }
}

@test "предупреждение при PasswordAuthentication = true" {
    jq '.Ssh.PasswordAuthentication = true' "$LCFG_ROOT/config/config.json" > /tmp/lcfg-pw-$$.json
    run "$LCFG_BIN" --validate-config --config /tmp/lcfg-pw-$$.json
    rm -f /tmp/lcfg-pw-$$.json
    grep -q 'PasswordAuthentication' <<< "$output" || { echo "$output"; return 1; }
}

@test "предупреждение о неизвестном шаге в DefaultSteps" {
    jq '.General.DefaultSteps = ["ssh", "несуществующий_шаг"]' "$LCFG_ROOT/config/config.json" > /tmp/lcfg-step-$$.json
    run "$LCFG_BIN" --validate-config --config /tmp/lcfg-step-$$.json
    rm -f /tmp/lcfg-step-$$.json
    grep -q 'несуществующий_шаг' <<< "$output" || { echo "$output"; return 1; }
}

@test "предупреждение при IsTestData = true" {
    jq '.Meta.IsTestData = true' "$LCFG_ROOT/config/config.json" > /tmp/lcfg-td-$$.json
    run "$LCFG_BIN" --validate-config --config /tmp/lcfg-td-$$.json
    rm -f /tmp/lcfg-td-$$.json
    grep -q 'IsTestData' <<< "$output" || { echo "$output"; return 1; }
}

@test "неизвестное поле конфигурации не считается ошибкой" {
    # additionalProperties намеренно не проверяется: конфиг должен переживать
    # появление новых полей в новой версии конфигуратора.
    run validate_modified '.MyOwnNote = "заметка оператора"'
    [ "$(jq -r '.valid' <<< "$output")" = "true" ]
}
