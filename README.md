# debian-setup.sh — Debian/Ubuntu server bootstrap

One self-contained Bash script: `apt full-upgrade`, Docker Engine + Compose plugin,
Tailscale, UFW, Fail2Ban, SSH hardening and Debian/Ubuntu security auto-updates —
with SSH access checks before firewall activation.

Repository: https://github.com/dany547/linux-onboarding-script

## What it does

- `apt-get update` + `apt-get full-upgrade` (skip with `--skip-upgrade`);
- installs Docker Engine, Buildx and the Compose plugin from Docker's official
  `stable` repository (pinned OpenPGP fingerprint);
- installs Tailscale from its official `stable` repository (sign-in stays manual:
  `sudo tailscale up`);
- installs and configures UFW: `default deny incoming`, `default allow outgoing`,
  low logging, SSH allowed only from the configured networks, `IPV6=yes`;
- configures Fail2Ban for SSH (`sshd` jail, `banaction = ufw`, `ignoreip` = your
  allowed networks + current session);
- enables unattended security upgrades (distro security origin only unless
  `--update-third-party`);
- applies a minimal SSH baseline: no empty passwords, no X11 forwarding, limited
  auth retries, optional `AllowUsers` and key-only login;
- verifies Docker, Compose, Tailscale, UFW, Fail2Ban and the effective sshd config.

## What it does not do

- no inbound ports 80/443, no public port 22 in `--mode vps`;
- no Cloudflare Tunnel, WireGuard/WG-Easy, Linux users beyond `--create-user`,
  no automatic Docker port publishing, no `machine-id`/timezone/host-key changes;
- no generic OS hardening (sysctl, NTP, hostname, swap);
- it never runs on a Proxmox VE host (refused, exit 3).

Docker's published ports bypass UFW: do not publish on `0.0.0.0` without an
explicit rule, and keep Cloudflare Tunnel apps on a shared Docker network instead
of `ports:`.

## Supported distributions

| System | Result |
|---|---|
| Debian 12 (bookworm), 13 (trixie) | supported |
| Ubuntu 22.04 (jammy), 24.04 (noble) | supported |
| Debian/Ubuntu derivatives (`ID_LIKE`) | accepted with an "untested combination" warning |
| Other codenames on a derivative | warning (repos may lack the suite) |
| Unknown codename on Debian/Ubuntu, Debian ≠12/13, Ubuntu ≠22.04/24.04 | refused, exit 3 |
| RHEL family, Arch, Alpine, anything else | refused, exit 3 |
| Proxmox VE host (`pveversion` found) | refused, exit 3 |
| Unprivileged LXC | packages installed, but UFW/Fail2Ban are skipped in the guest — configure the firewall on the Proxmox host |

## Quick start (new machine)

```bash
git clone https://github.com/dany547/linux-onboarding-script.git
cd linux-onboarding-script

# 1. preview — prints the full plan, performs no change (may run as non-root)
sudo bash debian-setup.sh --dry-run -y --mode lan --lan-cidr 192.168.1.0/24

# 2. apply
sudo bash debian-setup.sh -y --mode lan --lan-cidr 192.168.1.0/24
```

VPS (SSH only over WireGuard/Tailscale, never publicly):

```bash
sudo bash debian-setup.sh --dry-run -y --mode vps --wireguard-cidr 10.8.0.0/24
sudo bash debian-setup.sh -y --mode vps --wireguard-cidr 10.8.0.0/24
```

Ready-made config files load with `--config` (CLI arguments win over the file):

```bash
sudo bash debian-setup.sh -y --config examples/lan.conf
sudo bash debian-setup.sh -y --config examples/vps.conf
sudo bash debian-setup.sh -y --config examples/vps-fleet.conf   # admin user + key + --ssh-keys-only
```

`--dry-run` as a normal user additionally needs `DS_ROOT_OK=1`.

## Flags

Source of truth is `--help`; the table mirrors it.

