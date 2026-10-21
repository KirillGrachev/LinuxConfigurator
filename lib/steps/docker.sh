#!/usr/bin/env bash
#
# SYNOPSIS
#     Шаг docker: установка (опционально), ротация логов и лимиты демона.
#
# DESCRIPTION
#     По умолчанию шаг ОТКЛЮЧЁН (Docker.Enabled = false): базовая настройка не обязана
#     ставить контейнерный рантайм на каждую машину. Включается в конфигурации.
#
#     Главная проблема, которую шаг решает, - логи контейнеров. Драйвер json-file
#     без ограничений пишет в /var/lib/docker/containers/*/*-json.log бесконечно, и
#     на диске в 40 ГБ один разговорчивый контейнер заполняет его за дни. Ограничение
#     задаётся в daemon.json и применяется только к НОВЫМ контейнерам: существующие
#     сохраняют прежние настройки до пересоздания, о чём шаг явно предупреждает.
#
#     daemon.json собирается из отдельных полей конфигурации, а не отдаётся как
#     готовый JSON-кусок: валидность результата проверяется через jq до записи,
#     и опечатка в конфигурации не может превратить файл в нечитаемый для dockerd.
#     Ошибка в daemon.json - это docker, который не стартует вовсе.
#
#     userland-proxy=false убирает лишний процесс docker-proxy на каждый
#     опубликованный порт и переключает проброс на правила DNAT.
#
#     AdminGroupAccess намеренно false: членство в группе docker эквивалентно root
#     (монтирование /host в контейнер даёт полный доступ), и добавлять туда
#     администратора по умолчанию - значит незаметно выдать root-права.
#     Используется sudo docker.

step_docker() {
    if ! config_section_enabled Docker; then
        step_skipped 'Docker.Enabled = false'
        return $?
    fi

    local family
    family="$(pkg_family)"

    if [[ "$family" != debian && "$family" != rhel ]]; then
        step_skipped "автоматическая установка Docker поддержана для Debian/RHEL, обнаружено '${family}'"
        return $?
    fi

    local -a done_parts=()

    if config_get_bool '.Docker.Install' false && ! run_has docker; then
        if docker_install "$family"; then
            done_parts+=('docker=установлен')
        else
            step_failed 'Docker не установился'
            return $?
        fi
    elif run_has docker; then
        done_parts+=("docker=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')")
    else
        step_skipped 'docker не установлен и Docker.Install = false'
        return $?
    fi

    if ! docker_write_daemon_json; then
        step_failed 'daemon.json не прошёл проверку и не записан'
        return $?
    fi
    done_parts+=('daemon.json=записан')

    if config_get_bool '.Docker.InstallComposePlugin' true && [[ "$family" == debian ]]; then
        if ! dpkg -s docker-compose-plugin > /dev/null 2>&1; then
            if pkg_install docker-compose-plugin; then
                done_parts+=('compose=установлен')
            else
                log_warn 'docker-compose-plugin не установился.'
            fi
        fi
    fi

    if config_get_bool '.Docker.AdminGroupAccess' false; then
        local admin
        admin="$(config_get '.Users.Admin.Name' '')"
        if [[ -n "$admin" ]] && id "$admin" > /dev/null 2>&1; then
            run_quiet usermod -aG docker "$admin" && \
                done_parts+=('группа docker=выдана (ВНИМАНИЕ: эквивалент root)')
        fi
    fi

    if config_get_bool '.Docker.RestartAfterConfigure' true; then
        if run_quiet systemctl restart docker; then
            done_parts+=('docker=перезапущен')
        else
            step_failed 'dockerd не запустился после применения daemon.json - проверьте файл'
            return $?
        fi
        # Существующие контейнеры не подхватывают новые настройки логов.
        if ! testmode_enabled; then
            local existing
            existing="$(docker ps -aq 2>/dev/null | wc -l)"
            if (( existing > 0 )); then
                log_warn "Существующих контейнеров: ${existing}. Новые лимиты логов применятся только после их пересоздания."
            fi
        fi
    fi

    step_ok "$(IFS=', '; echo "${done_parts[*]}")"
    return $?
}

# Установка из официального репозитория Docker, а не из репозитория дистрибутива:
# пакет docker.io в Debian/Ubuntu отстаёт на несколько мажорных версий.
docker_install() {
    local family="$1"
    local keyring='/etc/apt/keyrings/docker.asc'

    if [[ "$family" != debian ]]; then
        log_warn "Автоматическая установка для семейства '${family}' не реализована - используйте пакетный менеджер дистрибутива."
        return 1
    fi

    fs_ensure_dir '/etc/apt/keyrings' 755

    if testmode_enabled; then
        testmode_journal command install-repo 'download.docker.com' "keyring=${keyring}"
        run_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        return 0
    fi

    if [[ ! -f "$keyring" ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg || {
            log_error 'Не удалось скачать GPG-ключ Docker.'
            return 1
        }
        gpg --dearmor --yes -o "$keyring" /tmp/docker.gpg || return 1
        rm -f /tmp/docker.gpg
        chmod 644 "$keyring"
    fi

    local codename
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}")"
    fs_write '/etc/apt/sources.list.d/docker.list' \
        "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://download.docker.com/linux/ubuntu ${codename} stable
" 644 root:root

    pkg_update_index
    DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# Собирает daemon.json и проверяет его jq'ом ДО записи.
docker_write_daemon_json() {
    local path json
    path="$(config_get '.Docker.DaemonJsonPath' '/etc/docker/daemon.json')"

    json="$(jq -n \
        --arg driver   "$(config_get '.Docker.LogDriver' 'json-file')" \
        --arg maxsize  "$(config_get '.Docker.LogMaxSize' '50m')" \
        --argjson maxfile "$(config_get_int '.Docker.LogMaxFile' 3)" \
        --argjson compress "$(config_get_bool '.Docker.LogCompress' true && echo true || echo false)" \
        --argjson proxy "$(config_get_bool '.Docker.UserlandProxy' false && echo true || echo false)" \
        --argjson nofile  "$(config_get_int '.Docker.DefaultNofile' 65536)" \
        '{
            "log-driver": $driver,
            "log-opts": {
                "max-size": $maxsize,
                "max-file": ($maxfile | tostring),
                "compress": ($compress | tostring)
            },
            "userland-proxy": $proxy,
            "default-ulimits": {
                "nofile": { "Name": "nofile", "Hard": $nofile, "Soft": $nofile }
            }
        }')" || {
        log_error 'Не удалось собрать daemon.json.'
        return 1
    }

    # Двойная проверка: jq -n уже гарантирует валидность, но файл может существовать
    # с содержимым от предыдущей ручной настройки - предупреждаем о перезаписи.
    if fs_is_file "$path"; then
        local existing
        existing="$(fs_read "$path" 2>/dev/null || true)"
        if [[ -n "$existing" && "$existing" != "$json" ]]; then
            log_warn "Существующий ${path} будет перезаписан (резервная копия создаётся автоматически)."
        fi
    fi

    fs_ensure_dir "$(dirname "$path")" 755
    fs_write "$path" "${json}"$'\n' 644 root:root
    return 0
}
