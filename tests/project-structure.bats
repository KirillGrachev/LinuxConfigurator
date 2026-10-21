#!/usr/bin/env bats
#
# Структура проекта и целостность реестра шагов.
#
# Эти тесты ловят класс ошибок, который невозможно поймать в рантайме до момента
# применения: шаг добавили в реестр, но забыли создать функцию (или наоборот),
# файл потерял shebang или право на исполнение, конфигурация разошлась со схемой.
# На боевой машине такой промах выглядит как "конфигуратор отработал зелёным,
# но ничего не сделал".

setup() {
    load test_helper
}

@test "точка входа существует и исполняема" {
    [ -f "$LCFG_BIN" ]
    [ -x "$LCFG_BIN" ]
}

@test "все .sh имеют shebang bash" {
    local f
    while IFS= read -r f; do
        head -1 "$f" | grep -q '^#!/usr/bin/env bash' \
            || { echo "нет shebang в $f"; return 1; }
    done < <(find "$LCFG_ROOT" -path '*/.git' -prune -o -name '*.sh' -print | sort)
}

@test "bash -n проходит на всех файлах" {
    local f
    while IFS= read -r f; do
        bash -n "$f" || { echo "синтаксическая ошибка в $f"; return 1; }
    done < <(find "$LCFG_ROOT" -path '*/.git' -prune -o -name '*.sh' -print)
}

@test "shellcheck не находит предупреждений и ошибок" {
    command -v shellcheck >/dev/null || skip "shellcheck не установлен"
    run shellcheck -x "$LCFG_BIN" "$LCFG_ROOT"/lib/*.sh "$LCFG_ROOT"/lib/*/*.sh
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "config.json соответствует config.schema.json" {
    run jq -f "$LCFG_ROOT/lib/config/validate-schema.jq" \
        --argjson config "$(cat "$LCFG_ROOT/config/config.json")" \
        "$LCFG_ROOT/config/config.schema.json"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.valid' <<< "$output")" = "true" ] || { echo "$output"; return 1; }
}

@test "для каждого шага реестра существует функция step_<имя>" {
    lcfg_load_lib
    local name func
    while IFS=$'\t' read -r name func _ _ _; do
        [ -n "$name" ] || continue
        declare -F "$func" >/dev/null || { echo "нет функции $func для шага $name"; return 1; }
    done < <(step_definitions)
}

@test "для каждой функции step_* в lib/steps есть запись в реестре" {
    lcfg_load_lib
    # Просматриваются только файлы шагов, кроме registry.sh: служебные функции
    # step_ok / step_failed / step_definitions / step_resolve и прочие тоже
    # начинаются с step_, но шагами не являются.
    local file fn registered
    while IFS= read -r file; do
        while IFS= read -r fn; do
            [ -n "$fn" ] || continue
            registered="$(step_definitions | awk -F'\t' -v f="$fn" '$2 == f {print $1}')"
            [ -n "$registered" ] || { echo "$fn из $(basename "$file") не зарегистрирована в реестре"; return 1; }
        done < <(grep -oE '^step_[a-z_]+\(\)' "$file" | tr -d '()')
    done < <(find "$LCFG_ROOT/lib/steps" -name '*.sh' ! -name 'registry.sh' | sort)
}

@test "все алиасы разрешаются в существующие шаги" {
    lcfg_load_lib
    local alias canonical
    while IFS=$'\t' read -r alias canonical; do
        [ -n "$alias" ] || continue
        run step_resolve "$alias"
        [ "$status" -eq 0 ] || { echo "алиас $alias не разрешается"; return 1; }
        [ "$output" = "$canonical" ] || { echo "алиас $alias -> $output, ожидалось $canonical"; return 1; }
    done < <(step_aliases)
}

@test "порядок шагов безопасен: users раньше ssh, ssh раньше firewall" {
    lcfg_load_lib
    local -a order=()
    local line
    while IFS= read -r line; do order+=("$line"); done < <(step_list_names)

    local i_users=-1 i_ssh=-1 i_fw=-1 i
    for i in "${!order[@]}"; do
        case "${order[$i]}" in
            users)    i_users=$i ;;
            ssh)      i_ssh=$i ;;
            firewall) i_fw=$i ;;
        esac
    done

    [ "$i_users" -ge 0 ] && [ "$i_ssh" -ge 0 ] && [ "$i_fw" -ge 0 ]
    # ssh отключает вход по паролю: к этому моменту ключ обязан быть установлен.
    [ "$i_users" -lt "$i_ssh" ] || { echo "users должен идти до ssh"; return 1; }
    # policy drop включается только когда доступ по ключу уже проверен.
    [ "$i_ssh" -lt "$i_fw" ] || { echo "ssh должен идти до firewall"; return 1; }
}

