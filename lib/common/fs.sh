#!/usr/bin/env bash
#
# SYNOPSIS
#     Файловые операции с учётом песочницы тестового режима.
#
# DESCRIPTION
#     Все шаги пишут на диск ТОЛЬКО через этот модуль. Это единственное место, где
#     известно про тестовый режим, поэтому ни один шаг не содержит ветвлений
#     "если тест - не писать": логика шага одинакова в обоих режимах, отличается
#     лишь точка записи.
#
#     Чтение работает через оверлей: сначала песочница, потом настоящая файловая
#     система. Без оверлея шаг, который перечитывает записанное (проверка sshd -t
#     по свежему drop-in, повторный запуск идемпотентного шага), в тестовом режиме
#     увидел бы старые данные и пошёл по другой ветке - тест перестал бы соответствовать
#     реальному прогону.
#
#     Перед изменением существующего файла создаётся резервная копия в каталоге
#     бэкапов (Backup.DirectoryPath из конфигурации), потому что конфигуратор правит
#     sshd_config, fstab и sysctl: ошибка в одном шаге не должна оставлять машину
#     без возможности откатиться.

declare -g LCFG_BACKUP_DIR=''

fs_set_backup_dir() {
    LCFG_BACKUP_DIR="$1"
}

# Возвращает путь, по которому файл виден сейчас: песочница перекрывает систему.
fs_resolve_read_path() {
    local path="$1"
    if testmode_enabled; then
        local sandboxed
        sandboxed="$(testmode_sandbox_path "$path")"
        if [[ -e "$sandboxed" ]]; then
            printf '%s' "$sandboxed"
            return 0
        fi
    fi
    printf '%s' "$path"
}

fs_is_file() {
    [[ -f "$(fs_resolve_read_path "$1")" ]]
}

fs_is_dir() {
    [[ -d "$(fs_resolve_read_path "$1")" ]]
}

fs_read() {
    local resolved
    resolved="$(fs_resolve_read_path "$1")"
    [[ -r "$resolved" ]] || return 1
    cat "$resolved"
}

fs_ensure_dir() {
    local path="$1"
    local mode="${2:-755}"

    if testmode_enabled; then
        local sandboxed
        sandboxed="$(testmode_sandbox_path "$path")"
        mkdir -p "$sandboxed"
        chmod "$mode" "$sandboxed" 2>/dev/null || true
        testmode_journal directory create "$path" "mode=${mode}"
        return 0
    fi

    mkdir -p "$path"
    chmod "$mode" "$path" 2>/dev/null || true
}

# Копирует существующий файл в каталог бэкапов, сохраняя исходное имя с меткой времени.
fs_backup() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    [[ -n "$LCFG_BACKUP_DIR" ]] || return 0

    if testmode_enabled; then
        testmode_journal backup copy "$path" "to=${LCFG_BACKUP_DIR}"
        return 0
    fi

    local stamp flat
    stamp="$(date '+%Y%m%d-%H%M%S')"
    flat="$(printf '%s' "$path" | tr '/' '_')"
    mkdir -p "$LCFG_BACKUP_DIR" 2>/dev/null || return 0
    cp -a "$path" "${LCFG_BACKUP_DIR}/${flat}.${stamp}" 2>/dev/null || true
    log_debug "Резервная копия: ${path} -> ${LCFG_BACKUP_DIR}/${flat}.${stamp}"
}

# Записывает файл целиком.
#
# Аргументы:
#   $1 - путь
#   $2 - содержимое
#   $3 - права (необязательно, по умолчанию 644)
#   $4 - владелец user:group (необязательно)
fs_write() {
    local path="$1"
    local content="$2"
    local mode="${3:-644}"
    local owner="${4:-}"

    if testmode_enabled; then
        local sandboxed
        sandboxed="$(testmode_sandbox_path "$path")"
        mkdir -p "$(dirname "$sandboxed")"
        printf '%s' "$content" > "$sandboxed"
        chmod "$mode" "$sandboxed" 2>/dev/null || true
        testmode_journal file write "$path" "mode=${mode} bytes=${#content}"
        return 0
    fi

    if [[ -f "$path" ]]; then
        fs_backup "$path"
    fi

    mkdir -p "$(dirname "$path")"
    # Сначала временный файл в том же каталоге, затем mv: целевой файл никогда
    # не оказывается наполовину записанным, если процесс убьют посреди записи.
    local tmp="${path}.lcfg-tmp.$$"
    printf '%s' "$content" > "$tmp"
    chmod "$mode" "$tmp" 2>/dev/null || true
    if [[ -n "$owner" ]]; then
        chown "$owner" "$tmp" 2>/dev/null || true
    fi
    mv -f "$tmp" "$path"
    log_debug "Записан файл ${path} (${#content} байт, mode=${mode})"
}

# Дописывает в конец файла, создавая его при необходимости.
#
# Перед дописыванием гарантируется перевод строки в конце существующего содержимого.
# Без этого запись в файл, последняя строка которого не закончена переводом строки,
# склеивается с ней: для /etc/fstab это означает повреждённую запись вида
# "/dev/sda1 / ext4 defaults 0 1/swapfile none swap sw 0 0" и незагружающуюся
# машину. Файлы без завершающего перевода строки встречаются чаще, чем кажется -
# их оставляют и ручные правки, и некоторые генераторы.
fs_append() {
    local path="$1"
    local content="$2"

    if testmode_enabled; then
        local sandboxed
        sandboxed="$(testmode_sandbox_path "$path")"
        mkdir -p "$(dirname "$sandboxed")"
        fs_ensure_trailing_newline "$sandboxed"
        printf '%s' "$content" >> "$sandboxed"
        testmode_journal file append "$path" "bytes=${#content}"
        return 0
    fi

    mkdir -p "$(dirname "$path")"
    fs_ensure_trailing_newline "$path"
    printf '%s' "$content" >> "$path"
}

# Дописывает один перевод строки, если файл непустой и не заканчивается им.
fs_ensure_trailing_newline() {
    local path="$1"
    [[ -s "$path" ]] || return 0
    # tail -c1 | wc -l даёт 1, когда последний байт - перевод строки, иначе 0.
    if [[ "$(tail -c1 "$path" 2>/dev/null | wc -l)" -eq 0 ]]; then
        printf '\n' >> "$path"
    fi
}

# Дописывает строку только если её там ещё нет - основа идемпотентности шагов.
fs_append_unique() {
    local path="$1"
    local line="$2"

    if fs_is_file "$path" && fs_read "$path" | grep -qxF -- "$line"; then
        return 0
    fi
    fs_append "$path" "${line}"$'\n'
}

fs_remove() {
    local path="$1"
    if testmode_enabled; then
        testmode_journal file remove "$path"
        return 0
    fi
    rm -rf -- "$path"
}
