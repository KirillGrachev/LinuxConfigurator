#!/usr/bin/env bash
#
# SYNOPSIS
#     Реестр шагов: имена, функции, описания, требования к правам, уровень риска, алиасы.
#
# DESCRIPTION
#     Единственное место, где перечислены существующие шаги. Оркестратор, меню,
#     справка и тесты читают список отсюда, поэтому добавление шага - это запись
#     в step_definitions плюс файл lib/steps/<имя>.sh с функцией step_<имя>.
#
#     Формат записи (TSV, 5 полей):
#       имя \t функция \t описание \t требует_root \t уровень риска
#
#     Порядок строк определяет ПОРЯДОК ВЫПОЛНЕНИЯ по умолчанию, если
#     General.DefaultSteps в конфигурации не задан. Порядок выбран не случайно:
#       - hostname и time идут первыми: от них зависят имена в логах и корректность
#         временных меток всех последующих записей;
#       - swap и sysctl - до пакетов: установка пакетов на машине без подкачки
#         при 2 GiB RAM может убить процесс apt средствами OOM-killer;
#       - users - до ssh: sshd-hardening отключает вход по паролю, и если к этому
#         моменту не создан пользователь с ключом, доступ к машине теряется;
#       - firewall - после ssh и users: к моменту включения policy drop ключ уже
#         должен работать, иначе блокируется единственный канал управления;
#       - cleanup и report - в конце.
#
#     Алиасы нужны потому, что в конфигурациях и в привычках имена шагов расходятся
#     (sshd/ssh, fw/firewall, ntp/time). Алиас разрешается в каноническое имя,
#     а неизвестное имя - ошибка запуска с кодом 2, а не тихий пропуск.

step_definitions() {
    cat <<'TSV'
hostname	step_hostname	Machine name and the /etc/hosts entry	false	Low
time	step_time	Timezone, locale and time synchronization	true	Low
swap	step_swap	Swap file, vm.swappiness and the /etc/fstab entry	true	Medium
sysctl	step_sysctl	Kernel parameters: tuning and hardening	true	Medium
limits	step_limits	Descriptor limits for systemd and PAM	true	Low
packages	step_packages	Package install and removal	true	Medium
users	step_users	Users, groups, sudo and SSH keys	true	High
ssh	step_ssh	 Hardening sshd: keys only, attempt limits	true	High
firewall	step_firewall	nftables: INPUT policy and open ports	true	High
fail2ban	step_fail2ban	Password brute-force blocking	true	Medium
updates	step_updates	Automatic security updates	true	Medium
logging	step_logging	journald limits and logrotate rules	true	Low
docker	step_docker	Docker: install, log rotation, limits	true	Medium
motd	step_motd	Login banner	true	Low
cleanup	step_cleanup	Package, old kernel and temp file cleanup	true	Medium
report	step_report	Machine state summary	false	Low
TSV
}

# Алиасы шагов: alias \t canonical
step_aliases() {
    cat <<'TSV'
host	hostname
hostnamectl	hostname
ntp	time
timezone	time
locale	time
kernel	sysctl
sysctl.d	sysctl
nofile	limits
ulimit	limits
pkgs	packages
apt	packages
sudo	users
admin	users
sshd	ssh
ssh_hardening	ssh
nftables	firewall
fw	firewall
f2b	fail2ban
unattended	updates
auto-updates	updates
journald	logging
logs	logging
logrotate	logging
container	docker
containers	docker
banner	motd
autoremove	cleanup
summary	report
TSV
}

# Разрешает имя или алиас в каноническое имя шага.
# Возвращает 1, если такое имя не известно.
step_resolve() {
    local name="${1,,}"
    local canonical

    canonical="$(step_definitions | awk -F'\t' -v n="$name" '$1 == n {print $1; exit}')"
    if [[ -n "$canonical" ]]; then
        printf '%s' "$canonical"
        return 0
    fi

    canonical="$(step_aliases | awk -F'\t' -v n="$name" '$1 == n {print $2; exit}')"
    if [[ -n "$canonical" ]]; then
        printf '%s' "$canonical"
        return 0
    fi

    return 1
}

step_field() {
    local name="$1" field_index="$2"
    step_definitions | awk -F'\t' -v n="$name" -v i="$field_index" '$1 == n {print $i; exit}'
}

step_description()  { step_field "$1" 3; }
step_needs_root()   { step_field "$1" 4; }
step_impact()       { step_field "$1" 5; }

step_list_names() {
    step_definitions | awk -F'\t' '{print $1}'
}

step_exists() {
    local resolved
    resolved="$(step_resolve "$1")" || return 1
    [[ -n "$resolved" ]]
}

# Печатает таблицу шагов для меню и для --help.
step_print_table() {
    local name description impact
    printf '%-12s %-6s %s\n' 'STEP' 'RISK' 'DESCRIPTION'
    while IFS=$'\t' read -r name _ description _ impact; do
        [[ -n "$name" ]] || continue
        printf '%-12s %-6s %s\n' "$name" "$impact" "$description"
    done < <(step_definitions)
}
