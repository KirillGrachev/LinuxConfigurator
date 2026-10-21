#!/usr/bin/env bash
# Общая обвязка bats-тестов.
#
# Тесты выполняются на РЕАЛЬНОЙ машине (в том числе в CI на ubuntu-latest), поэтому
# любое изменение системы запрещено. Все прогоны идут в --test-mode или --what-if,
# а корректность изоляции проверяется отдельным тестом testmode-isolation.bats.

# Каталог проекта определяется от расположения этого файла, а не от pwd:
# bats запускает тесты из произвольного каталога.
LCFG_TEST_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LCFG_ROOT="$(cd "${LCFG_TEST_HELPER_DIR}/.." && pwd)"
export LCFG_BIN="${LCFG_ROOT}/configure-linux.sh"

# Конфигурация для тестов: валидная, но с заполненными обязательными полями.
# Создаётся один раз на прогон в TMPDIR, а не в каталоге проекта - тесты не должны
# оставлять мусор в рабочем дереве (оно под git).
lcfg_test_config() {
    if [[ -z "${LCFG_CFG:-}" ]]; then
        LCFG_CFG="$(mktemp "${TMPDIR:-/tmp}/lcfg-test-config.XXXXXX.json")"
        # PrivateKeyOutputPath уходит в TMPDIR: по умолчанию шаг users кладёт ключ
        # в /root/lcfg-generated-keys, а в CI прогон идёт от обычного пользователя
        # и /root ему недоступен.
        jq --arg keypath "${TMPDIR:-/tmp}/lcfg-test-key-$$" \
            '.Hostname.Name = "lcfg-test-host"
            | .Logging.FilePath = null
            | .Users.GenerateKeyIfSecretMissing = true
            | .Users.PrivateKeyOutputPath = $keypath
            | .Ssh.RollbackGuardSeconds = 0
            | .Firewall.RollbackGuardSeconds = 0
            | .Report.FilePath = ""' \
            "${LCFG_ROOT}/config/config.json" > "$LCFG_CFG"
        export LCFG_CFG
    fi
    printf '%s' "$LCFG_CFG"
}

# Прогон в тестовом режиме с возвратом всего вывода.
lcfg_run_testmode() {
    "$LCFG_BIN" --test-mode --config "$(lcfg_test_config)" "$@" 2>&1
}

lcfg_run_whatif() {
    "$LCFG_BIN" --what-if --yes --config "$(lcfg_test_config)" "$@" 2>&1
}

# Загружает функции проекта в текущую оболочку для юнит-проверок.
lcfg_load_lib() {
    # shellcheck source=/dev/null
    source "${LCFG_ROOT}/lib/load-functions.sh"
    runtime_init "$LCFG_ROOT" "test"
}

# Отпечатки критичных файлов: меняются только если тест действительно тронул систему.
lcfg_system_fingerprint() {
    local f
    for f in /etc/nftables.conf /etc/fstab /etc/hostname /etc/hosts \
             /etc/ssh/sshd_config /etc/default/locale /etc/timezone \
             /etc/systemd/journald.conf /etc/docker/daemon.json; do
        if [[ -f "$f" ]]; then
            printf '%s %s\n' "$f" "$(md5sum "$f" | awk '{print $1}')"
        fi
    done
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        find /etc/ssh/sshd_config.d -type f -exec md5sum {} + 2>/dev/null | sort
    fi
    if [[ -d /etc/nftables.d ]]; then
        find /etc/nftables.d -type f -exec md5sum {} + 2>/dev/null | sort
    fi
}

teardown() {
    if [[ -n "${LCFG_CFG:-}" && -f "${LCFG_CFG}" ]]; then
        rm -f "$LCFG_CFG"
        unset LCFG_CFG
    fi
    # Песочницы тестового режима не должны накапливаться между прогонами.
    find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'LCFG-TestMode-*' -mmin +5 -exec rm -rf {} + 2>/dev/null || true
}

# Загружает функции проекта и подставляет тестовую конфигурацию.
# Без конфигурации config_get возвращает только значения по умолчанию,
# и юнит-тесты проверяли бы не реальные данные, а заглушки.
lcfg_load_lib_with_config() {
    lcfg_load_lib
    LCFG_CONFIG="$(jq -c . "$(lcfg_test_config)")"
}