| Flag | Effect |
|---|---|
| `-y`, `--yes` | Non-interactive; requires `--mode` |
| `--mode lan\|vps` | LAN = SSH from LAN/VPN; VPS = SSH from VPN only |
| `--lan-cidr CIDR` | LAN subnet allowed for SSH |
| `--wireguard-cidr CIDR` | WireGuard subnet/source allowed for SSH |
| `--wireguard-iface IFACE` | Extra UFW "in on IFACE" SSH rule, added *on top of* the CIDR rules |
| `--config FILE` | Load `KEY=value` lines from FILE (no shell evaluation); CLI has priority |
| `--print-config` | Print the effective configuration (`KEY=value`) and exit |
| `--dry-run` | Print the full plan (commands, files, UFW rules) with zero changes |
| `--no-docker` | Do not install Docker Engine + Compose plugin |
| `--no-tailscale` | Do not install Tailscale |
| `--no-fail2ban` | Do not install/configure Fail2Ban |
| `--no-auto-updates` | Do not enable unattended security upgrades |
| `--reset-firewall` | Reset existing UFW rules first (backs up `/etc/ufw`) |
| `--allow-current-ssh` | Explicitly allow the current SSH session's IP |
| `--skip-upgrade` | Do not run `apt full-upgrade` |
| `--docker-pool CIDR` | Docker `default-address-pools` (/24 subnets; e.g. `10.200.0.0/16`) |
| `--docker-bind-localhost` | Bind published ports to `127.0.0.1` by default |
| `--no-docker-config` | Leave `/etc/docker/daemon.json` untouched |
| `--docker-user USER` | Add USER to the `docker` group — equivalent to root |
| `--create-user NAME` | Create (or reuse) a bash user in `sudo` with a locked password |
| `--no-sudo-nopasswd` | With `--create-user`: no sudoers NOPASSWD, password not locked |
| `--ssh-key-file PATH` | Install the public key from PATH (preferred; not visible in `ps`) |
| `--ssh-key KEY` | Inline public key (visible in the process list) |
| `--ssh-keys-only` | Key-only SSH login (drop-in + `sshd -T` check) |
| `--allow-users U1,U2` | `AllowUsers` in sshd; must include the current/created user |
| `--auto-reboot HH:MM` | Unattended reboot at the given time |
| `--mail ADDR` | Unattended reports by e-mail (needs a local MTA) |
| `--update-third-party` | Also auto-update the Docker/Tailscale repos |
| `--strict` | Failed unattended-upgrades verification → exit 1 (default: warning) |
| `--version` | Print `debian-setup.sh <version>` and exit |
| `-h`, `--help` | Print usage and exit |

## Configuration precedence (and a known caveat)

Precedence for values: **CLI > `--config` file > built-in default.** `--config` is
read in a first pass, so command-line arguments override the file regardless of
argument order. `--print-config` shows the resulting values.

**Known limitation (not fixed yet):** when the script runs *interactively* (no
`-y`, no `--dry-run`), the four component questions (Docker, Tailscale, Fail2Ban,
auto-updates) overwrite `--no-docker`, `--no-tailscale`, `--no-fail2ban` and
`--no-auto-updates` — and the same values coming from a config file. The mode and
CIDR prompts only appear when the value is still unset, so those flags are safe.
Workaround until this is fixed: always pass `-y` for scripted/flag-driven runs,
or check the plan first with `--print-config` / `--dry-run`.

## SSH and firewall guards

The lockout guard refuses to enable UFW when the current session's source is not
covered by the proposed rules (exit 4). Session detection order:
`SSH_CONNECTION` → `sshd`/`sshd-session` PPID chain + `ss` → `who -m`.

- On a fresh VPS, run it **from the provider console first**, not over SSH.
- Escape hatches: `--allow-current-ssh`, `DS_SSH_SOURCE=IP`, or a correct
  `--lan-cidr` / `--wireguard-cidr`. With `-y` and an uncovered session the run
  stops with exit 4; interactively you must confirm explicitly.
- `--allow-current-ssh` also covers other *established* SSH sessions (tmux/screen
  chains that hide the ancestor) — each gets a /32 (or /128) rule.
- `--ssh-keys-only` is a hard precondition: at least one privileged account must
  already hold a valid key (or be created with a key in the same run), otherwise
  exit 4; likewise if `--allow-users` excludes every key-capable account.
