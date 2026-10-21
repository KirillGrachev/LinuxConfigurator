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

@test "path_expand_tokens раскрывает \${VAR} из окружения" {
    LCFG_TEST_MARKER='значение'
    export LCFG_TEST_MARKER
    run path_expand_tokens '/var/log/${LCFG_TEST_MARKER}/x.log'
    [ "$status" -eq 0 ]
    [ "$output" = '/var/log/значение/x.log' ]
    unset LCFG_TEST_MARKER
}

@test "path_expand_tokens раскрывает ~ в домашний каталог" {
    run path_expand_tokens '~/keys/id_ed25519'
    [ "$status" -eq 0 ]
    [ "$output" = "${HOME}/keys/id_ed25519" ]
}

@test "path_expand_tokens не трогает ~ в середине строки" {
    run path_expand_tokens '/opt/~backup/file'
    [ "$output" = '/opt/~backup/file' ]
}

@test "path_expand_tokens: неизвестная переменная становится пустой строкой" {
    # Оставленный как есть токен ${FOO} привёл бы к созданию файла с таким именем,
    # а это труднее заметить, чем понятную ошибку валидации.
    unset LCFG_DEFINITELY_UNSET_VAR
    run path_expand_tokens '/etc/${LCFG_DEFINITELY_UNSET_VAR}/conf'
    [ "$output" = '/etc//conf' ]
}

@test "path_expand_tokens НЕ исполняет код из конфигурации" {
    # Раскрытие сделано подстановкой значения, а не eval. Иначе config.json,
    # который хранят в репозитории и правят всей командой, стал бы вектором
    # выполнения произвольного кода от имени root.
    local marker="/tmp/lcfg-injection-$$"
    rm -f "$marker"
    run path_expand_tokens "\$(touch ${marker})"
    [ ! -e "$marker" ] || { echo "выполнен код из строки конфигурации"; return 1; }
    run path_expand_tokens "\`touch ${marker}\`"
    [ ! -e "$marker" ] || { echo "выполнен backtick-код из строки конфигурации"; return 1; }
}

