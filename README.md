# LinuxConfigurator

One run, reproducible baseline setup for a Linux server: the steps every machine
needs no matter what ends up running on it, a Java service, a database, a proxy.

A single JSON file describes the setup. It is checked against a schema before
anything on disk changes, and applied idempotently. Any run can be previewed in
test mode first: the full step logic executes, the system stays untouched.

Direct counterpart of [WindowsConfigurator](https://github.com/KirillGrachev/WindowsConfigurator):
same architecture, thin entry point, step registry, schema-backed configuration,
`-TestMode`, one result type per step, exit codes `0/1/2`.

---

## Why

Setting up a server by hand from memory does not reproduce well, and it tends to
break in the same places:

| What hand setup does | How it ends |
|---|---|
| No swap, because "memory looks fine" | First load spike: the OOM killer picks the largest process (usually the JVM or the database), not the one that caused the shortage |
| sshd edited in `sshd_config` while the cloud image ships `sshd_config.d/50-cloud-init.conf` with `PasswordAuthentication yes` | Password login keeps working and the hardening is worth nothing |
| The packaged `/etc/nftables.conf` enabled as is | It starts with `flush ruleset` and drops the Docker and fail2ban tables: containers lose network, bans stop applying |
| `sysctl --system` in a single call | One key this kernel does not have stops every other key from applying |
| needrestart left in interactive mode | `apt` asks a question mid-upgrade when libraries change, and an unattended run hangs forever |
| journald left unlimited | The journal grows to 10% of the filesystem; on a 40 GB disk that is 4 GB, and the disk ends read-only |
| `unattended-upgrades` installed but not configured | Security updates never install: the package is there, the timers are there, the periodic config is empty |

The configurator does these the same way every time, and the decisions that are
easy to get wrong are pinned down by tests.

---

## Requirements

- bash **5.0+** (`declare -A`, `${var,,}`, `EPOCHREALTIME`);
- **jq**, the only hard dependency: it reads both the configuration and the schema;
- root or `sudo`, except `--test-mode` and `--validate-config`, which run as any user;
- Debian 11/12, Ubuntu 20.04/22.04/24.04, RHEL/Rocky/Alma 8/9.

Steps specific to one distribution family report `[SKIP]` on another family
instead of failing: a run across a mixed fleet should not need a separate config
per family.

Optional, for the steps that use them: `nft`, `sshd`, `visudo`, `fail2ban`,
`logrotate`, `ssh-keygen`, `docker`.

Check that the machine is ready:

```bash
./configure-linux.sh --validate-config
```

---

## Quick start

```bash
git clone https://github.com/KirillGrachev/LinuxConfigurator.git
cd LinuxConfigurator

# 1. Set the hostname and pass your public SSH key.
#    Without a key the ssh step refuses to disable password login: that is the lockout guard.
jq '.Hostname.Name = "my-server"' config/config.json > /tmp/my.json
export LCFG_ADMIN_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)"

# 2. Run in test mode: all logic executes, nothing on the system changes.
./configure-linux.sh --test-mode --run-all --config /tmp/my.json

# 3. Read back the exact commands it would have run.
less /tmp/LCFG-TestMode-*/journal.tsv

# 4. Apply for real.
sudo -E ./configure-linux.sh --run-all --config /tmp/my.json
```

`sudo -E` keeps the environment, including the `LCFG_*` variables that carry
secrets. Without `-E` they never reach the configurator.

---

## Safety

### Test mode (`--test-mode`)

The whole step logic runs with every side effect simulated:

- **commands are not executed**: the exact command line goes to `journal.tsv`,
  exit codes and output come from fixtures (`0` and empty by default);
- **files are written to a sandbox** at `/tmp/LCFG-TestMode-*`, mirroring the
  absolute path (`etc/ssh/sshd_config.d/...`);
- **reads stay real**: decisions are made from the actual state of the machine,
  otherwise the test would prove nothing;
- the run ends with **`testmode-report.json`**: counters per category plus the
  full operation journal.

No root required. Test mode lives in one place, the `run_cmd` and `fs_*`
wrappers, so steps contain no "if test mode, skip writing" branches: the step
logic is literally the same in both modes.

```bash
./configure-linux.sh --test-mode --run-all
jq '.counters' /tmp/LCFG-TestMode-*/testmode-report.json
```

The isolation promise has its own tests (`tests/testmode-isolation.bats`):
fingerprints of critical configs before and after, no new files at known paths,
no armed systemd timers.

### `--what-if`

Prints the planned actions and executes nothing. Unlike `--test-mode` it keeps
no journal and builds no sandbox: a quick look at the plan, not a logic run.

### Automatic rollback

The `ssh` and `firewall` steps are the only ones that can cut access to the
machine with no way to fix it over the network. Both carry a guard:

1. current configuration is copied to the backup directory;
2. **a timer is armed** with `systemd-run --on-active=N` to restore the saved
   configuration and reload the service;
3. the new settings are applied;
4. verification runs: `sshd -t` / `nft -c -f`, then reload and **a fresh
   connection to 127.0.0.1** (ssh), or a table-loaded check plus sshd port
   reachability over loopback (firewall);
5. the timer is disarmed only after verification passes.

`systemd-run`, not `trap`: a trap never fires if the OOM killer takes the
machine, the network drops, or the process dies with the ssh session.

Durations come from `Ssh.RollbackGuardSeconds` (default 300) and
`Firewall.RollbackGuardSeconds` (default 180). `0` disables the guard; do not do
that on a remote machine.

### Lockout protection at the configuration level

- `firewall` refuses to apply a port set that lacks the sshd port
  (`Firewall.ProtectSshPort`);
- `ssh` refuses to disable password login while no user has `authorized_keys`;
- the step order `users -> ssh -> firewall` is pinned by a test.

---

## Steps

| Step | Risk | What it does |
|---|---|---|
| `hostname` | Low | Machine name and the `127.0.1.1` entry in `/etc/hosts` |
| `time` | Low | Timezone, locale, NTP (chrony with fallback to `systemd-timesyncd`) |
| `swap` | Medium | Swap file, `fstab` entry, `vm.swappiness` |
| `sysctl` | Medium | Drop-in under `/etc/sysctl.d/`, each key applied individually |
| `limits` | Low | `DefaultLimitNOFILE` for systemd **and** `limits.d` for PAM |
| `packages` | Medium | Install and remove packages from per-family lists |
| `users` | **High** | Admin account, groups, sudoers, SSH keys |
| `ssh` | **High** | sshd hardening via drop-in, cloud-init neutralized |
| `firewall` | **High** | nftables table with `policy drop` on INPUT |
| `fail2ban` | Medium | Jail configuration as a drop-in |
| `updates` | Medium | `unattended-upgrades`, needrestart, old kernels |
| `logging` | Low | journald limits and logrotate rules |
| `docker` | Medium | Install (optional), `daemon.json`, container log rotation |
| `motd` | Low | Login banner |
| `cleanup` | Medium | autoremove, package cache, journal vacuum, `/boot` check |
| `report` | Low | Summary of the actual machine state |

Risk level drives confirmation prompts: with `General.ConfirmImpact` above
`Low`, `High` steps ask for confirmation when stdin is a terminal.

### Order, and why

The registry order is not alphabetical and a test
(`tests/project-structure.bats`) keeps it that way:

```
hostname, time     -> log names and timestamps of everything below depend on
                      them; clock skew breaks TLS handshakes ("certificate not
                      yet valid")
swap, sysctl       -> before packages: installing packages on a 2 GiB machine
                      without swap can get apt killed by the OOM killer
users              -> before ssh: ssh disables password login, and without an
                      installed key the machine loses its only control channel
ssh                -> before firewall: policy drop switches on only after key
                      access is proven by a fresh connection
cleanup, report    -> last: autoremove before install would delete the
                      dependencies just placed
```

`General.DefaultSteps` in the configuration must match this order; a test
checks that too.

### Aliases

Configs and habits disagree about step names, so aliases exist: `sshd`->`ssh`,
`fw`/`nftables`->`firewall`, `ntp`/`timezone`->`time`, `f2b`->`fail2ban`,
`journald`/`logs`->`logging`, `apt`/`pkgs`->`packages`, and a few more. The full
list is `step_aliases` in `lib/steps/registry.sh`.

An unknown name is a startup error with code `2`, not a silent skip: a typo
should surface immediately, otherwise the machine stays unconfigured while the
report looks green.

---

## Run modes

```bash
./configure-linux.sh --run-all                        # steps from General.DefaultSteps
./configure-linux.sh --run-steps ssh,firewall,fail2ban # only the listed steps
./configure-linux.sh --interactive                    # step selection menu
./configure-linux.sh --validate-config                # schema check only
./configure-linux.sh --test-mode --run-all            # simulate everything
./configure-linux.sh --what-if --run-steps packages   # plan only
./configure-linux.sh --run-all --yes --verbose        # no prompts, Debug to the log
```

| Flag | Purpose |
|---|---|
| `--run-all` | run the steps from `General.DefaultSteps` |
| `--run-steps LIST` | run only the listed steps (comma separated, aliases allowed) |
| `--interactive` | interactive menu |
| `--config PATH` | configuration path (default `config/config.json`) |
| `--validate-config` | validate the configuration against the schema and exit |
| `--log PATH` | override `Logging.FilePath` |
| `--user NAME` | target user for profile-aware steps |
| `--test-mode` | simulate all side effects |
| `--what-if` | print the plan only |
| `--yes`, `-y` | skip confirmation prompts |
| `--verbose`, `-v` | Debug log level |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | every step succeeded (or only a config validation was requested) |
| `1` | some steps failed: see the summary and the log |
| `2` | startup error: configuration failed validation, no root, unknown step, required tool missing |

This is a contract for automation. `1` and `2` differ on purpose: `1` means
"the machine is partially configured", `2` means "configuration never started".

---

## Configuration

One file, `config/config.json`, checked against `config/config.schema.json`
**before anything changes**. The validator is jq and covers a JSON Schema
subset: `type`, `enum`, `minimum`/`maximum`, `pattern`, `minLength`, `required`,
`properties`, `items`.

Error messages carry the full field path:

```
$.Ssh.MaxAuthTries: value 99 exceeds the allowed maximum of 10
$.Firewall.AllowedTcpPorts[1]: value 99999 exceeds the allowed maximum of 65535
$.Logrotate.Rules[0]: required field "Path" is missing
$.Time.Ntp.Preferred: value "ntp4" is not in the allowed list ["chrony","systemd-timesyncd","ntpd"]
```

Keep the copy with real values elsewhere: `config/*.local.json` is in
`.gitignore`:

```bash
jq '.Hostname.Name = "prod-01"' config/config.json > config/config.local.json
```

### Sections

| Section | Purpose |
|---|---|
| `Meta` | Config version, `IsTestData`, environment, owner |
| `General` | `DefaultSteps`, `StopOnFirstFailure`, `StepDelaySeconds`, `ConfirmImpact` |
| `Logging` | Level, log path, `RetentionDays` |
| `Backup` | Directory holding copies of modified files |
| `Secrets` | Provider, environment variable prefix, `BlockTestDataSecrets` |
| `Hostname` | Machine name, `/etc/hosts` edit, old name as alias |
| `Time` | Timezone, locale, NTP daemon and fallback |
| `Swap` | Size, path, `swappiness`, minimum free disk |
| `Sysctl` | Drop-in path and the kernel parameter map |
| `Limits` | `DefaultLimitNOFILE`/`TasksMax` for systemd, `limits.d` for PAM |
| `Packages` | `Install`/`Remove` lists per OS family |
| `Users` | Admin account, groups, sudoers, secret names carrying keys |
| `Ssh` | Hardening directives, drop-in paths, rollback parameters |
| `Firewall` | Table name, open ports, rate limit, rollback parameters |
| `Fail2ban` | Backend, defaults, jails |
| `Updates` | Origins, automatic reboot and its window, needrestart |
| `Journald` | Size and retention limits |
| `Logrotate` | Array of rotation rules |
| `Docker` | Install, `daemon.json`, container log rotation |
| `Motd` | Which facts to show at login |
| `Cleanup` | autoremove, journal vacuum, `/boot` check |
| `Report` | Whether to print the summary and where to save it |

### Secrets

Secrets **never** live in `config/config.json`: the configuration holds a name
only, and the value comes from an environment variable prefixed with
`Secrets.EnvironmentVariablePrefix` (`LCFG_` by default):

```bash
export LCFG_ADMIN_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)"
export LCFG_ROOT_AUTHORIZED_KEYS="ssh-ed25519 AAAA... break-glass@company"
```

The prefix is `LCFG_`, not `LC_`: POSIX reserves `LC_ALL`, `LC_CTYPE` and the
rest of `LC_*` for locale, and a variable named `LC_PRIVATE_KEY` could break
output encoding.

A value may be the key itself or a path to a key file; both forms parse, so
multiline content never has to travel through a variable.

`Secrets.BlockTestDataSecrets` (`true` by default) rejects placeholder values
from the examples: `changeme`, `password`, `qwerty`, `hunter2`, `*@example.*`,
`*test.local*`. Without that check it is easy to run the configurator with the
demo config and end up with a production server whose only key sits in a public
repository.

If no key is set and `Users.GenerateKeyIfSecretMissing = true`, a pair is
generated on the machine (ed25519, 100 KDF rounds) and the private half is
stored at `Users.PrivateKeyOutputPath` with mode `600`. **The console and the
log show the file path only, never the content**: otherwise the key would land
in `testmode-report.json`, which people attach to tickets.

---

## Adding a step

1. Create `lib/steps/<name>.sh` with a `step_<name>` function:

```bash
#!/usr/bin/env bash
#
# SYNOPSIS
#     Step myapp: install the application.
#
# DESCRIPTION
#     Why the step is shaped this way. Known traps belong here too.

step_myapp() {
    if ! config_section_enabled MyApp; then
        step_skipped 'MyApp.Enabled = false'
        return $?
    fi

    local version
    version="$(config_get '.MyApp.Version' '')"

    if [[ -z "$version" ]]; then
        step_failed 'MyApp.Version is not set'
        return $?
    fi

    if ! confirm_step_action "/opt/myapp" "Install version ${version}" Medium; then
        local rc=$?
        if (( rc == 2 )); then step_skipped '--what-if'; return $?; fi
        step_skipped 'user declined'
        return $?
    fi

    fs_ensure_dir /opt/myapp 755
    fs_write "/opt/myapp/version" "${version}"$'\n' 644 root:root
    run_cmd systemctl restart myapp

    step_ok "version ${version} installed"
    return $?
}
```

2. Add the section to `config/config.json` and describe it in
   `config/config.schema.json`.
3. Register the step in `step_definitions` (`lib/steps/registry.sh`): name,
   function, description, root requirement, risk level.
4. Run `./tests/run-tests.sh`: the structure tests check that the function
   exists, the name is registered and the order is intact.

### Rules worth keeping

- **Step return codes:** `0` Success, `1` Failed, `3` Skipped (`step_ok` /
  `step_failed` / `step_skipped`). Code `2` belongs to the entry point for
  critical startup errors; steps never return it.
- **External commands only through `run_cmd` / `run_capture` / `run_quiet`.**
  A bare `apt-get` call inside a step is not simulated in test mode and never
  reaches the journal.
- **Disk writes only through `fs_write` / `fs_append` / `fs_append_unique`.**
  Otherwise the file bypasses the sandbox and test mode stops being safe.
- **Idempotency:** a second run must change nothing. Use `fs_append_unique`
  and read the current state before modifying it.
- `config_get_bool` returns a **status**, not a string. Correct:
  `if config_get_bool '.X' true; then ...`. Wrong:
  `x="$(config_get_bool '.X' true)"`, which always yields an empty
  string. A linter test enforces this.

---

## Tests

```bash
./tests/run-tests.sh                  # all suites
./tests/run-tests.sh --list           # list suites
./tests/run-tests.sh tests/units.bats # one suite
./tests/run-tests.sh --tap            # TAP output for external reporters
```

| Suite | Tests | What it catches |
|---|---|---|
| `project-structure.bats` | 16 | Registry and function drift, aliases, step order, shellcheck, dead code, `config_get_bool` misuse |
| `config-validation.bats` | 22 | Every schema error class and correct field paths in messages |
| `testmode-isolation.bats` | 11 | Any break of the "test mode changes nothing" promise |
| `generated-content.bats` | 25 | Properties of generated configs, plus a run through real `nft -c`, `sshd -t`, `visudo -cf`, `logrotate -d` |
| `cli-and-exitcodes.bats` | 17 | Exit codes as a contract, lockout protection |
| `units.bats` | 29 | Path tokens, no eval, sandbox overlay, idempotency, fixtures |

Tests **do not modify the system**: every run happens in `--test-mode`, so they
are safe on a production machine and in CI.

Tooling:

```bash
sudo apt-get install -y jq shellcheck bats      # Debian/Ubuntu
sudo dnf install -y jq ShellCheck bats          # RHEL/Fedora
```

---

## Rollback

Every modified file is copied to `Backup.DirectoryPath` (default
`/var/backups/linuxconfigurator`) before the edit, timestamp in the name. The
`ssh` and `firewall` steps additionally snapshot their whole configuration
directory before applying.

```bash
ls -lt /var/backups/linuxconfigurator/

# Roll back sshd settings
cp -a /var/backups/linuxconfigurator/sshd-20260101-120000/. /etc/ssh/sshd_config.d/
rm -f /etc/ssh/sshd_config.d/00-linuxconfigurator.conf
sudo systemctl reload ssh

# Roll back the firewall
cp -a /var/backups/linuxconfigurator/nftables-20260101-120000/nftables.conf /etc/nftables.conf
sudo nft -f /etc/nftables.conf
```

A full rollback of the `users` step removes the sudoers fragment and the added
`authorized_keys` lines; the account and its home directory stay.

---

## Verified

| Environment | Result |
|---|---|
| Ubuntu 24.04.5 LTS, 1 vCPU / 1.9 GiB RAM, Hetzner Cloud (Helsinki) | 16/16 steps, run applied and re-checked after reboot |
| GitHub Actions `ubuntu-latest` | shellcheck + 120 tests + test-mode run |

---

## Limits and known behaviour

**Docker and the firewall.** Published container ports
(`docker run -p 8080:8080`) go through DNAT in `PREROUTING` and then `FORWARD`,
so they **bypass INPUT**. Rules from this configurator do not filter them,
exactly like ufw does not. Restrict them either by publishing on loopback
(`127.0.0.1:8080:8080`) behind a proxy, or in the `DOCKER-USER` chain:

```bash
nft insert rule ip filter DOCKER-USER iifname enp1s0 tcp dport 8080 \
    ip saddr != { 1.2.3.4 } counter drop
```

The `firewall` step deliberately never declares a `FORWARD` chain: a `drop`
policy there would cut Docker networking completely.

**`nft` selectors.** Rules live in a dedicated `inet fw` table; the
configuration contains no `flush ruleset`, so Docker tables (`ip/ip6 nat`,
`ip/ip6 filter`) and fail2ban (`inet f2b-table`) stay untouched.

**`sshd` and drop-in order.** sshd applies the **first** value it finds for a
parameter, and `Include` sits at the top of `sshd_config`. Hence the drop-in
name `00-*`; the cloud `50-cloud-init.conf` is additionally overwritten and an
`/etc/cloud/cloud.cfg.d/*.cfg` is added, otherwise cloud-init restores password
login at next boot.

**The `docker` group equals root** (mount `/host` into a container and you have
full access). `Docker.AdminGroupAccess` defaults to `false`; use `sudo docker`.

**Docker log limits apply to new containers only.** Existing ones keep their
settings until recreated; the step warns about it explicitly.

**Reboots.** After a kernel update the `report` step flags a pending reboot.
`Updates.AutomaticReboot` enables automatic reboots at `AutomaticRebootTime`
(default 04:30); on a machine under long-running load disable it and reboot by
hand.

**SELinux/AppArmor are not configured.** On RHEL-family systems, changed paths
or ports may need `restorecon` / `semanage`; the step does not run them
automatically to avoid fighting the local policy.

---

## License

MIT, see [LICENSE](LICENSE).
