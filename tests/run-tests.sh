#!/usr/bin/env bash
#
# SYNOPSIS
#     Запуск тестов проекта.
#
# DESCRIPTION
#     Обёртка над bats: ищет bats в системе или использует локальную копию,
#     проверяет наличие обязательных утилит и печатает итоговую сводку
#     с количеством пройденных и упавших тестов.
#
#     Тесты НЕ изменяют систему: все прогоны идут в --test-mode, а корректность
#     изоляции сама проверяется тестами (tests/testmode-isolation.bats).
#     Поэтому запускать их можно на боевой машине и в CI.
#
# АРГУМЕНТЫ
#     без аргументов       прогнать все тесты
#     <имя-файла.bats>     прогнать только указанный набор
#     --list               перечислить доступные наборы
#     --tap                вывод в формате TAP (для внешних систем отчётности)
#
# КОДЫ ВОЗВРАТА
#     0 - все тесты прошли
#     1 - есть упавшие тесты
#     2 - не найдены bats или обязательные утилиты

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BATS_BIN=''
TAP=false
TARGETS=()

find_bats() {
    local candidate
    for candidate in bats "${PROJECT_ROOT}/tests/bats/bin/bats" ./bats/bin/bats; do
        if command -v "$candidate" > /dev/null 2>&1 || [[ -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

usage() {
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            find "${SCRIPT_DIR}" -maxdepth 1 -name '*.bats' -printf '  %f\n' | sort
            exit 0
            ;;
        --tap)   TAP=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *)       TARGETS+=("$1"); shift ;;
    esac
done

if ! BATS_BIN="$(find_bats)"; then
    echo "[FATAL] bats не найден." >&2
    echo "        Установка: apt-get install bats   (Debian/Ubuntu)" >&2
    echo "                   dnf install bats       (RHEL/Fedora)" >&2
    echo "                   git clone https://github.com/bats-core/bats-core tests/bats" >&2
    exit 2
fi

# jq обязателен и для кода, и для тестов: без него не работает ни чтение
# конфигурации, ни валидатор схемы.
missing=()
for tool in jq awk sed grep find; do
    command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
done
if (( ${#missing[@]} > 0 )); then
    echo "[FATAL] Не найдены обязательные утилиты: ${missing[*]}" >&2
    exit 2
fi

if (( ${#TARGETS[@]} == 0 )); then
    while IFS= read -r -d '' f; do
        TARGETS+=("$f")
    done < <(find "${SCRIPT_DIR}" -maxdepth 1 -name '*.bats' -print0 | sort -z)
fi

echo "==================== ТЕСТЫ LinuxConfigurator ===================="
echo "bats     : ${BATS_BIN}"
echo "проект   : ${PROJECT_ROOT}"
echo "наборов  : ${#TARGETS[@]}"
echo "================================================================="
echo

declare -i total_failed=0
declare -i total_passed=0
declare -a failed_files=()

for target in "${TARGETS[@]}"; do
    if [[ ! -f "$target" ]]; then
        # Допускается имя набора без пути и без расширения.
        if [[ -f "${SCRIPT_DIR}/${target}" ]]; then
            target="${SCRIPT_DIR}/${target}"
        elif [[ -f "${SCRIPT_DIR}/${target}.bats" ]]; then
            target="${SCRIPT_DIR}/${target}.bats"
        else
            echo "[FATAL] Набор тестов не найден: ${target}" >&2
            exit 2
        fi
    fi

    echo "--- $(basename "$target") ---"
    output="$("$BATS_BIN" ${TAP:+--tap} "$target" 2>&1)"
    rc=$?
    printf '%s\n' "$output"

    # Итог берётся из сводной строки bats ("N tests, M failures"), а не подсчётом
    # маркеров: в pretty- и TAP-режимах маркеры разные, и подсчёт по ним давал бы
    # разные числа для одного и того же прогона.
    # bats переключается в TAP-формат, когда вывод не терминал (то есть всегда
    # в CI и при перенаправлении), и в pretty-формат при выводе в терминал.
    # Считаем оба варианта, иначе сводка пустая в одном из режимов.
    if grep -qE '^(ok|not ok) [0-9]+' <<< "$output"; then
        n_tests="$(grep -cE '^(ok|not ok) [0-9]+' <<< "$output" || true)"
        n_failed="$(grep -cE '^not ok [0-9]+' <<< "$output" || true)"
    else
        summary="$(grep -oE '[0-9]+ tests?, [0-9]+ failures?' <<< "$output" | tail -1)"
        n_tests="$(awk '{print $1}' <<< "${summary:-0 tests}")"
        n_failed="$(awk '{print $3}' <<< "${summary:-0 tests, 0 failures}")"
    fi
    n_skipped="$(grep -cE '^(ok [0-9]+.*# skip|.*# skip)' <<< "$output" || true)"

    # Явная арифметика вместо `var += expr`: для declare -i форма += зависит от
    # того, остались ли n_tests/n_failed числами, и при пустом значении молча
    # обнуляла итог.
    total_passed=$(( total_passed + n_tests - n_failed ))
    total_failed=$(( total_failed + n_failed ))
    echo "[..] ${n_tests} тестов, ${n_failed} упало, ${n_skipped} пропущено (skip)"

    if (( rc != 0 )); then
        failed_files+=("$(basename "$target")")
    fi
    echo
done

echo "======================== ИТОГ ПО ТЕСТАМ ========================"
echo "прошло тестов      : ${total_passed}"
echo "упало тестов       : ${total_failed}"
echo "наборов с ошибками : ${#failed_files[@]} из ${#TARGETS[@]}"
if (( ${#failed_files[@]} > 0 )); then
    printf '  - %s\n' "${failed_files[@]}"
fi
echo "==============================================================="

if (( ${#failed_files[@]} > 0 )); then
    exit 1
fi
exit 0
