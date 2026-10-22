#!/usr/bin/env bash
#
# SYNOPSIS
#     Оркестратор: выполняет шаги по списку, измеряет время, собирает сводку.
#
# DESCRIPTION
#     Не содержит прикладной логики - только порядок выполнения и обработку итогов.
#
#     Поведение:
#       - имена шагов разрешаются через реестр (алиасы поддерживаются); неизвестное имя
#         прерывает запуск с кодом 2, а не пропускается молча: опечатка в конфигурации
#         должна быть видна сразу, иначе машина останется ненастроенной, а отчёт зелёным;
#       - каждый шаг выполняется в подоболочке? НЕТ - намеренно в текущей: шаги читают
#         и дополняют общее состояние (конфигурация, журнал песочницы, счётчики),
#         а изоляция потребовала бы сериализовать его на каждом вызове;
#       - ошибка шага не прерывает прогон, если General.StopOnFirstFailure = false:
#         типичный сценарий - одна настройка не применилась, но остальные десять важны;
#       - General.StepDelaySeconds задаёт паузу между шагами: на медленных дисках
#         подряд идущие apt-get и systemctl успевают упереться в IO.

declare -g LCFG_STEP_NAME=''

orchestrator_run_steps() {
    local list="$1"
    local -a names=()
    local item resolved
    local stop_on_failure delay

    IFS=',' read -r -a names <<< "$(printf '%s' "$list" | tr -d '[:space:]')"

    if (( ${#names[@]} == 0 )); then
        console_fatal 'The step list is empty.'
        return 2
    fi

    # Разрешаем все имена ДО первого выполнения: запуск не должен наполовину
    # отработать и остановиться на пятом шаге из-за опечатки в шестом.
    local -a resolved_names=()
    for item in "${names[@]}"; do
        [[ -n "$item" ]] || continue
        if ! resolved="$(step_resolve "$item")"; then
            console_fatal "Unknown step: '${item}'."
            console_fatal "Available steps: $(step_list_names | paste -sd, -)"
            return 2
        fi
        resolved_names+=("$resolved")
    done

    # Список мог состоять только из разделителей (" , , "). Без этой проверки
    # запуск молча ничего не делал и возвращал 0, то есть опечатка в --run-steps
    # выглядела как успешно настроенная машина.
    if (( ${#resolved_names[@]} == 0 )); then
        console_fatal 'The step list is empty after parsing (separators or spaces only).'
        console_fatal "Available steps: $(step_list_names | paste -sd, -)"
        return 2
    fi

    # Статус, а не строка: $(config_get_bool ...) дал бы пустое значение,
    # и General.StopOnFirstFailure молча игнорировался бы при любом значении.
    if config_get_bool '.General.StopOnFirstFailure' false; then stop_on_failure=true; else stop_on_failure=false; fi
    delay="$(config_get_int '.General.StepDelaySeconds' 0)"

    local idx=0 total="${#resolved_names[@]}"
    for resolved in "${resolved_names[@]}"; do
        ((idx++)) || true
        # || rc=$? обязателен: без него set -e прервал бы прогон на первой же
        # ошибке шага, хотя StopOnFirstFailure по умолчанию выключен.
        local rc=0
        orchestrator_run_one "$resolved" "$idx" "$total" || rc=$?

        if (( rc != 0 )) && [[ "$stop_on_failure" == true ]]; then
            log_warn "StopOnFirstFailure=true: the run stopped at step '${resolved}'."
            break
        fi

        if (( idx < total )) && [[ "$delay" =~ ^[0-9]+$ ]] && (( delay > 0 )); then
            runtime_flag test_mode || sleep "$delay"
        fi
    done

    orchestrator_finalize
    return $?
}

orchestrator_run_default_steps() {
    local -a steps=()
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] && steps+=("$line")
    done < <(config_get_array '.General.DefaultSteps')

    if (( ${#steps[@]} == 0 )); then
        log_warn 'General.DefaultSteps is empty; using the registry order.'
        while IFS= read -r line; do
            [[ -n "$line" ]] && steps+=("$line")
        done < <(step_list_names)
    fi

    orchestrator_run_steps "$(IFS=,; echo "${steps[*]}")"
}

# Выполняет один шаг.
# Аргументы: каноническое имя, номер по порядку, всего шагов.
orchestrator_run_one() {
    local name="$1" index="$2" total="$3"
    local func description needs_root
    local t0 t1 elapsed_ms rc=0

    func="step_${name}"
    description="$(step_description "$name")"
    needs_root="$(step_needs_root "$name")"

    console_plain ''
    console_info "(${index}/${total}) ${name}: ${description}"

    if ! declare -F "$func" > /dev/null 2>&1; then
        # Уровень Fatal, а не Error: шаг объявлен в реестре, но функции нет -
        # это рассогласование кода и реестра, а не сбой на конкретной машине.
        log_fatal "Step '${name}' is registered but function ${func} is not defined."
        runtime_add_result "$name" Failed "function ${func} not found" 0
        return 1
    fi

    if [[ "$needs_root" == true ]] && [[ "$(id -u)" -ne 0 ]] && ! runtime_flag test_mode; then
        runtime_add_result "$name" Skipped 'requires root' 0
        console_skip "${name}: requires root privileges."
        return 0
    fi

    LCFG_STEP_NAME="$name"
    step_reset_message

    t0="${EPOCHREALTIME/./}"
    # Шаг сам решает, что считать ошибкой; set -e внутри шага отключать нельзя,
    # поэтому непредвиденная ошибка интерпретируется как Failed, а не роняет прогон.
    "$func" || rc=$?
    t1="${EPOCHREALTIME/./}"
    elapsed_ms=$(( (t1 - t0) / 1000 ))

    local status
    case "$rc" in
        "$LC_RC_SUCCESS") status='Success' ;;
        "$LC_RC_SKIPPED") status='Skipped' ;;
        "$LC_RC_FAILED")  status='Failed' ;;
        *)
            status='Failed'
            if [[ -z "$LCFG_STEP_MESSAGE" ]]; then
                LCFG_STEP_MESSAGE="step exited with code ${rc}"
            fi
            ;;
    esac

    [[ -n "$LCFG_STEP_MESSAGE" ]] || LCFG_STEP_MESSAGE="$status"

    runtime_add_result "$name" "$status" "$LCFG_STEP_MESSAGE" "$elapsed_ms"

    # Дополнительные данные шага не попадают в сводку (она должна оставаться
    # однострочной), но уходят в журнал - именно там их ищут при разборе инцидента.
    if [[ -n "$LCFG_STEP_DATA" ]]; then
        log_debug "${name}: ${LCFG_STEP_DATA}"
    fi

    case "$status" in
        Success) console_ok   "${name}: ${LCFG_STEP_MESSAGE}" ;;
        Skipped) console_skip "${name}: ${LCFG_STEP_MESSAGE}" ;;
        Failed)  console_fail "${name}: ${LCFG_STEP_MESSAGE}" ;;
    esac

    if [[ "$status" == Failed ]]; then
        return 1
    fi
    return 0
}

# Завершает прогон: отчёт тестового режима, сводка, код возврата.
orchestrator_finalize() {
    if testmode_enabled; then
        testmode_write_report > /dev/null
        testmode_print_summary
    fi

    if runtime_print_summary; then
        return 0
    fi
    return 1
}
