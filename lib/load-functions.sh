#!/usr/bin/env bash
#
# SYNOPSIS
#     Загружает все функции проекта в текущую оболочку.
#
# DESCRIPTION
#     Единственное место, где перечислены файлы lib/. Порядок важен и отражает
#     зависимости: сначала примитивы (журнал, песочница, обёртки команд), затем
#     работа с конфигурацией, затем реестр шагов и сами шаги, в конце - меню.
#
#     Файлы подключаются через source, а не запускаются как процессы: шаги обмениваются
#     состоянием через переменные оболочки (результаты, журнал, конфигурация), а межпроцессный
#     обмен потребовал бы сериализации на каждом вызове.
#
#     Список собирается через glob, поэтому новый файл в lib/common или lib/steps
#     подхватывается автоматически и его не нужно регистрировать здесь вручную.
#     Исключение - steps/registry.sh: он грузится до остальных шагов, потому что
#     определяет порядок и алиасы, на которые эти шаги ссылаются.

# shellcheck disable=SC2034  # LC_LOADER_ROOT используется подключаемыми файлами
LC_LOADER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

lcfg_source_dir() {
    local dir="$1"
    local skip="${2:-}"
    local file

    [[ -d "$dir" ]] || return 0

    while IFS= read -r -d '' file; do
        [[ "$(basename "$file")" == "$skip" ]] && continue
        # shellcheck disable=SC1090
        source "$file" || {
            echo "[FATAL] Ошибка загрузки ${file}" >&2
            return 1
        }
    done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)
}

# Примитивы: журнал, песочница тестового режима, обёртки команд и файлового ввода-вывода.
lcfg_source_dir "${LC_LOADER_ROOT}/common" || return 1

# Конфигурация: чтение, валидация по схеме, нормализация, секреты.
lcfg_source_dir "${LC_LOADER_ROOT}/config" || return 1

# Реестр шагов грузится раньше самих шагов: он задаёт порядок и алиасы.
# shellcheck source=steps/registry.sh
source "${LC_LOADER_ROOT}/steps/registry.sh" || return 1

# Шаги: по одному файлу на шаг.
lcfg_source_dir "${LC_LOADER_ROOT}/steps" 'registry.sh' || return 1

# Интерактивное меню.
lcfg_source_dir "${LC_LOADER_ROOT}/menu" || return 1

unset -f lcfg_source_dir