@test "порядок General.DefaultSteps совпадает с безопасным порядком реестра" {
    lcfg_load_lib
    local -a registry=() defaults=()
    local line
    while IFS= read -r line; do registry+=("$line"); done < <(step_list_names)
    while IFS= read -r line; do defaults+=("$line"); done \
        < <(jq -r '.General.DefaultSteps[]' "$LCFG_ROOT/config/config.json")

    idx_of() {
        local target="$1" i
        for i in "${!registry[@]}"; do
            [ "${registry[$i]}" = "$target" ] && { printf '%d' "$i"; return 0; }
        done
        printf '%d' -1
    }

    local prev=-1 cur name
    for name in "${defaults[@]}"; do
        cur="$(idx_of "$name")"
        [ "$cur" -ge 0 ] || { echo "$name отсутствует в реестре"; return 1; }
        [ "$cur" -gt "$prev" ] || { echo "DefaultSteps нарушает порядок реестра на $name"; return 1; }
        prev=$cur
    done
}

@test "в реестре нет дублей имён и алиасов" {
    lcfg_load_lib
    local dup
    dup="$(step_definitions | awk -F'\t' '{print $1}' | sort | uniq -d)"
    [ -z "$dup" ] || { echo "дубли шагов: $dup"; return 1; }
    dup="$(step_aliases | awk -F'\t' '{print $1}' | sort | uniq -d)"
    [ -z "$dup" ] || { echo "дубли алиасов: $dup"; return 1; }
}

@test "алиас не совпадает с именем существующего шага" {
    lcfg_load_lib
    local alias
    while IFS=$'\t' read -r alias _; do
        [ -n "$alias" ] || continue
        if step_definitions | awk -F'\t' -v a="$alias" '$1 == a {found=1} END {exit !found}'; then
            echo "алиас '$alias' одновременно является именем шага"
            return 1
        fi
    done < <(step_aliases)
}

@test "в проекте нет файлов с табуляцией в отступах bash-кода" {
    # 4 пробела - соглашение проекта (см. стиль HLS). Табы в bash ломают выравнивание
    # heredoc с <<-, поэтому их быть не должно.
    local f
    while IFS= read -r f; do
        if grep -qP '^\t' "$f"; then
            echo "табуляция в отступе: $f"
            return 1
        fi
    done < <(find "$LCFG_ROOT/lib" -name '*.sh')
}

@test "нет непарных CRLF в bash-файлах" {
    local f
    while IFS= read -r f; do
        if grep -qU $'\r' "$f"; then
            echo "CRLF в $f - bash на Linux его не переварит"
            return 1
        fi
    done < <(find "$LCFG_ROOT" -path '*/.git' -prune -o -name '*.sh' -print)
}

@test "config_get_bool не вызывается в подстановке команд без && или ||" {
    # config_get_bool возвращает СТАТУС, а не строку. Запись вида
    #   flag="$(config_get_bool '.X' true)"
    # всегда даёт пустую строку, и последующее [[ "$flag" == true ]] молча ложно.
    # Именно так ломались Users.Admin.CreateHome (домашний каталог не создавался,
    # вход по SSH падал), General.StopOnFirstFailure, Secrets.BlockTestDataSecrets
    # и откат на systemd-timesyncd в шаге time. Тест закрепляет урок.
    local bad
    bad="$(grep -rnE '\$\(config_get_bool' "$LCFG_ROOT/lib" \
        | grep -vE '&&|\|\|' \
        | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
    [ -z "$bad" ] || {
        echo "найдено misuse config_get_bool (нужен if/then, а не подстановка):"
        printf '%s\n' "$bad"
        return 1
    }
}

@test "в lib/ нет мёртвых функций: каждая определена и где-то вызвана" {
    lcfg_load_lib
    # Подсчёт по вхождениям имени как отдельного слова: определение даёт ровно одно
    # вхождение (строка "имя() {"), поэтому count == 1 означает "определена, но не
    # вызвана". Подсчёт вызовов через grep -v по шаблону определений давал ложные
    # срабатывания на именах с управляющими символами.
    local fn count dead=()
    while IFS= read -r fn; do
        [ -n "$fn" ] || continue
        count="$(grep -rwoE "$fn" "$LCFG_ROOT/lib" "$LCFG_BIN" "$LCFG_ROOT/tests" 2>/dev/null | wc -l)"
        if ! (( count > 1 )); then
            dead+=("$fn")
        fi
    done < <(declare -F | awk '{print $3}' | grep -E '^(fs_|config_|log_|step_|sys_|pkg_|run_|secret_|path_|confirm_|menu_|orchestrator_|runtime_|testmode_|hosts_|swap_|updates_|docker_|fail2ban_|motd_|report_|logging_|ssh_|users_|time_)' | sort)

    [ "${#dead[@]}" -eq 0 ] || {
        echo "мёртвые функции (определены, но нигде не вызываются):"
        printf '  %s\n' "${dead[@]}"
        return 1
    }
}