- No allowed network at all → exit 4.
- LAN mode allows SSH from `--lan-cidr`, `--wireguard-cidr` and Tailscale
  (`100.64.0.0/10` + `fd7a:115c:a1e0::/48`); VPS mode opens no public SSH port.

## Running on an existing host

There is **no guaranteed rollback.** The script has no revert transaction: package
installs, `apt full-upgrade`, sshd drop-ins, user/sudoers changes and enabling UFW
are not automatically undone if something later fails or you lose access. The only
safety nets are targeted, per-change copies: `/var/backups/ufw-<timestamp>/` on
`--reset-firewall`, `daemon.json.bak-<timestamp>` before each daemon.json edit, and
automatic restore of the ssh drop-ins when `sshd -t`/`sshd -T` fails.

Practical advice for machines that already matter:

- review `--dry-run` output line by line and take your own snapshot/backup first;
- `--reset-firewall` deletes every existing UFW rule — only use it when you intend
  to rebuild the firewall from scratch (without it, existing rules are kept and the
  summary warns about it);
- `--ssh-keys-only`, `--allow-users` and `--create-user` change who can log in;
  keep a second access path (console/Tailscale/WireGuard);
- Docker/Tailscale come from external `stable` repos; their upgrades are only
  included when `--update-third-party` is set.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success (also user-aborted before any change) |
| 1 | runtime error (e.g. bad key fingerprint, invalid JSON, `--strict` verification failure) |
| 2 | invalid arguments/configuration, missing option value, test `DS_*` overrides present |
| 3 | unmet precondition / unsupported OS / Proxmox / not root |
| 4 | detected lockout risk |

## Environment overrides

- `DS_SSH_SOURCE=IP` — declare the SSH session source when detection cannot (e.g.
  deep `sudo`/`su` chains). Safe in production.
- Test/CI only: `DS_TEST=1`, `DS_OS_RELEASE`, `DS_ROOT_OK`, `DS_SSH_CHAIN`,
  `DS_SSHD_PID`, `DS_CMD_*`, `DS_UFW_DEFAULT`, `DS_DOCKER_DAEMON`,
  `DS_SSH_CONFIG_DIR`, `DS_TAILSCALE_OLD_LIST`, `DS_SUDOERS_DIR` — see the script
  header. On a real run (not `--dry-run`, not `DS_TEST=1`) any `DS_*` variable
  aborts with exit 2. `DS_ROOT_OK=1` only relaxes the root check for `--dry-run`.

## Logs, verification, containers

- Log: `/var/log/debian-setup.log` (no colors; `trap ERR` records line + command).
- After a run: `docker --version`, `docker compose version`, `sudo tailscale status`,
  `sudo ufw status verbose`, `sudo fail2ban-client status sshd`, `ss -lntup`.
- Unprivileged LXC: UFW/Fail2Ban stay off in the guest; Docker may need
  `nesting=1`, `keyctl=1`, `fuse=1`.
- Auto-updates verify that `unattended-upgrade --dry-run --debug` lists the distro
  security origin; a failed check is a loud warning, or exit 1 with `--strict`.
  The script does not reboot immediately. `--auto-reboot` explicitly enables
  later unattended reboots; otherwise check `/var/run/reboot-required` manually.

## Tests and validation status

```bash
bash tests/run.sh     # unit tests: non-root, no network, temp fixtures are cleaned up
bash -n debian-setup.sh && shellcheck -x -S warning debian-setup.sh
```

The suite is **mocked**: fixtures replace `/etc/os-release`, UFW, `sshd`, `ss` and
friends. The manual real-VM checklist in `docs/TEST-VM.md` (Debian 12/13, Ubuntu
22.04/24.04, privileged and unprivileged LXC) has **not been executed for this
baseline**, so this release makes no real-VM or production-readiness claim.

## Versioning

Releases use Semantic Versioning and `vMAJOR.MINOR.PATCH` Git tags. See
[CHANGELOG.md](CHANGELOG.md) for changes and known limitations. A tag does not
imply real-VM or production validation.