@test "path_absolute приводит относительный путь к абсолютному" {
    run path_absolute 'config/config.json'
    [[ "$output" == /* ]]
}

@test "secret_is_test_data отвергает заглушки из примеров" {
    local bad
    for bad in 'changeme' 'PASSWORD' 'qwerty123' 'hunter2' 'ssh-ed25519 AAAA user@example.com' 'test.local key'; do
        secret_is_test_data "$bad" || { echo "заглушка не распознана: '$bad'"; return 1; }
    done
}

@test "secret_is_test_data пропускает настоящие ключи" {
    local good='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHx9Kd2mQ7vLp3Zw8Rt5Yn4Bc6Af1Gh0JkL admin@prod-server-01'
    ! secret_is_test_data "$good" || { echo "настоящий ключ принят за заглушку"; return 1; }
}

@test "secret_resolve берёт значение из переменной окружения с префиксом" {
    export LCFG_ADMIN_AUTHORIZED_KEYS='ssh-ed25519 AAAArealKEY admin@host'
    secret_init
    run secret_resolve admin_authorized_keys
    [ "$status" -eq 0 ]
    [ "$output" = 'ssh-ed25519 AAAArealKEY admin@host' ]
    unset LCFG_ADMIN_AUTHORIZED_KEYS
}

@test "secret_resolve возвращает 1 на заглушке при BlockTestDataSecrets" {
    export LCFG_ADMIN_AUTHORIZED_KEYS='changeme'
    secret_init
    run secret_resolve admin_authorized_keys
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    # Значение секрета не должно попасть в вывод ни в каком виде. Сообщение об
    # ошибке при этом законно печатается (bats сливает stderr с stdout),
    # поэтому проверяем не пустоту вывода, а отсутствие самого значения.
    ! grep -q 'changeme' <<< "$output" || { echo "значение секрета утекло в вывод: $output"; return 1; }
    unset LCFG_ADMIN_AUTHORIZED_KEYS
}

@test "config_get возвращает значение по умолчанию для отсутствующего поля" {
    run config_get '.Несуществующего.Поля.Нет' 'дефолт'
    [ "$output" = 'дефолт' ]
}

@test "config_get различает false и отсутствие значения" {
    # jq выводит "null" для отсутствующего поля; если трактовать его как значение,
    # все булевы флаги по умолчанию стали бы false независимо от конфигурации.
    run config_get '.Docker.Enabled' 'fallback'
    [ "$output" = 'false' ]
    run config_get '.Meta.NonExistent' 'fallback'
    [ "$output" = 'fallback' ]
}

@test "config_get_bool корректно обрабатывает true и false" {
    config_get_bool '.Ssh.PasswordAuthentication' true && { echo "false прочитан как true"; return 1; }
    config_get_bool '.Ssh.PubkeyAuthentication' false || { echo "true прочитан как false"; return 1; }
    # Значение по умолчанию применяется при отсутствии поля.
    config_get_bool '.Полностью.Отсутствует' true || { echo "дефолт true не сработал"; return 1; }
    ! config_get_bool '.Полностью.Отсутствует' false
}

@test "config_get_int отсекает нечисловые значения" {
    jq '.Ssh.MaxAuthTries = "много"' "$(lcfg_test_config)" > /tmp/lcfg-int-$$.json
    LCFG_CONFIG="$(jq -c . /tmp/lcfg-int-$$.json)"
    rm -f /tmp/lcfg-int-$$..json /tmp/lcfg-int-$$.json
    run config_get_int '.Ssh.MaxAuthTries' 3
    [ "$output" = "3" ]
}

@test "config_get_array возвращает по элементу в строке" {
    run config_get_array '.General.DefaultSteps'
    [ "$status" -eq 0 ]
    [ "$(grep -c . <<< "$output")" -ge 10 ]
    grep -qx 'ssh' <<< "$output"
    grep -qx 'firewall' <<< "$output"
}

@test "config_get_array для отсутствующего массива не падает" {
    run config_get_array '.Полностью.Отсутствует'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "config_section_enabled: отсутствие секции означает 'выключено'" {
    # Шаг, для которого в конфигурации ничего не описано, не должен менять систему.
    ! config_section_enabled 'СекцииНет'
    config_section_enabled 'Ssh'
}

@test "step_resolve принимает каноническое имя, алиас и любой регистр" {
    run step_resolve 'firewall'
    [ "$output" = 'firewall' ]
    run step_resolve 'fw'
    [ "$output" = 'firewall' ]
    run step_resolve 'SSHD'
    [ "$output" = 'ssh' ]
    run step_resolve 'NTP'
    [ "$output" = 'time' ]
}

@test "step_resolve возвращает ошибку на неизвестном имени" {
    run step_resolve 'такого_нет'
    [ "$status" -ne 0 ]
}

@test "step_field возвращает описание, требование root и уровень риска" {
    [ -n "$(step_description ssh)" ]
    [ "$(step_needs_root ssh)" = 'true' ]
    [ "$(step_needs_root report)" = 'false' ]
    [ "$(step_impact ssh)" = 'High' ]
    [ "$(step_impact motd)" = 'Low' ]
}

@test "log_level_weight упорядочивает уровни правильно" {
    [ "$(log_level_weight DEBUG)" -lt "$(log_level_weight INFO)" ]
    [ "$(log_level_weight INFO)" -lt "$(log_level_weight WARN)" ]
    [ "$(log_level_weight WARN)" -lt "$(log_level_weight ERROR)" ]
    [ "$(log_level_weight ERROR)" -lt "$(log_level_weight FATAL)" ]
    # Неизвестный уровень трактуется как INFO, а не как 0 (иначе логилось бы всё).
    [ "$(log_level_weight ЧТО-ТО)" -eq 20 ]
}

@test "fs-оверлей: записанное в песочницу читается обратно" {
    testmode_enable
    fs_write '/etc/lcfg-test/file.conf' 'содержимое' 644

    # Чтение обязано видеть песочницу, иначе шаг, перечитывающий записанное
    # (sshd -t по свежему drop-in, повторный идемпотентный прогон), в тестовом
    # режиме ушёл бы по другой ветке и тест перестал бы соответствовать реальности.
    fs_is_file '/etc/lcfg-test/file.conf'
    run fs_read '/etc/lcfg-test/file.conf'
    [ "$output" = 'содержимое' ]

    # Настоящая файловая система не затронута.
    [ ! -e /etc/lcfg-test ]
}

@test "fs-оверлей: существующий системный файл читается, пока не перезаписан" {
    testmode_enable
    run fs_read /etc/hostname
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "fs_append_unique не дублирует строку" {
    testmode_enable
    fs_write '/etc/lcfg-test/fstab' 'первая строка'
    fs_append_unique '/etc/lcfg-test/fstab' '/swapfile none swap sw 0 0'
    fs_append_unique '/etc/lcfg-test/fstab' '/swapfile none swap sw 0 0'
    fs_append_unique '/etc/lcfg-test/fstab' '/swapfile none swap sw 0 0'

    local sandboxed count
    sandboxed="$(testmode_sandbox_path /etc/lcfg-test/fstab)"
    count="$(grep -cF '/swapfile none swap sw 0 0' "$sandboxed")"
    [ "$count" = "1" ] || { echo "строка продублирована $count раз"; cat "$sandboxed"; return 1; }
}

@test "fs_write атомарен: временный файл не остаётся" {
    testmode_enable
    fs_write '/etc/lcfg-test/atomic.conf' 'данные' 600
    local sandboxed_dir
    sandboxed_dir="$(dirname "$(testmode_sandbox_path /etc/lcfg-test/atomic.conf)")"
    local leftover
    leftover="$(find "$sandboxed_dir" -name '*.lcfg-tmp.*' 2>/dev/null | wc -l)"
    [ "$leftover" = "0" ] || { echo "остался временный файл"; return 1; }
}

@test "фикстура тестового режима подменяет вывод команды" {
    testmode_enable
    testmode_set_fixture 'uname -r' '9.9.9-testmode'
    run run_capture uname -r
    [ "$status" -eq 0 ]
    [ "$output" = '9.9.9-testmode' ] || { echo "получено: '$output'"; return 1; }
}

@test "фикстура задаёт ненулевой код возврата команды" {
    testmode_enable
    testmode_set_fixture 'systemctl reload ssh' '' 1
    run run_cmd systemctl reload ssh
    [ "$status" -eq 1 ] || { echo "ожидался код 1 от фикстуры, получен $status"; return 1; }
}

@test "команда без фикстуры в тестовом режиме возвращает 0 и пустой вывод" {
    # Именно это позволяет прогонять --test-mode на любой машине: отсутствующая
    # фикстура не ошибка, а успешная симуляция с пустым выводом.
    testmode_enable
    run run_capture some-tool-that-does-not-exist --flag
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "в тестовом режиме команда попадает в журнал дословно" {
    testmode_enable
    run_quiet apt-get install -y --no-install-recommends "пакет с пробелом"
    local journal="$LCFG_TESTMODE_JOURNAL"
    # Смысл журнала - воспроизводимость: командная строка обязана быть полной,
    # включая аргументы с пробелами.
    grep -qF 'пакет с пробелом' "$journal" || { cat "$journal"; return 1; }
}
