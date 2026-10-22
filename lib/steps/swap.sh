#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг swap: файл подкачки, запись в /etc/fstab, vm.swappiness.
#
# DESCRIPTION
#     На машинах с 2-4 GiB RAM отсутствие подкачки - не экономия места, а гарантированный
#     OOM-killer при первой же сборке или пике нагрузки: ядро лишается возможности выгрузить
#     холодные страницы и убивает самый большой процесс, которым обычно оказывается JVM
#     или база данных, а не виновник нехватки памяти.
#
#     Порядок действий принципиален:
#       1. проверка свободного места ДО создания файла - иначе fallocate заполнит диск
#          под завязку и машина уйдёт в read-only;
#       2. chmod 600 ДО mkswap - swapon отказывается работать с файлом, доступным
#          на запись всем, и сообщение об этом неочевидно;
#       3. fallocate с откатом на dd: fallocate создаёт файл мгновенно, но на btrfs и
#          части конфигураций XFS оставляет "дыры", из-за которых swapon падает с
#          "swapfile has holes". dd медленнее, зато гарантирует настоящие блоки;
#       4. запись в /etc/fstab только после успешного swapon - иначе машина не загрузится
#          при следующем рестарте, если файл оказался нерабочим.
#
#     Шаг идемпотентен: при наличии активной подкачки он ничего не делает
#     (Swap.SkipIfAlreadyPresent), поэтому повторный прогон безопасен.

step_swap() {
    if ! config_section_enabled Swap; then
        step_skipped 'Swap.Enabled = false'
        return $?
    fi

    local path size_mb swappiness vfs_pressure min_free
    path="$(config_get '.Swap.FilePath' '/swapfile')"
    size_mb="$(config_get_int '.Swap.SizeMegabytes' 0)"
    swappiness="$(config_get_int '.Swap.Swappiness' 10)"
    vfs_pressure="$(config_get_int '.Swap.VfsCachePressure' 50)"
    min_free="$(config_get_int '.Swap.MinFreeDiskMegabytes' 4096)"

    if (( size_mb <= 0 )); then
        step_skipped 'Swap.SizeMegabytes = 0, no swap file will be created'
        return $?
    fi

    # Уже есть активная подкачка (любая, не обязательно наш файл).
    if [[ -n "$(swap_active_list)" ]]; then
        if config_get_bool '.Swap.SkipIfAlreadyPresent' true; then
            swap_apply_tuning "$swappiness" "$vfs_pressure"
            step_ok "swap is already active: $(swap_active_list | head -1 | awk '{print $1" "$2}')"
            return $?
        fi
        log_warn 'Swap already exists but SkipIfAlreadyPresent=false; creating an additional file.'
    fi

    local free_mb
    free_mb="$(sys_disk_free_mb "$(dirname "$path")")"
    if [[ -n "$free_mb" ]] && (( size_mb + min_free > free_mb )); then
        step_failed "needs ${size_mb} MiB for swap plus ${min_free} MiB reserve, only ${free_mb} MiB free"
        return $?
    fi

    if ! confirm_step_action "$path" "Create a ${size_mb} MiB swap file" Medium; then
        local rc=$?
        if (( rc == 2 )); then step_skipped '--what-if: swap not created'; return $?; fi
        step_skipped 'user declined to create swap'
        return $?
    fi

    if ! swap_create_file "$path" "$size_mb"; then
        step_failed "failed to create and enable ${path}"
        return $?
    fi

    swap_add_fstab_entry "$path"
    swap_apply_tuning "$swappiness" "$vfs_pressure"

    step_ok "${path} ${size_mb} MiB, swappiness=${swappiness}"
    return $?
}

swap_active_list() {
    if run_has swapon; then
        swapon --show=NAME,SIZE --noheadings 2>/dev/null || true
    else
        awk 'NR > 1 {print $1, $2/1024 "M"}' /proc/swaps 2>/dev/null || true
    fi
}

# Создаёт файл подкачки с откатом с fallocate на dd.
swap_create_file() {
    local path="$1" size_mb="$2"

    fs_ensure_dir "$(dirname "$path")" 755

    if [[ ! -f "$path" ]]; then
        if ! run_quiet fallocate -l "${size_mb}M" "$path"; then
            log_debug "fallocate failed for ${path}; falling back to dd."
            if ! run_cmd dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=none; then
                log_error "Failed to allocate ${size_mb} MiB for ${path}."
                return 1
            fi
        fi
    fi

    # Права выставляются до mkswap: swapon отвергает файл, читаемый не только root.
    if ! testmode_enabled; then
        chmod 600 "$path" 2>/dev/null || true
    fi
    testmode_journal file chmod "$path" "mode=600"

    run_cmd mkswap "$path" > /dev/null || {
        log_error "mkswap could not format ${path}."
        return 1
    }

    if ! run_cmd swapon "$path"; then
        # Типичная причина - "дыры" в файле после fallocate на btrfs/XFS.
        log_warn "swapon rejected ${path}; recreating the file with dd."
        if testmode_enabled; then
            testmode_journal file recreate "$path" "dd ${size_mb}M"
            return 0
        fi
        rm -f "$path"
        run_cmd dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=none || return 1
        chmod 600 "$path"
        run_cmd mkswap "$path" > /dev/null || return 1
        run_cmd swapon "$path" || return 1
    fi

    return 0
}

swap_add_fstab_entry() {
    local path="$1"
    local entry="${path} none swap sw 0 0"

    if fs_is_file /etc/fstab && fs_read /etc/fstab | grep -qE "^[^#]*[[:space:]]${path}[[:space:]]"; then
        log_debug "An entry for ${path} already exists in /etc/fstab."
        return 0
    fi

    fs_append_unique /etc/fstab "$entry"
}

# Параметры применяются немедленно: до перезагрузки машина должна вести себя
# так же, как после неё. Персистентная копия живёт в drop-in из шага sysctl.
swap_apply_tuning() {
    local swappiness="$1" vfs_pressure="$2"

    run_has sysctl || return 0
    run_quiet sysctl -w "vm.swappiness=${swappiness}" || log_warn "Failed to apply vm.swappiness=${swappiness}."
    run_quiet sysctl -w "vm.vfs_cache_pressure=${vfs_pressure}" || true
}
