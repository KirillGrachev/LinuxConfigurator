#!/usr/bin/env bats
#
# Юнит-тесты вспомогательных функций.
#
# Проверяются те места, где ошибка не видна до применения: раскрытие токенов в путях,
# оверлей песочницы при чтении, идемпотентность дописывания строк, фильтрация
# секретов-заглушек и разрешение алиасов шагов.

setup() {
    load test_helper
    lcfg_load_lib_with_config
}

@test "path_expand_tokens expands \${VAR} from the environment" {
    LCFG_TEST_MARKER='value'
    export LCFG_TEST_MARKER
    run path_expand_tokens '/var/log/${LCFG_TEST_MARKER}/x.log'
    [ "$status" -eq 0 ]
    [ "$output" = '/var/log/value/x.log' ]
    unset LCFG_TEST_MARKER
}

@test "path_expand_tokens expands ~ to the home directory" {
    run path_expand_tokens '~/keys/id_ed25519'
    [ "$status" -eq 0 ]
    [ "$output" = "${HOME}/keys/id_ed25519" ]
}

@test "path_expand_tokens leaves ~ in the middle of a string untouched" {
    run path_expand_tokens '/opt/~backup/file'
    [ "$output" = '/opt/~backup/file' ]
}

@test "path_expand_tokens: an unknown variable becomes an empty string" {
    # Оставленный как есть токен ${FOO} привёл бы к созданию файла с таким именем,
    # а это труднее заметить, чем понятную ошибку валидации.
    unset LCFG_DEFINITELY_UNSET_VAR
    run path_expand_tokens '/etc/${LCFG_DEFINITELY_UNSET_VAR}/conf'
    [ "$output" = '/etc//conf' ]
}

@test "path_expand_tokens does NOT execute code from the configuration" {
    # Раскрытие сделано подстановкой значения, а не eval. Иначе config.json,
    # который хранят в репозитории и правят всей командой, стал бы вектором
    # выполнения произвольного кода от имени root.
    local marker="/tmp/lcfg-injection-$$"
    rm -f "$marker"
    run path_expand_tokens "\$(touch ${marker})"
    [ ! -e "$marker" ] || { echo "code from the config line was executed"; return 1; }
    run path_expand_tokens "\`touch ${marker}\`"
    [ ! -e "$marker" ] || { echo "backtick code from the config line was executed"; return 1; }
}

