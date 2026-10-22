#!/usr/bin/env bash
#
# SYNOPSIS
#     Разрешение секретов: SSH-ключи, пароли, токены.
#
# DESCRIPTION
#     Секрет никогда не хранится в config.json. В конфигурации указывается только ИМЯ
#     секрета, а значение берётся из переменных окружения с префиксом из
#     Secrets.EnvironmentVariablePrefix (по умолчанию LCFG_).
#
#     Префикс намеренно LCFG_, а не LC_: LC_ALL, LC_CTYPE и прочие LC_* зарезервированы
#     POSIX под локаль, и переменная LC_PRIVATE_KEY могла бы быть проглочена механизмом
#     локали или, что хуже, сама сломать бы кодировку вывода.
#
#     Порядок разрешения:
#       1. переменная окружения <PREFIX><ИМЯ В ВЕРХНЕМ РЕГИСТРЕ>;
#       2. Secrets.Values.<имя> при Secrets.Provider = "Plain" - для лабораторных стендов;
#       3. пустая строка.
#
#     BlockTestDataSecrets отвергает значения-заглушки из примеров ("changeme", "test",
#     "password" и т.п.). Без этого легко прогнать конфигуратор с демо-конфигом и получить
#     боевой сервер с ключом, который лежит в публичном репозитории.

declare -g LCFG_SECRET_PREFIX='LCFG_'
declare -g LCFG_SECRET_PROVIDER='Environment'
declare -g LCFG_SECRET_BLOCK_TEST_DATA=true

# Список значений-заглушек. Проверка регистронезависимая и по подстроке.
readonly LCFG_TEST_DATA_SECRETS=('changeme' 'change_me' 'password' 'secret' 'test123' 'qwerty' 'placeholder' 'example' 'dummy' 'hunter2')

secret_init() {
    LCFG_SECRET_PREFIX="$(config_get '.Secrets.EnvironmentVariablePrefix' 'LCFG_')"
    LCFG_SECRET_PROVIDER="$(config_get '.Secrets.Provider' 'Environment')"
    # Статус, а не строка: иначе защита от секретов-заглушек не работала бы вообще.
    if config_get_bool '.Secrets.BlockTestDataSecrets' true; then
        LCFG_SECRET_BLOCK_TEST_DATA=true
    else
        LCFG_SECRET_BLOCK_TEST_DATA=false
    fi
}

secret_env_name() {
    local name="$1"
    printf '%s%s' "$LCFG_SECRET_PREFIX" "$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
}

# Является ли значение тестовой заглушкой.
secret_is_test_data() {
    local value="${1,,}"
    local marker

    [[ -n "$value" ]] || return 1

    for marker in "${LCFG_TEST_DATA_SECRETS[@]}"; do
        [[ "$value" == *"$marker"* ]] && return 0
    done

    # SSH-ключ из демо-конфигурации узнаётся по комментарию в конце публичной части.
    [[ "$value" == *'@example.'* || "$value" == *'test.local'* ]] && return 0
    return 1
}

# Возвращает значение секрета. Пустая строка - секрет не задан.
# Возвращает 1, если значение задано, но отвергнуто как тестовое.
secret_resolve() {
    local name="$1"
    local env_name value=''

    env_name="$(secret_env_name "$name")"
    value="${!env_name:-}"

    if [[ -z "$value" && "$LCFG_SECRET_PROVIDER" == Plain ]]; then
        value="$(config_get ".Secrets.Values.\"${name}\"" '')"
    fi

    [[ -n "$value" ]] || { printf ''; return 0; }

    if [[ "$LCFG_SECRET_BLOCK_TEST_DATA" == true ]] && secret_is_test_data "$value"; then
        log_error "Secret '${name}' looks like a test placeholder and was rejected (Secrets.BlockTestDataSecrets=true)."
        printf ''
        return 1
    fi

    printf '%s' "$value"
}

