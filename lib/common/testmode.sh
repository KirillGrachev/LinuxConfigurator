#!/usr/bin/env bash
#
# SYNOPSIS
#     Тестовый режим: полный прогон логики шагов с симуляцией всех побочных эффектов.
#
# DESCRIPTION
#     Прямой аналог -TestMode из WindowsConfigurator и ответ на главную проблему
#     скриптов настройки: их невозможно безопасно протестировать, не испортив машину.
#
#     В тестовом режиме:
#       - внешние команды (apt-get, systemctl, sysctl, nft, sshd, useradd ...) НЕ исполняются:
#         точная командная строка уходит в журнал, код возврата берётся из фикстур
#         (по умолчанию 0), вывод - из фикстуры или пустой;
#       - запись файлов идёт в песочницу /tmp/LCFG-TestMode-*, повторяя абсолютный путь
#         (etc/ssh/sshd_config.d/...), поэтому логика read-modify-write остаётся честной:
#         шаг, который перечитывает то, что записал предыдущий шаг, увидит свои данные;
#       - чтение существующих файлов системы остаётся настоящим: конфигуратор должен
#         принимать решения по реальному состоянию машины, иначе тест ничего не проверит;
#       - по итогам создаётся testmode-report.json со счётчиками по категориям и полным
#         журналом операций.
#
#     Права root в тестовом режиме не требуются - это позволяет прогнать весь сценарий
#     на рабочей машине или в CI до того, как применять его к боевому серверу.

declare -g LCFG_TESTMODE_SANDBOX=''
declare -g LCFG_TESTMODE_JOURNAL=''
declare -gA LCFG_TESTMODE_COUNTERS=()
declare -gA LCFG_TESTMODE_FIXTURES=()

testmode_enabled() {
    runtime_flag test_mode
}

testmode_enable() {
    LCFG_TESTMODE_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/LCFG-TestMode-XXXXXX")"
    LCFG_TESTMODE_JOURNAL="${LCFG_TESTMODE_SANDBOX}/journal.tsv"
    : > "$LCFG_TESTMODE_JOURNAL"
    LCFG_TESTMODE_COUNTERS=()
    runtime_set_flag test_mode true
    runtime_set_value testmode_sandbox "$LCFG_TESTMODE_SANDBOX"
}

testmode_sandbox() {
    printf '%s' "$LCFG_TESTMODE_SANDBOX"
}

testmode_bump() {
    local category="$1"
    LCFG_TESTMODE_COUNTERS["$category"]="$(( ${LCFG_TESTMODE_COUNTERS[$category]:-0} + 1 ))"
}

# Пишет операцию в журнал песочницы.
# Формат TSV: категория \t операция \t цель \t детали.
# TSV выбран вместо JSON потому, что журнал пишется построчно из подшеллов,
# где вызов jq на каждую строку заметен на длинном прогоне.
testmode_journal() {
    local category="$1" operation="$2" target="$3" details="${4:-}"
    [[ -n "$LCFG_TESTMODE_JOURNAL" ]] || return 0
    printf '%s\t%s\t%s\t%s\n' "$category" "$operation" "$target" "$details" >> "$LCFG_TESTMODE_JOURNAL"
    testmode_bump "$category"
}

# Программируемый вывод команды для тестового режима.
# Без фикстуры команда возвращает пустой вывод и код 0.
testmode_set_fixture() {
    local command_pattern="$1"
    local output="$2"
    local exit_code="${3:-0}"
    LCFG_TESTMODE_FIXTURES["$command_pattern"]="${output}"$'\x1f'"${exit_code}"
}

testmode_get_fixture() {
    local command="$1"
    local pattern entry

    for pattern in "${!LCFG_TESTMODE_FIXTURES[@]}"; do
        # shellcheck disable=SC2053  # намеренное сопоставление с шаблоном, а не строкой
        if [[ "$command" == $pattern ]]; then
            entry="${LCFG_TESTMODE_FIXTURES[$pattern]}"
            printf '%s' "$entry"
            return 0
        fi
    done
    return 1
}

# Преобразует абсолютный путь в путь внутри песочницы, сохраняя структуру каталогов.
# /etc/ssh/sshd_config.d/x.conf -> $SANDBOX/etc/ssh/sshd_config.d/x.conf
testmode_sandbox_path() {
    local path="$1"
    printf '%s/%s' "$LCFG_TESTMODE_SANDBOX" "${path#/}"
}

# Формирует testmode-report.json: счётчики по категориям + полный журнал операций.
testmode_write_report() {
    local report_path="${LCFG_TESTMODE_SANDBOX}/testmode-report.json"
    local counters_json journal_json category

    counters_json='{'
    local first=true
    for category in $(printf '%s\n' "${!LCFG_TESTMODE_COUNTERS[@]}" | sort); do
        if [[ "$first" == true ]]; then first=false; else counters_json+=','; fi
        counters_json+="$(printf '"%s":%d' "$category" "${LCFG_TESTMODE_COUNTERS[$category]}")"
    done
    counters_json+='}'

    # Журнал может содержать кавычки и переводы строк, поэтому собираем его через jq.
    journal_json="$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t") |
        {category: .[0], operation: .[1], target: .[2], details: (.[3] // "")})' \
        < "$LCFG_TESTMODE_JOURNAL" 2>/dev/null || echo '[]')"

    jq -n \
        --argjson counters "$counters_json" \
        --argjson journal "$journal_json" \
        --arg sandbox "$LCFG_TESTMODE_SANDBOX" \
        --arg generated "$(date -Iseconds)" \
        --arg version "$LCFG_VERSION" \
        '{generated: $generated, version: $version, sandbox: $sandbox,
          operationCount: ($journal | length), counters: $counters, journal: $journal}' \
        > "$report_path"

    runtime_set_value testmode_report "$report_path"
    runtime_set_value testmode_operations "$(jq '.operationCount' < "$report_path")"
    printf '%s' "$report_path"
}

testmode_print_summary() {
    local operations report category
    operations="$(runtime_value testmode_operations 0)"
    report="$(runtime_value testmode_report '')"

    console_plain ''
    console_plain '=========> Test Mode <========='
    console_plain "System changes are SIMULATED. Operations in the journal: ${operations}"
    for category in $(printf '%s\n' "${!LCFG_TESTMODE_COUNTERS[@]}" | sort); do
        console_plain "  ${category}: ${LCFG_TESTMODE_COUNTERS[$category]}"
    done
    console_plain "Sandbox : ${LCFG_TESTMODE_SANDBOX}"
    console_plain "Report  : ${report}"
    console_plain '========================================================'
}
