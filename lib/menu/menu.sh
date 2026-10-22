#!/usr/bin/env bash
#
# SYNOPSIS
#     Интерактивное меню выбора шагов.
#
# DESCRIPTION
#     Нужно для двух сценариев: первый прогон на незнакомой машине (оператор видит
#     список шагов с уровнем риска и выбирает, что применять) и точечное повторное
#     применение одного шага после правки конфигурации.
#
#     Для автоматизации меню не предназначено: при stdin не из терминала оно
#     немедленно завершается с ошибкой и подсказкой использовать --run-all или
#     --run-steps. Интерактивный запрос в cron или в CI подвесил бы прогон навсегда,
#     поэтому проверка выполняется до вывода первого приглашения.
#
#     Ввод проверяется по реестру шагов: неизвестное имя отклоняется сразу, а не
#     на этапе выполнения, когда часть шагов уже изменила систему.

menu_run() {
    if [[ ! -t 0 ]]; then
        console_fatal 'The interactive menu requires a terminal.'
        console_fatal 'In unattended mode use --run-all or --run-steps ssh,firewall.'
        return 2
    fi

    local mode selected

    while true; do
        menu_print_header
        printf '\nChoose an action:\n'
        printf '  1) %s\n' 'Run all default steps (General.DefaultSteps)'
        printf '  2) %s\n' 'Pick steps manually'
        printf '  3) %s\n' 'Show configuration (summary)'
        printf '  4) %s\n' 'Validate configuration against the schema'
        printf '  0) %s\n' 'Exit'
        printf '\n> '
        read -r mode || mode=0

        case "$mode" in
            1) orchestrator_run_default_steps; return $? ;;
            2)
                selected="$(menu_select_steps)" || return 2
                [[ -n "$selected" ]] || { console_warn 'Nothing selected.'; continue; }
                orchestrator_run_steps "$selected"
                return $?
                ;;
            3) menu_print_config_summary ;;
            4)
                if config_validate_file "$(runtime_value config_path '')"; then
                    console_ok 'Configuration matches the schema.'
                else
                    console_fail 'Configuration does NOT match the schema.'
                fi
                ;;
            0) console_info 'Exiting without changes.'; return 0 ;;
            *) console_warn "Unrecognized choice: '${mode}'" ;;
        esac
    done
}

menu_print_header() {
    local pending
    console_plain ''
    console_plain "=========> LinuxConfigurator ${LCFG_VERSION} <========="
    console_plain "Machine: $(sys_describe)"
    pending="$(sys_reboot_pending)"
    [[ -n "$pending" ]] && console_warn "Reboot pending: ${pending}"
    console_plain ''
    step_print_table
}

# Возвращает список шагов через запятую. Пустая строка - ничего не выбрано.
menu_select_steps() {
    local input
    console_plain ''
    console_plain "Enter step names comma-separated (example: ssh,firewall,fail2ban)"
    console_plain "or 'all' for every registry step. An empty line cancels."
    printf '> '
    read -r input || return 1

    input="$(printf '%s' "$input" | tr -d '[:space:]')"
    [[ -n "$input" ]] || { printf ''; return 0; }

    if [[ "${input,,}" == all ]]; then
        step_list_names | paste -sd, -
        return 0
    fi

    # Проверка всех имён до передачи в оркестратор.
    local item resolved unknown=() valid=() items=()
    IFS=',' read -r -a items <<< "$input"
    for item in "${items[@]}"; do
        [[ -n "$item" ]] || continue
        if resolved="$(step_resolve "$item")"; then
            valid+=("$resolved")
        else
            unknown+=("$item")
        fi
    done

    if (( ${#unknown[@]} > 0 )); then
        console_fail "Unknown steps: ${unknown[*]}"
        console_plain "Available: $(step_list_names | paste -sd, -)"
        return 2
    fi

    # Дедупликация с сохранением порядка: случайный повтор имени в вводе
    # не должен применять шаг дважды.
    local -A seen=()
    local out=()
    for item in "${valid[@]}"; do
        [[ -n "${seen[$item]:-}" ]] && continue
        seen[$item]=1
        out+=("$item")
    done

    # local IFS обязателен: присваивание без local меняет IFS для всего скрипта,
    # и последующее чтение конфигурации по словам пошло бы по запятой.
    local IFS=,
    printf '%s' "${out[*]}"
}

menu_print_config_summary() {
    local cfg
    cfg="$(runtime_get_config)"
    [[ -n "$cfg" ]] || { console_warn 'Configuration is not loaded.'; return 0; }

    console_plain ''
    console_plain '=========> Configuration Summary <========='
    printf '%s\n' "$cfg" | jq -r '
        to_entries[]
        | select(.value | type == "object")
        | "  \(.key): " + (
            if (.value | has("Enabled")) then
                (if .value.Enabled then "enabled" else "DISABLED" end)
            else "—" end)
        ' 2>/dev/null || console_warn 'Failed to print the summary.'
}