@test "path_absolute converts a relative path to an absolute one" {
    run path_absolute 'config/config.json'
    [[ "$output" == /* ]]
}

@test "secret_is_test_data rejects placeholders from the examples" {
    local bad
    for bad in 'changeme' 'PASSWORD' 'qwerty123' 'hunter2' 'ssh-ed25519 AAAA user@example.com' 'test.local key'; do
        secret_is_test_data "$bad" || { echo "placeholder not recognized: '$bad'"; return 1; }
    done
}

@test "secret_is_test_data accepts real keys" {
    local good='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHx9Kd2mQ7vLp3Zw8Rt5Yn4Bc6Af1Gh0JkL admin@prod-server-01'
    ! secret_is_test_data "$good" || { echo "a real key was treated as a placeholder"; return 1; }
}

@test "secret_resolve takes the value from the prefixed environment variable" {
    export LCFG_ADMIN_AUTHORIZED_KEYS='ssh-ed25519 AAAArealKEY admin@host'
    secret_init
    run secret_resolve admin_authorized_keys
    [ "$status" -eq 0 ]
    [ "$output" = 'ssh-ed25519 AAAArealKEY admin@host' ]
    unset LCFG_ADMIN_AUTHORIZED_KEYS
}

@test "secret_resolve returns 1 on a placeholder with BlockTestDataSecrets" {
    export LCFG_ADMIN_AUTHORIZED_KEYS='changeme'
    secret_init
    run secret_resolve admin_authorized_keys
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    # Значение секрета не должно попасть в вывод ни в каком виде. Сообщение об
    # ошибке при этом законно печатается (bats сливает stderr с stdout),
    # поэтому проверяем не пустоту вывода, а отсутствие самого значения.
    ! grep -q 'changeme' <<< "$output" || { echo "the secret value leaked into the output: $output"; return 1; }
    unset LCFG_ADMIN_AUTHORIZED_KEYS
}

@test "config_get returns the default for a missing field" {
    run config_get '.Missing.Field.None' 'default'
    [ "$output" = 'default' ]
}

@test "config_get distinguishes false from a missing value" {
    # jq выводит "null" для отсутствующего поля; если трактовать его как значение,
    # все булевы флаги по умолчанию стали бы false независимо от конфигурации.
    run config_get '.Docker.Enabled' 'fallback'
    [ "$output" = 'false' ]
    run config_get '.Meta.NonExistent' 'fallback'
    [ "$output" = 'fallback' ]
}

@test "config_get_bool handles true and false correctly" {
    config_get_bool '.Ssh.PasswordAuthentication' true && { echo "false read as true"; return 1; }
    config_get_bool '.Ssh.PubkeyAuthentication' false || { echo "true read as false"; return 1; }
    # Значение по умолчанию применяется при отсутствии поля.
    config_get_bool '.Fully.Missing' true || { echo "default true did not work"; return 1; }
    ! config_get_bool '.Fully.Missing' false
}

@test "config_get_int rejects non-numeric values" {
    jq '.Ssh.MaxAuthTries = "many"' "$(lcfg_test_config)" > /tmp/lcfg-int-$$.json
    LCFG_CONFIG="$(jq -c . /tmp/lcfg-int-$$.json)"
    rm -f /tmp/lcfg-int-$$..json /tmp/lcfg-int-$$.json
    run config_get_int '.Ssh.MaxAuthTries' 3
    [ "$output" = "3" ]
}

@test "config_get_array returns one element per line" {
    run config_get_array '.General.DefaultSteps'
    [ "$status" -eq 0 ]
    [ "$(grep -c . <<< "$output")" -ge 10 ]
    grep -qx 'ssh' <<< "$output"
    grep -qx 'firewall' <<< "$output"
}

@test "config_get_array does not fail on a missing array" {
    run config_get_array '.Fully.Missing'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "config_section_enabled: a missing section means 'disabled'" {
    # Шаг, для которого в конфигурации ничего не описано, не должен менять систему.
    ! config_section_enabled 'NoSectionHere'
    config_section_enabled 'Ssh'
}

@test "step_resolve accepts the canonical name, an alias and any case" {
    run step_resolve 'firewall'
    [ "$output" = 'firewall' ]
    run step_resolve 'fw'
    [ "$output" = 'firewall' ]
    run step_resolve 'SSHD'
    [ "$output" = 'ssh' ]
    run step_resolve 'NTP'
    [ "$output" = 'time' ]
}

@test "step_resolve errors on an unknown name" {
    run step_resolve 'no_such_step'
    [ "$status" -ne 0 ]
}

@test "step_field returns the description, root requirement and risk level" {
    [ -n "$(step_description ssh)" ]
    [ "$(step_needs_root ssh)" = 'true' ]
    [ "$(step_needs_root report)" = 'false' ]
    [ "$(step_impact ssh)" = 'High' ]
    [ "$(step_impact motd)" = 'Low' ]
}

@test "log_level_weight orders levels correctly" {
    [ "$(log_level_weight DEBUG)" -lt "$(log_level_weight INFO)" ]
    [ "$(log_level_weight INFO)" -lt "$(log_level_weight WARN)" ]
    [ "$(log_level_weight WARN)" -lt "$(log_level_weight ERROR)" ]
    [ "$(log_level_weight ERROR)" -lt "$(log_level_weight FATAL)" ]
    # Неизвестный уровень трактуется как INFO, а не как 0 (иначе логилось бы всё).
    [ "$(log_level_weight SOMETHING)" -eq 20 ]
}

@test "fs overlay: what was written to the sandbox reads back" {
    testmode_enable
    fs_write '/etc/lcfg-test/file.conf' 'content' 644

    # Чтение обязано видеть песочницу, иначе шаг, перечитывающий записанное
    # (sshd -t по свежему drop-in, повторный идемпотентный прогон), в тестовом
    # режиме ушёл бы по другой ветке и тест перестал бы соответствовать реальности.
    fs_is_file '/etc/lcfg-test/file.conf'
    run fs_read '/etc/lcfg-test/file.conf'
    [ "$output" = 'content' ]

    # Настоящая файловая система не затронута.
    [ ! -e /etc/lcfg-test ]
}

@test "fs overlay: an existing system file reads until overwritten" {
    testmode_enable
    run fs_read /etc/hostname
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "fs_append_unique does not duplicate a line" {
    testmode_enable
    fs_write '/etc/lcfg-test/fstab' 'first line'
    fs_append_unique '/etc/lcfg-test/fstab' '/swapfile none swap sw 0 0'
    fs_append_unique '/etc/lcfg-test/fstab' '/swapfile none swap sw 0 0'
    fs_append_unique '/etc/lcfg-test/fstab' '/swapfile none swap sw 0 0'

    local sandboxed count
    sandboxed="$(testmode_sandbox_path /etc/lcfg-test/fstab)"
    count="$(grep -cF '/swapfile none swap sw 0 0' "$sandboxed")"
    [ "$count" = "1" ] || { echo "the line was duplicated $count times"; cat "$sandboxed"; return 1; }
}

@test "fs_write is atomic: no temp file is left behind" {
    testmode_enable
    fs_write '/etc/lcfg-test/atomic.conf' 'data' 600
    local sandboxed_dir
    sandboxed_dir="$(dirname "$(testmode_sandbox_path /etc/lcfg-test/atomic.conf)")"
    local leftover
    leftover="$(find "$sandboxed_dir" -name '*.lcfg-tmp.*' 2>/dev/null | wc -l)"
    [ "$leftover" = "0" ] || { echo "a temp file was left behind"; return 1; }
}

@test "a test-mode fixture replaces command output" {
    testmode_enable
    testmode_set_fixture 'uname -r' '9.9.9-testmode'
    run run_capture uname -r
    [ "$status" -eq 0 ]
    [ "$output" = '9.9.9-testmode' ] || { echo "got: '$output'"; return 1; }
}

@test "a fixture sets a non-zero exit code for the command" {
    testmode_enable
    testmode_set_fixture 'systemctl reload ssh' '' 1
    run run_cmd systemctl reload ssh
    [ "$status" -eq 1 ] || { echo "expected code 1 from the fixture, got $status"; return 1; }
}

@test "a command without a fixture returns 0 and empty output in test mode" {
    # Именно это позволяет прогонять --test-mode на любой машине: отсутствующая
    # фикстура не ошибка, а успешная симуляция с пустым выводом.
    testmode_enable
    run run_capture some-tool-that-does-not-exist --flag
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "in test mode the command reaches the journal verbatim" {
    testmode_enable
    run_quiet apt-get install -y --no-install-recommends "package with space"
    local journal="$LCFG_TESTMODE_JOURNAL"
    # Смысл журнала - воспроизводимость: командная строка обязана быть полной,
    # включая аргументы с пробелами.
    grep -qF 'package with space' "$journal" || { cat "$journal"; return 1; }
}
