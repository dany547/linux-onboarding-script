#!/usr/bin/env bash
set -Eeuo pipefail

# Keep the legacy filename usable on Alpine when Bash is already installed.
# Alpine users without Bash should invoke the portable setup.sh launcher.
if [[ "${BASH_SOURCE[0]}" == "$0" && -r /etc/alpine-release ]]; then
    alpine_backend="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/alpine-setup.sh"
    if [[ ! -r "$alpine_backend" ]]; then
        printf '%s\n' '[ERROR] Alpine requires alpine-setup.sh; clone the complete repository and run sh setup.sh.' >&2
        exit 3
    fi
    exec sh "$alpine_backend" "$@"
fi

# ============================================================
# Debian/Ubuntu server bootstrap — Docker, Compose, UFW,
# Fail2Ban, Tailscale și SSH privat.
#
# Debian 12 / 13 și Ubuntu 22.04 / 24.04 (și derivate ale
# acestora, cu avertisment). Docker și Tailscale sunt instalate
# din repository-urile oficiale, pe canalul stable.
#
# Cloudflare Tunnel nu este configurat aici. El rulează ulterior
# prin Docker Compose și nu necesită porturile 80/443 inbound.
#
# Exemple:
#   sudo bash debian-setup.sh
#   sudo bash debian-setup.sh --mode lan
#   sudo bash debian-setup.sh -y --mode vps --wireguard-cidr 10.8.0.0/24
#   sudo bash debian-setup.sh --config setup.conf -y --mode vps
#   bash debian-setup.sh --dry-run --mode lan     # doar planul, nicio mutație
#
# Coduri de ieșire:
#   0 = succes
#   1 = eroare de execuție
#   2 = argumente/configurație invalide
#   3 = precondiție neîndeplinită / OS nesuportat
#   4 = risc de lockout detectat
#
# Override-uri pentru teste (nu folosi în producție):
#   DS_OS_RELEASE=CALE   folosește alt fișier în loc de /etc/os-release
#   DS_SSH_SOURCE=IP     IP-ul sesiunii SSH, în loc de detecție automată
#   DS_ROOT_OK=1         permite --dry-run ca non-root
#   DS_SSH_CHAIN=none    sare căutarea sshd în lanțul PPID (test 'fără sesiune SSH')
#   DS_SSHD_PID=PID      tratează PID-ul dat ca sshd găsit în lanț (simulează sudo)
#   DS_CMD_SS=CALE       înlocuiește comanda ss (fixture pentru detecția sesiunii)
#   DS_CMD_WHO=CALE      înlocuiește comanda who
#   DS_CMD_SSHD=CALE     înlocuiește comanda sshd (ex. pentru 'sshd -T')
#   DS_CMD_SYSTEMCTL=CALE înlocuiește systemctl (ex. starea ssh.socket)
#   DS_UFW_DEFAULT=CALE  înlocuiește /etc/default/ufw
#   DS_CMD_GPG=CALE      înlocuiește gpg (verificare fingerprint chei)
#   DS_CMD_DPKG=CALE     înlocuiește dpkg (pachete Docker conflictuale)
#   DS_CMD_SNAP=CALE     înlocuiește snap (docker snap)
#   DS_CMD_FAIL2BAN_CLIENT=CALE înlocuiește fail2ban-client (starea jail sshd)
#   DS_CMD_UNATTENDED=CALE înlocuiește unattended-upgrade (verificarea originilor)
#   DS_CMD_PYTHON3=CALE  înlocuiește python3 (merge daemon.json)
#   DS_CMD_GETENT=CALE   înlocuiește getent (verificare --docker-user)
#   DS_DOCKER_DAEMON=CALE înlocuiește /etc/docker/daemon.json
#   DS_CMD_SSH_KEYGEN=CALE înlocuiește ssh-keygen (validarea cheilor SSH)
#   DS_SSH_CONFIG_DIR=CALE înlocuiește /etc/ssh/sshd_config.d
#   DS_TAILSCALE_OLD_LIST=CALE înlocuiește /etc/apt/sources.list.d/tailscale.list
#   DS_CMD_DETECT_VIRT=CALE înlocuiește systemd-detect-virt
#   DS_CMD_PASSWD=CALE   înlocuiește passwd (starea parolei)
#   DS_CMD_VISUDO=CALE   înlocuiește visudo (validarea sudoers)
#   DS_SUDOERS_DIR=CALE  înlocuiește /etc/sudoers.d
#
#   F5: override-urile de mai sus funcționează doar în --dry-run sau în medii de
#   test cu DS_TEST=1; la rulare reală, orice DS_* de test setat => exit 2.
# ============================================================

VERSION="2.8.0"
LOG_FILE="/var/log/debian-setup.log"
LOG_FD=""

# fingerprint-ul pinuit al cheii oficiale Docker (B4)
DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# culorile conțin ESC real (printf '%s' le tipărește ca atare;\n# în fișierul de log nu intră niciodată — log_write primește doar mesajul)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

NONINTERACTIVE=no
DRY_RUN=no
PRINT_CONFIG=no
PRINT_VERSION=no
STRICT=no
CONFIG_FILE=""
WIZARD=no
INSPECT=no
MANAGE_SSH=yes
# Only explicit CLI/config choices suppress wizard questions.
declare -A CHOICE_SOURCE=()

MODE=""
LAN_CIDR=""
WIREGUARD_CIDR=""
TAILSCALE_CIDR="100.64.0.0/10"
INSTALL_DOCKER=yes
INSTALL_TAILSCALE=yes
INSTALL_FAIL2BAN=yes
INSTALL_AUTO_UPDATES=yes
RESET_FIREWALL=no
SKIP_UPGRADE=no
ALLOW_CURRENT_SSH=no

# Layer distro (umplut de detect_distro)
DISTRO=""
CODENAME=""
DOCKER_REPO_URL=""
TAILSCALE_REPO_URL=""
SECURITY_ORIGINS=()

SKIP_FIREWALL=no
SSH_SOURCE_IP=""
SSH_SESSION_IS_SSH=no
SSH_ESTABLISHED_PEERS=""
UNCOVERED_PEERS=""
SSH_PORT=22
SSH_SOCKET_ACTIVE=no
WIREGUARD_IFACE=""
DETECTED_LAN_CIDR=""
SSH_CIDRS=()
TAILSCALE_IPV6_CIDR="fd7a:115c:a1e0::/48"
DOCKER_LXC_NO_NESTING=no
DOCKER_CONFIG=yes
DOCKER_POOL=""
DOCKER_BIND_LOCALHOST=no
DOCKER_USER=""
CREATE_USER=""
SSH_KEY_FILE=""
SSH_KEY=""
SSH_KEYS_ONLY=no
ALLOW_USERS=""
SUDO_NOPASSWD=no
AUTO_REBOOT=""
MAIL_ADDR=""
UPDATE_THIRD_PARTY=no

# Cheile permise în fișierele --config ( aceleași chei le printează --print-config )
CONFIG_KEYS=(
    MODE
    LAN_CIDR
    WIREGUARD_CIDR
    WIREGUARD_IFACE
    TAILSCALE_CIDR
    TAILSCALE_IPV6_CIDR
    MANAGE_SSH
    SKIP_FIREWALL
    INSTALL_DOCKER
    INSTALL_TAILSCALE
    INSTALL_FAIL2BAN
    INSTALL_AUTO_UPDATES
    RESET_FIREWALL
    SKIP_UPGRADE
    ALLOW_CURRENT_SSH
    DOCKER_CONFIG
    DOCKER_POOL
    DOCKER_BIND_LOCALHOST
    DOCKER_USER
    CREATE_USER
    SSH_KEY_FILE
    SSH_KEYS_ONLY
    ALLOW_USERS
    SUDO_NOPASSWD
    AUTO_REBOOT
    MAIL_ADDR
    UPDATE_THIRD_PARTY
)

# ------------------------------------------------------------
# Jurnal și erori
# ------------------------------------------------------------

# Scrie o linie simplă (fără coduri ANSI) în fișierul de log.
# În --dry-run sau când descriptorul nu e deschis, nu scrie nimic.
log_write() {
    local level="$1"
    shift
    if [[ -z "$LOG_FD" ]]; then
        return 0
    fi
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >&"$LOG_FD"
}

# Deschide logul cu umask 077 (0600 root:root). În --dry-run nu se scrie.
open_log() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        return 0
    fi

    local umask_old
    umask_old="$(umask)"
    umask 077
    if exec {LOG_FD}>>"$LOG_FILE"; then
        umask "$umask_old"
    else
        umask "$umask_old"
        LOG_FD=""
        warn "Cannot write the log to $LOG_FILE; continuing without a file log."
    fi
}

# trap ERR: raportează linia și comanda care a eșuat, apoi exit 1.
on_error() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-?}"
    local cmd="${BASH_COMMAND:-unknown}"

    log_write ERROR "Failure at line ${line_no}: ${cmd} (exit code ${exit_code})"
    printf '%s[ERROR]%s Error at line %s: %s (exit code %s)%s\n' \
        "${RED}" "${NC}" "${line_no}" "${cmd}" "${exit_code}" \
        "$(if [[ -n "$LOG_FD" ]]; then printf ', see %s' "$LOG_FILE"; fi)" >&2
    exit 1
}

# die [COD] mesaj — COD implicit 1. Vezi tabelul de coduri din antet.
die() {
    local code=1
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        code="$1"
        shift
    fi
    log_write ERROR "$*"
    printf '%s[ERROR]%s %s\n' "${RED}" "${NC}" "$*" >&2
    exit "$code"
}

info() {
    log_write INFO "$*"
    printf '%s[INFO]%s %s\n' "${BLUE}" "${NC}" "$*"
}

ok() {
    log_write OK "$*"
    printf '%s[OK]%s %s\n' "${GREEN}" "${NC}" "$*"
}

warn() {
    log_write WARN "$*"
    printf '%s[WARN]%s %s\n' "${YELLOW}" "${NC}" "$*"
}

# ------------------------------------------------------------
# Wrappere mutative (run / write_file)
# ------------------------------------------------------------

# rulează o comandă mutativă; în --dry-run doar o afișează.
run() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '%s[DRY-RUN]%s ' "${CYAN}" "${NC}"
        printf '%q ' "$@"
        printf '\n'
        return 0
    fi
    log_write RUN "$*"
    "$@"
}

# write_file CALE MOD — scrie pe stdin în fișier; în --dry-run afișează conținutul.
write_file() {
    local path="$1"
    local mode="$2"

    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '%s[DRY-RUN]%s write %s (mode %s):\n' "${CYAN}" "${NC}" "$path" "$mode"
        sed 's/^/    | /'
        return 0
    fi

    log_write WRITE "$path (mode $mode)"
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp"
    install -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
}

# ------------------------------------------------------------
# Utilitare
# ------------------------------------------------------------

# ------------------------------------------------------------
# Straturi de comandă suprascriibile în teste (DS_CMD_*)
# ------------------------------------------------------------

cmd_ss() {
    if [[ -n "${DS_CMD_SS:-}" ]]; then "$DS_CMD_SS" "$@"; else ss "$@"; fi
}

cmd_who() {
    if [[ -n "${DS_CMD_WHO:-}" ]]; then "$DS_CMD_WHO" "$@"; else who "$@"; fi
}

cmd_sshd() {
    if [[ -n "${DS_CMD_SSHD:-}" ]]; then "$DS_CMD_SSHD" "$@"; else sshd "$@"; fi
}

cmd_systemctl() {
    if [[ -n "${DS_CMD_SYSTEMCTL:-}" ]]; then "$DS_CMD_SYSTEMCTL" "$@"; else systemctl "$@"; fi
}

cmd_gpg() {
    if [[ -n "${DS_CMD_GPG:-}" ]]; then "$DS_CMD_GPG" "$@"; else gpg "$@"; fi
}

cmd_dpkg() {
    if [[ -n "${DS_CMD_DPKG:-}" ]]; then "$DS_CMD_DPKG" "$@"; else dpkg "$@"; fi
}

cmd_snap() {
    if [[ -n "${DS_CMD_SNAP:-}" ]]; then "$DS_CMD_SNAP" "$@"; else snap "$@"; fi
}

cmd_fail2ban_client() {
    if [[ -n "${DS_CMD_FAIL2BAN_CLIENT:-}" ]]; then "$DS_CMD_FAIL2BAN_CLIENT" "$@"; else fail2ban-client "$@"; fi
}

cmd_unattended_upgrade() {
    if [[ -n "${DS_CMD_UNATTENDED:-}" ]]; then "$DS_CMD_UNATTENDED" "$@"; else unattended-upgrade "$@"; fi
}

cmd_python3() {
    if [[ -n "${DS_CMD_PYTHON3:-}" ]]; then "$DS_CMD_PYTHON3" "$@"; else python3 "$@"; fi
}

cmd_getent() {
    if [[ -n "${DS_CMD_GETENT:-}" ]]; then "$DS_CMD_GETENT" "$@"; else getent "$@"; fi
}

cmd_ssh_keygen() {
    if [[ -n "${DS_CMD_SSH_KEYGEN:-}" ]]; then "$DS_CMD_SSH_KEYGEN" "$@"; else ssh-keygen "$@"; fi
}

cmd_detect_virt() {
    if [[ -n "${DS_CMD_DETECT_VIRT:-}" ]]; then "$DS_CMD_DETECT_VIRT" "$@"; else systemd-detect-virt "$@"; fi
}

cmd_passwd() {
    if [[ -n "${DS_CMD_PASSWD:-}" ]]; then "$DS_CMD_PASSWD" "$@"; else passwd "$@"; fi
}

cmd_visudo() {
    if [[ -n "${DS_CMD_VISUDO:-}" ]]; then "$DS_CMD_VISUDO" "$@"; else visudo "$@"; fi
}

usage() {
    cat <<'EOF'
Debian/Ubuntu server bootstrap — Docker, Compose, UFW, Fail2Ban, Tailscale

Usage:
  sudo bash debian-setup.sh [options]

Options:
  -y, --yes                  Non-interactive; requires --mode
  --mode lan|vps             LAN = SSH from LAN/VPN; VPS = SSH from VPN only
  --lan-cidr CIDR            LAN subnet allowed for SSH
  --wireguard-cidr CIDR      WireGuard subnet or source allowed for SSH
  --wireguard-iface IFACE    Extra UFW rule 'in on IFACE' for SSH
                             (in addition to the CIDR rules, not instead of them)
  --config FILE              Load settings from FILE (KEY=value lines, no shell;
                             allowed keys are those listed by --print-config;
                             command-line arguments take precedence)
  --print-config             Print the effective configuration (KEY=value) and exit
  --dry-run                  Print the full plan (commands, files, UFW rules)
                             with no mutation; also works as non-root with DS_ROOT_OK=1
  --inspect                  Read-only inventory; no root, no log, no changes
  --wizard                   Conservative assistant; existing services are preserved
                             by default
  --no-ssh                   Do not modify the SSH service configuration
  --no-firewall              Do not install/configure UFW or the Fail2Ban-UFW
                             integration
  --no-docker                Do not install Docker Engine + Compose plugin
  --no-tailscale             Do not install Tailscale
  --no-fail2ban              Do not install/configure Fail2Ban
  --no-auto-updates          Do not enable unattended-upgrades for security updates
  --reset-firewall           Reset existing UFW rules before configuration
  --allow-current-ssh        Explicitly allow the IP of the current SSH session
  --skip-upgrade             Do not run apt full-upgrade
  --docker-pool CIDR         Default Docker network pool (default-address-pools,
                             /24 subnets; e.g. 10.200.0.0/16)
  --docker-bind-localhost    Port publishes bind to 127.0.0.1 by default
                             (the "ip" key in daemon.json). Without it Docker binds
                             to 0.0.0.0 and can bypass UFW rules!
  --no-docker-config         Do not touch /etc/docker/daemon.json
  --docker-user USER         Add USER to the docker group — root equivalent!
  --create-user NAME         Create (or reuse) a user with a bash shell, in the sudo
                             group, with a locked password; idempotent install
  --no-sudo-nopasswd         With --create-user: do not write sudoers NOPASSWD and do
                             not lock the password (set it manually with passwd)
  --ssh-key-file PATH        Install the public key from PATH for --create-user
                             (or for root). PREFERRED: the key does not show up in the
                             process list, unlike --ssh-key
  --ssh-key KEY              SSH public key (ssh-ed25519 AAAA... comment); visible in
                             the process list — use --ssh-key-file when you can
  --ssh-keys-only            Strict policy: key-only authentication (drop-in
                             00-bootstrap-security.conf + sshd -T check);
                             precondition: at least one privileged account has a
                             valid key
  --allow-users U1,U2        AllowUsers in sshd; must include the current user
                             or the --create-user user, otherwise exit 4
  --auto-reboot HH:MM        Allow the server to reboot automatically at the given time
  --mail ADDRESS             Send unattended reports to ADDRESS (requires an MTA)
  --update-third-party       Automatic updates also for the Docker/Tailscale repos
                             (by default only the official security origins)
  --strict                   If the unattended-upgrades check fails at the end →
                             exit 1 (by default: strong warning only)
  --version                  Print the version and exit
  -h, --help

Network behavior:
  LAN:
    SSH is allowed from --lan-cidr, --wireguard-cidr and Tailscale.
  VPS:
    Public SSH is not allowed; SSH is allowed only from WireGuard/Tailscale.

Tailscale uses the official stable channel. Authentication stays manual:
  sudo tailscale up

Cloudflare Tunnel does not need ports 80/443 open.

Exit codes: 0 ok, 1 error, 2 invalid arguments,
3 precondition/unsupported OS, 4 lockout risk.
EOF
}

yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer

    if [[ "$NONINTERACTIVE" == "yes" ]]; then
        [[ "$default" == "y" ]]
        return
    fi

    if [[ "$default" == "y" ]]; then
        read -r -p "$prompt [Y/n]: " answer || die 2 "Input closed; configuration cancelled without applying changes."
        answer="${answer:-y}"
    else
        read -r -p "$prompt [y/N]: " answer || die 2 "Input closed; configuration cancelled without applying changes."
        answer="${answer:-n}"
    fi

    answer="${answer,,}"
    [[ "$answer" =~ ^(y|yes|da)$ ]]
}

require_tty_or_yes() {
    # În --dry-run nu se citește nimic de la tastatură.
    if [[ "$DRY_RUN" == "yes" ]]; then
        return 0
    fi
    if [[ "$NONINTERACTIVE" != "yes" && ! -t 0 ]]; then
        die "No TTY. Run interactively or with -y and the required options."
    fi
}

valid_cidr() {
    local value="$1"
    local ip prefix octet
    local -a octets

    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        ip="${value%/*}"
        prefix="${value##*/}"
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            # 10# forțează baza 10: '08' și '010' nu sunt interpretate octal.
            (( 10#$octet <= 255 )) || return 1
        done
        (( 10#$prefix <= 32 )) || return 1
        return 0
    fi

    if [[ "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]]; then
        prefix="${value##*/}"
        (( 10#$prefix <= 128 )) || return 1
        return 0
    fi

    return 1
}

detect_lan_cidr() {
    local dev=""

    if command -v ip >/dev/null 2>&1; then
        dev="$(ip route show default 2>/dev/null | awk 'NR == 1 {print $5}')"
        if [[ -n "$dev" ]]; then
            ip -4 route show dev "$dev" scope link 2>/dev/null \
                | awk '$1 ~ /^[0-9]+\./ {print $1; exit}'
            return 0
        fi

        ip -4 route show scope link 2>/dev/null \
            | awk '$1 ~ /^[0-9]+\./ {print $1; exit}'
    fi
}

detect_ssh_source() {
    SSH_SOURCE_IP=""
    SSH_SESSION_IS_SSH=no

    # 1) override explicit pentru teste/rulări automatizate
    if [[ -n "${DS_SSH_SOURCE:-}" ]]; then
        SSH_SOURCE_IP="$DS_SSH_SOURCE"
        SSH_SESSION_IS_SSH=yes
        return 0
    fi

    # 2) sesiune SSH normală (variabilele supraviețuiesc de obicei și prin sudo)
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        SSH_SOURCE_IP="$(awk '{print $1}' <<<"$SSH_CONNECTION")"
        SSH_SESSION_IS_SSH=yes
        return 0
    fi
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        SSH_SOURCE_IP="$(awk '{print $1}' <<<"$SSH_CLIENT")"
        SSH_SESSION_IS_SSH=yes
        return 0
    fi

    # 3) sub sudo/su variabilele SSH_* dispar: căutăm sshd în lanțul de părinți,
    #    apoi IP-ul din conexiunea established pe portul SSH, apoi who -m.
    local sshd_pid=""
    if [[ "${DS_SSH_CHAIN:-}" != "none" ]]; then
        if [[ -n "${DS_SSHD_PID:-}" ]]; then
            sshd_pid="$DS_SSHD_PID"
        else
            sshd_pid="$(find_ssh_ancestor_pid || true)"
        fi
    fi

    if [[ -z "$sshd_pid" ]]; then
        # R1: sesiune locală/consolă — dar colectăm sesiunile SSH established
        # pe portul SSH pentru un warn vizibil mai târziu (warn_uncovered_established)
        collect_established_peers
        return 0
    fi

    SSH_SESSION_IS_SSH=yes # citit de teste; expus pentru chunk-uri ulterioare
    SSH_SOURCE_IP="$(ssh_source_from_ss "$sshd_pid" || true)"
    if [[ -z "$SSH_SOURCE_IP" ]]; then
        SSH_SOURCE_IP="$(ssh_source_from_who || true)"
    fi

    if [[ -z "$SSH_SOURCE_IP" ]]; then
        die 4 "SSH session detected (sshd in the process chain), but the source IP cannot be determined (typical under sudo/su). Re-run with DS_SSH_SOURCE=<IP> or use --allow-current-ssh."
    fi
}

# citește comm din /proc/<pid>/stat (comm poate conține spații)
_proc_comm() {
    local line
    line="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    line="${line#*\(}"
    printf '%s' "${line%%\)*}"
}

# citește ppid din /proc/<pid>/stat, ignorând (comm)
_proc_ppid() {
    local rest
    rest="$(sed -E 's/^[0-9]+ \([^)]*\) //' "/proc/$1/stat" 2>/dev/null)" || return 1
    awk '{print $2}' <<<"$rest"
}

# R1: numele de proces al daemonului SSH variază (OpenSSH ≥ 9.8: sshd-session)
is_sshd_comm() {
    case "$1" in
        sshd|sshd-session|sshd-auth) return 0 ;;
        *) return 1 ;;
    esac
}

# parcurge lanțul PPID până la init; întoarce PID-ul primului sshd găsit
find_ssh_ancestor_pid() {
    local pid="$$" i ppid comm

    for ((i = 0; i < 32; i++)); do
        comm="$(_proc_comm "$pid")" || return 1
        if is_sshd_comm "$comm"; then
            printf '%s' "$pid"
            return 0
        fi
        ppid="$(_proc_ppid "$pid")" || return 1
        [[ "$ppid" =~ ^[0-9]+$ ]] || return 1
        (( ppid <= 1 )) && return 1
        pid="$ppid"
    done
    return 1
}

# IP-ul sursă din conexiunile established pe portul SSH.
# Preferă conexiunea deținută de sshd-ul din lanțul nostru (PID cunoscut);
# fără informație de PID (non-root), acceptă o singură pereche unică.
ssh_source_from_ss() {
    local sshd_pid="$1"
    local line peer pid
    local -a peers=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        peer="$(awk '{print $5}' <<<"$line")"
        peer="${peer%:*}"
        peer="${peer#[}"
        peer="${peer%]}"
        [[ "$peer" =~ ^[0-9A-Fa-f:.]+$ ]] || continue
        if [[ "$line" =~ pid=([0-9]+) ]]; then
            pid="${BASH_REMATCH[1]}"
            if [[ "$pid" == "$sshd_pid" ]]; then
                printf '%s' "$peer"
                return 0
            fi
        fi
        peers+=("$peer")
    done < <(cmd_ss -Htnp state established "( sport = :$SSH_PORT )" 2>/dev/null)

    if (( ${#peers[@]} > 0 )); then
        local uniq
        uniq="$(printf '%s\n' "${peers[@]}" | sort -u)"
        if [[ "$(printf '%s\n' "$uniq" | wc -l)" -eq 1 ]]; then
            printf '%s' "$uniq"
            return 0
        fi
    fi

    return 1
}

# ultim fallback: coloana cu hostname din 'who -m'
ssh_source_from_who() {
    local out
    out="$(cmd_who -m 2>/dev/null)" || return 1
    [[ -n "$out" ]] || return 1
    out="$(sed -E 's/.*\(([^)]+)\).*/\1/' <<<"$out")"
    [[ "$out" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    printf '%s' "$out"
}

# B6: portul SSH efectiv din sshd -T (fallback 22)
detect_ssh_port() {
    SSH_PORT="$(cmd_sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
    if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        SSH_PORT=22
    fi
}

# B6: socket-activation (Debian 13 / Ubuntu >= 22.10)
detect_ssh_socket() {
    SSH_SOCKET_ACTIVE=no
    if cmd_systemctl is-active --quiet ssh.socket 2>/dev/null; then
        SSH_SOCKET_ACTIVE=yes
    fi
}

# verificare post-restart ssh.socket: portul SSH ascultă efectiv?
verify_ssh_listening() {
    if cmd_ss -Hln "( sport = :$SSH_PORT )" 2>/dev/null | grep -q .; then
        ok "sshd is listening on port $SSH_PORT."
    else
        warn "sshd is not listening (yet) on port $SSH_PORT; check ssh.socket/the sshd service."
    fi
}

ip_in_cidr() {
    local address="$1"
    local cidr="$2"

    python3 - "$address" "$cidr" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
    network = ipaddress.ip_network(sys.argv[2], strict=False)
except ValueError:
    raise SystemExit(1)

raise SystemExit(0 if address in network else 1)
PY
}

# Adaugă un CIDR o singură dată (idempotent).
add_ssh_cidr() {
    local cidr="$1"
    local existing

    [[ -n "$cidr" ]] || return 0
    for existing in "${SSH_CIDRS[@]}"; do
        [[ "$existing" == "$cidr" ]] && return 0
    done
    SSH_CIDRS+=("$cidr")
}

print_detection() {
    echo
    echo "============================================================"
    echo " Debian/Ubuntu server bootstrap"
    echo "============================================================"
    echo
    echo "System:       ${PRETTY_NAME:-Debian/Ubuntu}"
    echo "Distro:       ${DISTRO:-?}"
    echo "Codename:     ${CODENAME:-unknown}"
    echo "Network mode: ${MODE:-unset}"
    echo "Port SSH:     $SSH_PORT"
    echo "LAN CIDR:     ${LAN_CIDR:-unset}"
    echo "WireGuard:    ${WIREGUARD_CIDR:-unset}${WIREGUARD_IFACE:+ (interface $WIREGUARD_IFACE)}"
    echo "Tailscale:    $([[ "$INSTALL_TAILSCALE" == "yes" ]] && echo "$TAILSCALE_CIDR + $TAILSCALE_IPV6_CIDR" || echo NO)"
    echo
}

# Afișează configurația efectivă (aceleași chei ca allowlist-ul --config).
print_config() {
    local key
    for key in "${CONFIG_KEYS[@]}"; do
        printf '%s=%s\n' "$key" "${!key:-}"
    done
}

print_plan_summary() {
    echo "============================================================"
    echo " CONFIGURATION"
    echo "============================================================"
    echo
    echo "Docker + Compose:       $INSTALL_DOCKER"
    echo "Tailscale:              $INSTALL_TAILSCALE"
    echo "Fail2Ban:               $INSTALL_FAIL2BAN"
    echo "Security auto-updates:  $INSTALL_AUTO_UPDATES"
    echo "SSH configuration:      $MANAGE_SSH"
    echo "Firewall UFW:            $([[ "$SKIP_FIREWALL" == "yes" ]] && echo 'KEEP (explicitly skipped / container restrictions)' || echo YES)"
    echo "Reset UFW rules:        $RESET_FIREWALL"
    echo "Upgrade Debian:          $([[ "$SKIP_UPGRADE" == "yes" ]] && echo NO || echo YES)"
    echo "Port SSH:                $SSH_PORT"
    if [[ "$SKIP_FIREWALL" == "yes" ]]; then
        echo "SSH firewall access:     KEPT (existing rules, unverified)"
    else
        echo "SSH allowed from:        ${SSH_CIDRS[*]}"
    fi
    echo "SSH session detected:    $SSH_SESSION_IS_SSH"
    if [[ -n "$WIREGUARD_IFACE" ]]; then
        echo "WireGuard interface:     $WIREGUARD_IFACE"
    fi
    if [[ -n "$SSH_SOURCE_IP" ]]; then
        echo "Current SSH from:        $SSH_SOURCE_IP"
    fi
    echo
}

# ------------------------------------------------------------
# Layer distro
# ------------------------------------------------------------

# Populează DISTRO, CODENAME, DOCKER_REPO_URL, TAILSCALE_REPO_URL,
# SECURITY_ORIGINS. Poate fi apelată repetat: resetează valorile,
# deci rezultatul este același (idempotent).
# Debian/Ubuntu primare fără warn; derivatele (prin ID_LIKE) cu warn;
# orice altceva → exit 3.
detect_distro() {
    local os_file="${DS_OS_RELEASE:-/etc/os-release}"
    local id id_like version_id major=""

    [[ -r "$os_file" ]] || die 3 "Cannot read $os_file."

    # shellcheck disable=SC1090
    source "$os_file"

    id="${ID:-}"
    id_like="${ID_LIKE:-}"
    version_id="${VERSION_ID:-}"

    DISTRO=""
    CODENAME=""
    DOCKER_REPO_URL=""
    TAILSCALE_REPO_URL=""
    SECURITY_ORIGINS=()

    if [[ "$id" == "debian" || "$id" == "ubuntu" ]]; then
        DISTRO="$id"
    elif [[ " $id_like " == *" debian "* && " $id_like " != *" ubuntu "* ]]; then
        DISTRO="debian"
        warn "Debian derivative detected (ID=${id}, ID_LIKE=${id_like}); it is treated as Debian. This combination is not officially tested."
    elif [[ " $id_like " == *" ubuntu "* || " $id_like " == *" debian "* ]]; then
        DISTRO="ubuntu"
        warn "Ubuntu derivative detected (ID=${id}, ID_LIKE=${id_like}); it is treated as Ubuntu. This combination is not officially tested."
    else
        die 3 "Unsupported distribution: ${PRETTY_NAME:-${id:-unknown}}. Supported: Debian 12/13, Ubuntu 22.04/24.04 and their derivatives."
    fi

    if [[ "$DISTRO" == "debian" ]]; then
        if [[ "$id" == "debian" ]]; then
            major="${version_id%%.*}"
            if [[ "$major" != "12" && "$major" != "13" ]]; then
                die 3 "Supported: Debian 12 and 13; detected: ${PRETTY_NAME:-unknown}."
            fi
        fi
        CODENAME="${VERSION_CODENAME:-}"
        if [[ -z "$CODENAME" ]]; then
            case "$major" in
                12) CODENAME=bookworm ;;
                13) CODENAME=trixie ;;
            esac
        fi
    else
        if [[ "$id" == "ubuntu" ]]; then
            if [[ "$version_id" != "22.04" && "$version_id" != "24.04" ]]; then
                die 3 "Supported: Ubuntu 22.04 and 24.04; detected: ${PRETTY_NAME:-unknown}."
            fi
        fi
        CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    fi

    [[ -n "$CODENAME" ]] \
        || die 3 "Cannot determine the distribution codename (${PRETTY_NAME:-${id:-unknown}})."

    # R3: codename cunoscut? Primar necunoscut → die 3; derivat necunoscut → warn.
    local known_codename=no c
    for c in bookworm trixie jammy noble; do
        if [[ "$CODENAME" == "$c" ]]; then
            known_codename=yes
        fi
    done
    if [[ "$known_codename" != "yes" ]]; then
        if [[ "$id" == "debian" || "$id" == "ubuntu" ]]; then
            die 3 "Unknown codename for ${id}: '${CODENAME}'. Supported: bookworm, trixie, jammy, noble."
        fi
        warn "Derivative ${id}: codename '${CODENAME}' is not in the known list (bookworm/trixie/jammy/noble); official repos may not have a suite for it."
    fi

    DOCKER_REPO_URL="https://download.docker.com/linux/${DISTRO}"
    TAILSCALE_REPO_URL="https://pkgs.tailscale.com/stable/${DISTRO}"

    if [[ "$DISTRO" == "debian" ]]; then
        SECURITY_ORIGINS=(
            "origin=Debian,codename=${CODENAME},label=Debian-Security"
            "origin=Debian,codename=${CODENAME}-security,label=Debian-Security"
        )
    else
        SECURITY_ORIGINS=(
            "origin=Ubuntu,archive=${CODENAME}-security,label=Ubuntu"
            "origin=Ubuntu,archive=${CODENAME},label=Ubuntu"
        )
    fi
}

# F5: override-urile DS_* sunt doar pentru --dry-run sau medii de test (DS_TEST=1).
# La rulare reală, orice DS_* de test setat (exportat) => exit 2. DS_SSH_SOURCE și
# DS_TEST sunt exceptate; căile permise prin DS_TEST sunt validate strict.
guard_test_overrides() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        return 0
    fi
    if [[ "${DS_TEST:-}" == "1" ]]; then
        if [[ -n "${DS_TAILSCALE_OLD_LIST:-}" && "${DS_TAILSCALE_OLD_LIST}" != /etc/apt/sources.list.d/* ]]; then
            die 2 "DS_TAILSCALE_OLD_LIST must be under /etc/apt/sources.list.d/."
        fi
        return 0
    fi

    local v found=""
    while IFS= read -r v; do
        case "$v" in
            DS_SSH_SOURCE|DS_TEST) continue ;;
        esac
        found+="${v#DS_} "
    done < <(compgen -e | grep '^DS_' || true)

    if [[ -n "$found" ]]; then
        die 2 "Test DS_* variables detected in a real run (${found}). Remove them from the environment or use --dry-run (in test environments: DS_TEST=1)."
    fi
}

# ------------------------------------------------------------
# Parsare argumente și fișier de configurare
# ------------------------------------------------------------

# Încarcă un fișier cu linii KEY=value. Fără source: doar cheile
# din CONFIG_KEYS sunt acceptate, valorile sunt validate pe tip.
load_config() {
    local file="$1"
    local line raw_key key value

    if [[ ! -r "$file" ]]; then
        die 2 "Cannot read config file: $file"
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # ignoră liniile goale și comentariile
        if [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        if [[ "$line" != *"="* ]]; then
            die 2 "Invalid line in $file (expected format KEY=value): $line"
        fi

        raw_key="${line%%=*}"
        value="${line#*=}"
        key="${raw_key//[[:space:]]/}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        case "$key" in
            MODE)
                [[ "$value" == "lan" || "$value" == "vps" ]] \
                    || die 2 "MODE must be lan or vps (in $file)."
                ;;
            LAN_CIDR|WIREGUARD_CIDR|TAILSCALE_CIDR|TAILSCALE_IPV6_CIDR)
                valid_cidr "$value" || die 2 "$key invalid in $file: $value"
                ;;
            WIREGUARD_IFACE)
                [[ "$value" =~ ^[A-Za-z0-9._-]{1,15}$ ]] \
                    || die 2 "WIREGUARD_IFACE invalid in $file: $value"
                ;;
            DOCKER_POOL)
                valid_cidr "$value" || die 2 "DOCKER_POOL invalid in $file: $value"
                ;;
            DOCKER_CONFIG|DOCKER_BIND_LOCALHOST)
                [[ "$value" == "yes" || "$value" == "no" ]] \
                    || die 2 "$key must be yes or no (in $file)."
                ;;
            DOCKER_USER)
                [[ -n "$value" ]] || die 2 "DOCKER_USER cannot be empty (in $file)."
                ;;
            CREATE_USER)
                [[ "$value" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
                    || die 2 "CREATE_USER invalid in $file: $value"
                ;;
            SSH_KEY_FILE)
                [[ -n "$value" ]] || die 2 "SSH_KEY_FILE cannot be empty (in $file)."
                ;;
            ALLOW_USERS)
                local u
                for u in ${value//,/ }; do
                    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
                        || die 2 "ALLOW_USERS invalid in $file: $u"
                done
                ;;
            AUTO_REBOOT)
                [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
                    || die 2 "AUTO_REBOOT invalid in $file (format HH:MM): $value"
                ;;
            MAIL_ADDR)
                [[ "$value" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] \
                    || die 2 "MAIL_ADDR invalid in $file: $value"
                ;;
            SSH_KEYS_ONLY|UPDATE_THIRD_PARTY|SUDO_NOPASSWD)
                [[ "$value" == "yes" || "$value" == "no" ]] \
                    || die 2 "$key must be yes or no (in $file)."
                ;;
            MANAGE_SSH|SKIP_FIREWALL|INSTALL_DOCKER|INSTALL_TAILSCALE|INSTALL_FAIL2BAN|INSTALL_AUTO_UPDATES|RESET_FIREWALL|SKIP_UPGRADE|ALLOW_CURRENT_SSH)
                [[ "$value" == "yes" || "$value" == "no" ]] \
                    || die 2 "$key must be yes or no (in $file)."
                ;;
            *)
                die 2 "Disallowed key in $file: $key"
                ;;
        esac

        printf -v "$key" '%s' "$value"
        CHOICE_SOURCE["$key"]=config
    done <"$file"

    log_write INFO "Configuration loaded from $file"
}

# Parsare centralizată: --config se procesează într-o primă trecere,
# ca orice flag din linia de comandă să suprascrie valorile din fișier.
parse_args() {
    local args=("$@")
    local i

    for ((i = 0; i < ${#args[@]}; i++)); do
        if [[ "${args[i]}" == "--config" ]]; then
            if (( i + 1 >= ${#args[@]} )); then
                die 2 "Missing value for --config."
            fi
            CONFIG_FILE="${args[i + 1]}"
            load_config "$CONFIG_FILE"
        fi
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)
                NONINTERACTIVE=yes
                shift
                ;;
            --mode)
                [[ $# -ge 2 ]] || die 2 "Missing value for --mode."
                MODE="${2,,}"
                shift 2
                ;;
            --lan-cidr)
                [[ $# -ge 2 ]] || die 2 "Missing value for --lan-cidr."
                LAN_CIDR="$2"
                shift 2
                ;;
            --wireguard-cidr)
                [[ $# -ge 2 ]] || die 2 "Missing value for --wireguard-cidr."
                WIREGUARD_CIDR="$2"
                shift 2
                ;;
            --wireguard-iface)
                [[ $# -ge 2 ]] || die 2 "Missing value for --wireguard-iface."
                WIREGUARD_IFACE="$2"
                shift 2
                ;;
            --config)
                shift 2 # deja procesat în prima trecere
                ;;
            --print-config)
                PRINT_CONFIG=yes
                shift
                ;;
            --dry-run)
                DRY_RUN=yes
                shift
                ;;
            --version)
                PRINT_VERSION=yes
                shift
                ;;
            --inspect)
                INSPECT=yes
                shift
                ;;
            --wizard)
                WIZARD=yes
                shift
                ;;
            --no-ssh)
                MANAGE_SSH=no
                CHOICE_SOURCE[MANAGE_SSH]=cli
                shift
                ;;
            --no-firewall)
                SKIP_FIREWALL=yes
                CHOICE_SOURCE[SKIP_FIREWALL]=cli
                shift
                ;;
            --no-docker)
                INSTALL_DOCKER=no
                CHOICE_SOURCE[INSTALL_DOCKER]=cli
                shift
                ;;
            --no-tailscale)
                INSTALL_TAILSCALE=no
                CHOICE_SOURCE[INSTALL_TAILSCALE]=cli
                shift
                ;;
            --no-fail2ban)
                INSTALL_FAIL2BAN=no
                CHOICE_SOURCE[INSTALL_FAIL2BAN]=cli
                shift
                ;;
            --no-auto-updates)
                INSTALL_AUTO_UPDATES=no
                CHOICE_SOURCE[INSTALL_AUTO_UPDATES]=cli
                shift
                ;;
            --reset-firewall)
                RESET_FIREWALL=yes
                shift
                ;;
            --allow-current-ssh)
                ALLOW_CURRENT_SSH=yes
                shift
                ;;
            --skip-upgrade)
                SKIP_UPGRADE=yes
                CHOICE_SOURCE[SKIP_UPGRADE]=cli
                shift
                ;;
            --docker-pool)
                [[ $# -ge 2 ]] || die 2 "Missing value for --docker-pool."
                DOCKER_POOL="$2"
                shift 2
                ;;
            --docker-bind-localhost)
                DOCKER_BIND_LOCALHOST=yes
                shift
                ;;
            --no-docker-config)
                DOCKER_CONFIG=no
                shift
                ;;
            --docker-user)
                [[ $# -ge 2 ]] || die 2 "Missing value for --docker-user."
                DOCKER_USER="$2"
                shift 2
                ;;
            --create-user)
                [[ $# -ge 2 ]] || die 2 "Missing value for --create-user."
                CREATE_USER="$2"
                shift 2
                ;;
            --ssh-key-file)
                [[ $# -ge 2 ]] || die 2 "Missing value for --ssh-key-file."
                SSH_KEY_FILE="$2"
                shift 2
                ;;
            --ssh-key)
                [[ $# -ge 2 ]] || die 2 "Missing value for --ssh-key."
                SSH_KEY="$2"
                shift 2
                ;;
            --ssh-keys-only)
                SSH_KEYS_ONLY=yes
                shift
                ;;
            --no-sudo-nopasswd)
                SUDO_NOPASSWD=yes
                shift
                ;;
            --allow-users)
                [[ $# -ge 2 ]] || die 2 "Missing value for --allow-users."
                ALLOW_USERS="$2"
                shift 2
                ;;
            --auto-reboot)
                [[ $# -ge 2 ]] || die 2 "Missing value for --auto-reboot."
                AUTO_REBOOT="$2"
                shift 2
                ;;
            --mail)
                [[ $# -ge 2 ]] || die 2 "Missing value for --mail."
                MAIL_ADDR="$2"
                shift 2
                ;;
            --update-third-party)
                UPDATE_THIRD_PARTY=yes
                shift
                ;;
            --strict)
                STRICT=yes
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die 2 "Unknown option: $1 (see --help)"
                ;;
        esac
    done
}

# ------------------------------------------------------------
# Preflight
# ------------------------------------------------------------

require_root() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi
    if [[ "$DRY_RUN" == "yes" && "${DS_ROOT_OK:-}" == "1" ]]; then
        warn "Running as non-root in --dry-run (DS_ROOT_OK=1); no mutation is performed."
        return 0
    fi
    die 3 "Run the script with sudo or as root."
}

check_proxmox() {
    if command -v pveversion >/dev/null 2>&1; then
        die 3 "Proxmox VE detected (pveversion). This script must not be run on a Proxmox host; use it in a VM or LXC."
    fi
}

resolve_mode() {
    if [[ -z "$MODE" ]]; then
        if [[ "$DRY_RUN" == "yes" && "$WIZARD" != "yes" ]]; then
            MODE=lan
            info "DRY-RUN without --mode: defaulting to lan (change with --mode)."
        elif [[ "$NONINTERACTIVE" == "yes" ]]; then
            die "In non-interactive mode you must specify --mode lan or --mode vps."
        else
            echo "Where does this machine run?"
            echo "  1) LAN — SSH from the local network and VPN"
            echo "  2) VPS — SSH from VPN only"
            read -r -p "Choose [1]: " mode_answer || die 2 "Input closed; configuration cancelled without applying changes."
            mode_answer="${mode_answer:-1}"
            case "$mode_answer" in
                1) MODE=lan ;;
                2) MODE=vps ;;
                *) die "Invalid mode: $mode_answer" ;;
            esac
        fi
    fi

    [[ "$MODE" == "lan" || "$MODE" == "vps" ]] \
        || die 2 "--mode must be lan or vps."
}

resolve_lan_cidr() {
    if [[ -z "$LAN_CIDR" && "$MODE" == "lan" ]]; then
        if [[ "$DRY_RUN" == "yes" && "$WIZARD" != "yes" || "$NONINTERACTIVE" == "yes" ]]; then
            LAN_CIDR="$DETECTED_LAN_CIDR"
        else
            read -r -p "LAN CIDR [${DETECTED_LAN_CIDR:-e.g. 192.168.1.0/24}]: " LAN_CIDR \
                || die 2 "Input closed; configuration cancelled without applying changes."
            LAN_CIDR="${LAN_CIDR:-$DETECTED_LAN_CIDR}"
        fi
    fi

    if [[ -n "$LAN_CIDR" ]]; then
        valid_cidr "$LAN_CIDR" || die "Invalid LAN CIDR: $LAN_CIDR"
    fi
}

resolve_wireguard_cidr() {
    if [[ -n "$WIREGUARD_CIDR" ]]; then
        valid_cidr "$WIREGUARD_CIDR" || die "Invalid WireGuard CIDR: $WIREGUARD_CIDR"
    elif [[ ( "$DRY_RUN" != "yes" || "$WIZARD" == "yes" ) && "$NONINTERACTIVE" != "yes" ]]; then
        if yes_no "Allow SSH from WireGuard?" y; then
            read -r -p "WireGuard subnet or the source seen by the server (e.g. 10.8.0.0/24): " WIREGUARD_CIDR \
                || die 2 "Input closed; configuration cancelled without applying changes."
            [[ -z "$WIREGUARD_CIDR" ]] || valid_cidr "$WIREGUARD_CIDR" \
                || die "Invalid WireGuard CIDR: $WIREGUARD_CIDR"
        fi
    fi

    # B5: interfață WireGuard pentru reguli UFW 'in on <iface>'
    if [[ -n "$WIREGUARD_IFACE" ]]; then
        [[ "$WIREGUARD_IFACE" =~ ^[A-Za-z0-9._-]{1,15}$ ]] \
            || die 2 "Invalid WireGuard interface name: $WIREGUARD_IFACE"
    fi
}

# dpkg database facts, not guesses based on executable names or open ports.
package_state() {
    local state
    if ! command -v dpkg-query >/dev/null 2>&1; then
        printf 'unknown'
        return 0
    fi
    state="$(dpkg-query -W -f='${Status}' -- "$1" 2>/dev/null || true)"
    case "$state" in
        'install ok installed') printf 'installed' ;;
        '') printf 'absent-or-unregistered' ;;
        *) printf 'not-fully-installed' ;;
    esac
}

print_inventory() {
    local package service active enabled
    echo 'READ-ONLY INVENTORY — no configuration is changed'
    printf 'OS: %s; architecture: %s\n' "${PRETTY_NAME:-unknown}" "$(uname -m)"
    for package in docker-ce docker.io tailscale fail2ban unattended-upgrades openssh-server ufw; do
        printf 'Package %-22s %s\n' "$package" "$(package_state "$package")"
    done
    for service in docker tailscaled fail2ban ssh ufw; do
        active=unknown enabled=unknown
        if command -v systemctl >/dev/null 2>&1; then
            active="$(systemctl is-active "$service.service" 2>/dev/null || true)"
            enabled="$(systemctl is-enabled "$service.service" 2>/dev/null || true)"
        fi
        printf 'Service %-22s active=%s enabled=%s\n' "$service" "${active:-unknown}" "${enabled:-unknown}"
    done
    printf 'SSH source: %s; detected port: %s\n' "${SSH_SOURCE_IP:-unknown}" "$SSH_PORT"
    printf 'LAN candidate: %s (inferred, confirm before using)\n' "${DETECTED_LAN_CIDR:-unknown}"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local virtualization
        virtualization="$(systemd-detect-virt 2>/dev/null || true)"
        printf 'Virtualization: %s\n' "${virtualization:-unknown}"
    fi
    local path
    for path in /etc/docker/daemon.json /etc/ssh/sshd_config /etc/ufw/ufw.conf; do
        if [[ -e "$path" ]]; then
            printf 'Configuration exists: %s (contents not collected)\n' "$path"
        fi
    done
    echo 'Public exposure, VPN reachability and provider firewall: UNKNOWN; not inferred from private IPs.'
    [[ ! -e /var/run/reboot-required ]] || echo 'Reboot-required marker present; no reboot will be performed.'
    return 0
}

resolve_component() {
    local key="$1" package="$2" prompt="$3" default=y state
    [[ -z "${CHOICE_SOURCE[$key]:-}" ]] || return 0
    if [[ "$WIZARD" == "yes" ]]; then
        state="$(package_state "$package")"
        printf '\n%s: %s. No = preserve/omit; nothing is uninstalled.\n' "$package" "$state"
        # Conservative for installed, unregistered alternative packages and unknown states.
        default=n
    fi
    if yes_no "$prompt" "$default"; then
        printf -v "$key" yes
    else
        printf -v "$key" no
    fi
    CHOICE_SOURCE["$key"]=wizard
}

resolve_feature_flags() {
    if [[ "$DRY_RUN" == "yes" && "$WIZARD" != "yes" || "$NONINTERACTIVE" == "yes" ]]; then
        return 0
    fi
    resolve_component INSTALL_DOCKER docker-ce "Install/configure Docker Engine and Compose?"
    resolve_component INSTALL_TAILSCALE tailscale "Install/configure Tailscale?"
    resolve_component INSTALL_FAIL2BAN fail2ban "Install/configure Fail2Ban for SSH?"
    resolve_component INSTALL_AUTO_UPDATES unattended-upgrades "Enable automatic security updates?"
}

resolve_access_choices() {
    [[ "$WIZARD" == "yes" ]] || return 0
    echo 'Wizard: Enter keeps the existing services and access. There is no timed rollback.'
    if [[ -z "${CHOICE_SOURCE[MANAGE_SSH]:-}" && "$SSH_KEYS_ONLY" != "yes" && -z "$ALLOW_USERS" ]]; then
        if yes_no 'Modify the SSH configuration? Recommended: No, especially over SSH.' n; then
            MANAGE_SSH=yes
        else
            MANAGE_SSH=no
        fi
    fi
    if [[ -z "${CHOICE_SOURCE[SKIP_FIREWALL]:-}" && "$RESET_FIREWALL" != "yes" ]]; then
        if yes_no 'Configure the UFW firewall? You need alternative console access.' n; then
            SKIP_FIREWALL=no
        else
            SKIP_FIREWALL=yes
        fi
    fi
    if [[ -z "${CHOICE_SOURCE[SKIP_UPGRADE]:-}" ]]; then
        if yes_no 'Upgrade ALL system packages (including preserved services)?' n; then
            SKIP_UPGRADE=no
        else
            SKIP_UPGRADE=yes
        fi
    fi
}

validate_selection() {
    [[ "$WIZARD" != "yes" || "$NONINTERACTIVE" != "yes" ]] \
        || die 2 "--wizard requires interaction; do not combine it with --yes."
    [[ "$MANAGE_SSH" != "no" || ( "$SSH_KEYS_ONLY" != "yes" && -z "$ALLOW_USERS" ) ]] \
        || die 2 "--no-ssh / MANAGE_SSH=no conflicts with the requested SSH policy."
    [[ "$SKIP_FIREWALL" != "yes" || "$RESET_FIREWALL" != "yes" ]] \
        || die 2 "Firewall skipped: cannot apply --reset-firewall."
}

# C4: validare timpurie pentru flag-urile Docker
resolve_docker_flags() {
    if [[ -n "$DOCKER_POOL" ]]; then
        valid_cidr "$DOCKER_POOL" || die 2 "Invalid Docker pool CIDR: $DOCKER_POOL"
    fi
    if [[ -n "$DOCKER_USER" ]] && ! cmd_getent passwd "$DOCKER_USER" >/dev/null 2>&1; then
        die 2 "User '$DOCKER_USER' does not exist; create it first or omit --docker-user."
    fi
}

# R1: colectează IP-urile sursă ale conexiunilor established pe portul SSH
# (sesiuni văzute din afară — folosite pentru warn, nu pentru die)
collect_established_peers() {
    SSH_ESTABLISHED_PEERS=""
    local line peer
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        peer="$(awk '{print $5}' <<<"$line")"
        peer="${peer%:*}"
        peer="${peer#[}"
        peer="${peer%]}"
        [[ "$peer" =~ ^[0-9A-Fa-f:.]+$ ]] || continue
        SSH_ESTABLISHED_PEERS+="${peer} "
    done < <(cmd_ss -Htn state established "( sport = :$SSH_PORT )" 2>/dev/null)
}

# R1: warn vizibil pentru sesiuni SSH established din surse neacoperite de CIDR-uri
warn_uncovered_established() {
    local peer p

    UNCOVERED_PEERS=""
    if [[ "$SSH_SESSION_IS_SSH" == "yes" || -z "$SSH_ESTABLISHED_PEERS" ]]; then
        return 0
    fi

    for peer in ${SSH_ESTABLISHED_PEERS}; do
        local covered=no
        for p in "${SSH_CIDRS[@]}"; do
            if ip_in_cidr "$peer" "$p"; then
                covered=yes
                break
            fi
        done
        if [[ "$covered" != "yes" ]]; then
            UNCOVERED_PEERS+="${peer} "
        fi
    done

    if [[ -n "$UNCOVERED_PEERS" ]]; then
        warn "Active SSH connections from sources not covered by the allowed CIDRs: ${UNCOVERED_PEERS} — check --lan-cidr/--wireguard-cidr; a real run requires an explicit decision (--allow-current-ssh or confirmation)."
    fi
}

# validarea unei chei publice SSH (string) cu ssh-keygen
validate_ssh_public_key() {
    local key="$1"
    [[ -n "$key" ]] || return 1
    printf '%s\n' "$key" | cmd_ssh_keygen -lf - >/dev/null 2>&1
}

# A4: utilizatorul curent de administrare (SUDO_USER → logname → root)
current_admin_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
        printf '%s' "$SUDO_USER"
        return 0
    fi
    if command -v logname >/dev/null 2>&1; then
        local ln
        ln="$(logname 2>/dev/null || true)"
        if [[ -n "$ln" ]]; then
            printf '%s' "$ln"
            return 0
        fi
    fi
    printf 'root'
}

# C5: validare A1-A4 + U1-U2 + precondiția hard pentru --ssh-keys-only
resolve_ssh_hardening() {
    local u

    if [[ -n "$CREATE_USER" && ! "$CREATE_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        die 2 "Invalid user name: $CREATE_USER"
    fi

    if [[ -n "$SSH_KEY_FILE" && -n "$SSH_KEY" ]]; then
        die 2 "Use only one: --ssh-key-file or --ssh-key."
    fi

    if [[ -n "$SSH_KEY_FILE" ]]; then
        if [[ ! -r "$SSH_KEY_FILE" ]]; then
            die 2 "Cannot read key file: $SSH_KEY_FILE"
        fi
        if ! cmd_ssh_keygen -lf "$SSH_KEY_FILE" >/dev/null 2>&1; then
            die 2 "File $SSH_KEY_FILE does not contain a valid SSH public key."
        fi
    fi

    if [[ -n "$SSH_KEY" ]] && ! validate_ssh_public_key "$SSH_KEY"; then
        die 2 "The SSH key passed via --ssh-key is not valid."
    fi

    if [[ -n "$ALLOW_USERS" ]]; then
        local found=no cur
        for u in ${ALLOW_USERS//,/ }; do
            if [[ ! "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
                die 2 "Invalid user in --allow-users: '$u'"
            fi
            cur="$(current_admin_user)"
            if [[ "$u" == "$cur" || "$u" == "$CREATE_USER" ]]; then
                found=yes
            fi
        done
        if [[ "$found" != "yes" ]]; then
            die 4 "--allow-users does not include the current user ($cur) nor the --create-user user; you would lock yourself out of SSH. Add them to the list."
        fi
    fi

    if [[ -n "$AUTO_REBOOT" && ! "$AUTO_REBOOT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        die 2 "Invalid time for --auto-reboot (format HH:MM): $AUTO_REBOOT"
    fi

    if [[ -n "$MAIL_ADDR" && ! "$MAIL_ADDR" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]]; then
        die 2 "Invalid email address: $MAIL_ADDR"
    fi

    # U2: fără MTA, rapoartele pe e-mail nu pot pleca
    if [[ -n "$MAIL_ADDR" ]] && ! command -v sendmail >/dev/null 2>&1 && ! command -v mail >/dev/null 2>&1; then
        warn "No MTA found (sendmail/mail): reports to $MAIL_ADDR will not be sent. Install mailutils/postfix."
    fi

    # A2/F3: precondiție hard pentru --ssh-keys-only — cine rămâne cu login capabil?
    if [[ "$SSH_KEYS_ONLY" == "yes" ]]; then
        local capable="" cur_admin
        capable="$(ssh_login_capable_users || true)"
        if [[ -z "$capable" ]]; then
            die 4 "Precondition --ssh-keys-only not met: no privileged account (root/sudo) has a valid SSH key in authorized_keys. Install one with --create-user + --ssh-key-file or add a key for root manually, then rerun."
        fi
        if [[ "$SSH_SESSION_IS_SSH" == "yes" ]]; then
            cur_admin="$(current_admin_user)"
            if ! grep -qx -- "$cur_admin" <<<"$capable"; then
                die 4 "--ssh-keys-only: the current account '$cur_admin' will no longer be able to log in (no valid key${ALLOW_USERS:+ / excluded by --allow-users}). Add a key for it or include it in --allow-users, otherwise you lock yourself out."
            fi
        else
            info "Console: --ssh-keys-only enables key-only login; make sure you have alternative access."
        fi
    fi
}

# A2: are minim un cont privilegiat (root sau membru sudo) o cheie validă?
ssh_keys_present_for_privileged() {
    local users="root" u grp_members home

    grp_members="$(cmd_getent group sudo 2>/dev/null | awk -F: '{print $4}' || true)"
    for u in ${grp_members//,/ }; do
        if [[ -n "$u" ]]; then users+=" $u"; fi
    done

    for u in $users; do
        home="$(cmd_getent passwd "$u" 2>/dev/null | awk -F: '{print $6}' || true)"
        if [[ -n "$home" && -r "$home/.ssh/authorized_keys" ]] \
            && cmd_ssh_keygen -lf "$home/.ssh/authorized_keys" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

build_ssh_cidrs() {
    if [[ -n "$LAN_CIDR" ]]; then
        add_ssh_cidr "$LAN_CIDR"
    fi
    if [[ -n "$WIREGUARD_CIDR" ]]; then
        add_ssh_cidr "$WIREGUARD_CIDR"
    fi
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        # B5/B7: CIDR-urile Tailscale rămân permanente (v4 + v6)
        add_ssh_cidr "$TAILSCALE_CIDR"
        add_ssh_cidr "$TAILSCALE_IPV6_CIDR"
    fi

    if [[ "$ALLOW_CURRENT_SSH" == "yes" && -n "$SSH_SOURCE_IP" ]]; then
        if [[ "$SSH_SOURCE_IP" == *:* ]]; then
            add_ssh_cidr "${SSH_SOURCE_IP}/128"
        else
            add_ssh_cidr "${SSH_SOURCE_IP}/32"
        fi
    fi

    if (( ${#SSH_CIDRS[@]} == 0 )); then
        die 4 "No network is allowed for SSH. Configure WireGuard/Tailscale or --lan-cidr."
    fi
}

# Detectează cazul în care firewall-ul din guest nu poate funcționa.
detect_lxc_unprivileged() {
    if command -v systemd-detect-virt >/dev/null 2>&1 \
        && cmd_detect_virt --quiet --container \
        && [[ -r /proc/1/uid_map ]]; then
        local uid_outside
        uid_outside="$(awk 'NR == 1 {print $2}' /proc/1/uid_map)"
        if [[ -n "$uid_outside" && "$uid_outside" != "0" ]]; then
            SKIP_FIREWALL=yes
            warn "Unprivileged LXC detected: UFW/Fail2Ban will not be enabled in the guest."
        fi
    fi
}

preflight() {
    require_root
    check_proxmox
    detect_distro

    require_tty_or_yes
    detect_ssh_port
    detect_ssh_socket
    detect_ssh_source
    DETECTED_LAN_CIDR="$(detect_lan_cidr || true)"

    if [[ "$WIZARD" == "yes" ]]; then
        print_inventory
        resolve_access_choices
    fi
    resolve_mode
    if [[ "$SKIP_FIREWALL" != "yes" ]]; then
        resolve_lan_cidr
        resolve_wireguard_cidr
    fi
    resolve_feature_flags
    resolve_docker_flags
    resolve_ssh_hardening
    validate_selection
    if [[ "$SKIP_FIREWALL" != "yes" ]]; then
        build_ssh_cidrs
        warn_uncovered_established
    fi
    detect_lxc_unprivileged
}

# ------------------------------------------------------------
# U-verificare: fail-loud — unattended-upgrade trebuie să listeze originea
# de securitate a distribuției; altfel warn puternic, sau exit 1 cu --strict.
verify_unattended_origins() {
    local out want_label

    out="$(cmd_unattended_upgrade --dry-run --debug 2>&1 || true)"
    # eticheta așteptată vine din layer-ul distro (primul origin declarat)
    want_label="${SECURITY_ORIGINS[0]##*,}"

    if grep -q -- "${CODENAME}-security" <<<"$out" && grep -q -- "$want_label" <<<"$out"; then
        ok "unattended-upgrades uses the distribution security origin (${CODENAME}-security)."
        return 0
    fi

    if [[ "$STRICT" == "yes" ]]; then
        die 1 "The unattended-upgrades check failed: origin '${CODENAME}-security' does not appear in 'unattended-upgrade --dry-run --debug'. Automatic security updates are NOT working. (--strict)"
    fi
    warn "UNATTENDED CHECK: origin '${CODENAME}-security' does not appear in 'unattended-upgrade --dry-run --debug'. Automatic security updates may NOT be working; check manually. (use --strict for exit 1)"
}

# Bootstrap (toate mutațiile trec prin run()/write_file())
# ------------------------------------------------------------

# Dacă sesiunea SSH curentă nu este în una dintre rețelele configurate,
# refuzăm activarea firewall-ului pentru a evita lockout-ul accidental.
# În modul vps, sesiunea poate fi acoperită de regulile pe interfață
# (tailscale0 / --wireguard-iface): cere confirmare explicită.
check_current_session_allowed() {
    local cidr cand covered uncovered=""

    if [[ "$SKIP_FIREWALL" == "yes" ]]; then
        return 0
    fi

    # F2: candidatți = sesiunea curentă (dacă e cunoscută) + peer-uri established
    # neacoperite (tmux/screen/systemd-run — lanțul PPID nu ajunge la sshd)
    local candidates=""
    if [[ -n "$SSH_SOURCE_IP" ]]; then
        candidates="${SSH_SOURCE_IP} "
    fi
    candidates+="$UNCOVERED_PEERS"

    if [[ -z "${candidates// /}" ]]; then
        return 0
    fi

    for cand in $candidates; do
        covered=no
        for cidr in "${SSH_CIDRS[@]}"; do
            if ip_in_cidr "$cand" "$cidr"; then
                covered=yes
                break
            fi
        done
        if [[ "$covered" != "yes" ]]; then
            uncovered+="${cand} "
        fi
    done

    if [[ -z "${uncovered// /}" ]]; then
        return 0
    fi

    # F2: --allow-current-ssh acoperă fiecare candidat neacoperit (/32 sau /128)
    if [[ "$ALLOW_CURRENT_SSH" == "yes" ]]; then
        for cand in $uncovered; do
            if [[ "$cand" == *:* ]]; then
                add_ssh_cidr "${cand}/128"
            else
                add_ssh_cidr "${cand}/32"
            fi
            log_write INFO "Allow SSH access for ${cand} (--allow-current-ssh)"
        done
        return 0
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
        warn "Sessions uncovered by the proposed rules (${uncovered}); a real run requires explicit confirmation or --allow-current-ssh."
        return 0
    fi

    if [[ "$NONINTERACTIVE" == "yes" ]]; then
        die 4 "SSH sessions uncovered by the proposed rules: ${uncovered}. Use --allow-current-ssh, fix --lan-cidr/--wireguard-cidr or set DS_SSH_SOURCE=IP."
    fi

    warn "SSH sessions uncovered by the proposed rules: ${uncovered}."
    if yes_no "Confirm that these sessions lose SSH access and you have alternative access (console/Tailscale/WireGuard)?" n; then
        log_write INFO "Uncovered SSH sessions explicitly confirmed by the user"
        return 0
    fi
    die 4 "I will not enable the firewall without confirmed SSH access. Use --allow-current-ssh, fix the CIDRs or set DS_SSH_SOURCE=IP."
}

# A1: adaugă cheia în authorized_keys doar dacă lipsește; rc 0 = a scris acum
ssh_key_append_if_missing() {
    local ak="$1" key="$2"
    if [[ -f "$ak" ]] && grep -qxF -- "$key" "$ak"; then
        return 1
    fi
    printf '%s\n' "$key" | run tee -a "$ak" >/dev/null
}

# F4: parola userului e blocată? (al doilea câmp din „passwd -S”)
user_password_locked() {
    local st
    st="$(cmd_passwd -S "$1" 2>/dev/null | awk '{print $2}' || true)"
    [[ "$st" == "L" ]]
}

# F4: userul are deja o cheie validă în authorized_keys?
user_has_valid_key() {
    local u="$1" home
    home="$(cmd_getent passwd "$u" 2>/dev/null | awk -F: '{print $6}' || true)"
    if [[ -n "$home" && -r "$home/.ssh/authorized_keys" ]] \
        && cmd_ssh_keygen -lf "$home/.ssh/authorized_keys" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# A1: creează (idempotent) userul din --create-user: sudo, parolă blocată, cheie.
# F4: pentru cont nou-creat sau deja blocat, cu cheie, acordă sudo NOPASSWD
# (sudoers validat cu visudo); --no-sudo-nopasswd renunță la ambele.
configure_created_user() {
    if [[ -z "$CREATE_USER" ]]; then
        return 0
    fi

    local created_now=no

    info "Configuring user $CREATE_USER..."

    if ! cmd_getent passwd "$CREATE_USER" >/dev/null 2>&1; then
        run useradd -m -s /bin/bash "$CREATE_USER"
        created_now=yes
        ok "User $CREATE_USER was created (bash shell)."
    else
        info "User $CREATE_USER already exists; reusing it."
    fi

    run usermod -aG sudo "$CREATE_USER"

    local key_installed=no
    if [[ -n "$SSH_KEY_FILE" || -n "$SSH_KEY" ]]; then
        local target_user home ak key_line
        target_user="$CREATE_USER"
        home="$(cmd_getent passwd "$target_user" 2>/dev/null | awk -F: '{print $6}' || true)"
        if [[ -z "$home" ]]; then
            home="/home/$target_user"
        fi

        run install -d -m 0700 -o "$target_user" -g "$target_user" "$home/.ssh"
        ak="$home/.ssh/authorized_keys"
        if [[ -n "$SSH_KEY_FILE" ]]; then
            key_line="$(grep -m1 -vE '^(\s*#)?\s*$' "$SSH_KEY_FILE" 2>/dev/null || true)"
        else
            key_line="$SSH_KEY"
        fi
        if ssh_key_append_if_missing "$ak" "$key_line"; then
            run chmod 0600 "$ak"
            run chown "$target_user:$target_user" "$ak"
            ok "SSH key installed for $target_user."
        else
            info "Key already in authorized_keys for $target_user; not duplicating."
        fi
        run chown "$target_user:$target_user" "$home/.ssh"
        run chmod 0700 "$home/.ssh"
        key_installed=yes
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
        if [[ "$SUDO_NOPASSWD" == "yes" ]]; then
            warn "--no-sudo-nopasswd: not writing sudoers and not locking the password; set it manually with passwd."
        else
            info "Writing sudoers NOPASSWD for $CREATE_USER (validated with visudo) and locking the password."
        fi
        return 0
    fi

    # F4: parola se blochează doar dacă: creat acum sau deja blocat, ȘI cheie prezentă
    local can_lock=no
    if [[ "$created_now" == "yes" ]] || user_password_locked "$CREATE_USER"; then
        can_lock=yes
    fi
    if [[ "$key_installed" != "yes" ]] && ! user_has_valid_key "$CREATE_USER"; then
        can_lock=no
    fi

    if [[ "$SUDO_NOPASSWD" == "yes" ]]; then
        warn "--no-sudo-nopasswd: not writing sudoers and not locking the password; set it manually with 'passwd $CREATE_USER'."
    elif [[ "$created_now" != "yes" ]] && ! user_password_locked "$CREATE_USER"; then
        warn "$CREATE_USER has an active password: not locking the password and not granting NOPASSWD (use the account as is or manage it manually)."
    else
        if [[ "$can_lock" == "yes" ]]; then
            local sudoers_dir="${DS_SUDOERS_DIR:-/etc/sudoers.d}"
            local sudoers_file="$sudoers_dir/90-bootstrap-$CREATE_USER"
            local tmp visudo_rc=0
            tmp="$(mktemp)"
            printf '%s\n' "$CREATE_USER ALL=(ALL) NOPASSWD:ALL" >"$tmp"
            cmd_visudo -cf "$tmp" || visudo_rc=$?
            if [[ "$visudo_rc" != "0" ]]; then
                rm -f "$tmp"
                die 1 "sudoers validation failed (visudo -cf); not installing $sudoers_file."
            fi
            run install -d -m 0755 "$sudoers_dir"
            run install -m 0440 "$tmp" "$sudoers_file"
            rm -f "$tmp"
            run passwd -l "$CREATE_USER"
            ok "$CREATE_USER: sudo NOPASSWD (sudoers validated) + password locked."
        else
            warn "$CREATE_USER: no valid key installed — not locking the password (lockout risk); install a key or set it manually."
        fi
    fi
}

# F3: conturile care vor putea face login SSH după rulare (cu keys-only).
# Candidat i: root, membri sudo, CREATE_USER, userul curent. Capabil = are
# authorized_keys valid SAU e CREATE_USER cu cheie ce va fi instalată acum.
# Dacă ALLOW_USERS e setat, candidatul trebuie să fie în listă (root inclus).
ssh_login_capable_users() {
    local users="" u grp_members home
    local candidates="root"

    grp_members="$(cmd_getent group sudo 2>/dev/null | awk -F: '{print $4}' || true)"
    for u in ${grp_members//,/ }; do
        if [[ -n "$u" ]]; then candidates+=" $u"; fi
    done
    if [[ -n "$CREATE_USER" ]]; then candidates+=" $CREATE_USER"; fi
    candidates+=" $(current_admin_user)"

    local allowed_list=""
    if [[ -n "$ALLOW_USERS" ]]; then
        allowed_list=" ${ALLOW_USERS//,/ } "
    fi

    for u in $candidates; do
        if [[ -z "$u" ]]; then continue; fi
        case " $users " in *" $u "*) continue ;; esac
        if [[ -n "$allowed_list" ]]; then
            case "$allowed_list" in *" $u "*) ;; *) continue ;; esac
        fi
        if [[ "$u" == "$CREATE_USER" && ( -n "$SSH_KEY_FILE" || -n "$SSH_KEY" ) ]]; then
            users+="${u}"$'\n'   # cheia va fi instalată în această rulare
            continue
        fi
        home="$(cmd_getent passwd "$u" 2>/dev/null | awk -F: '{print $6}' || true)"
        if [[ -n "$home" && -r "$home/.ssh/authorized_keys" ]] \
            && cmd_ssh_keygen -lf "$home/.ssh/authorized_keys" >/dev/null 2>&1; then
            users+="${u}"$'\n'
        fi
    done

    if [[ -n "$users" ]]; then
        printf '%s' "$users"
        return 0
    fi
    return 1
}

configure_auto_updates() {
    if [[ "$INSTALL_AUTO_UPDATES" != "yes" ]]; then
        return 0
    fi

    info "Configuring automatic security updates..."

    write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # Origins-Pattern pe distro (placeholder-ul ${distro_codename} rămâne literal,
    # să-l substitute unattended-upgrades). ESM doar ca comentariu (Ubuntu Pro).
    local origins_block
    if [[ "$DISTRO" == "debian" ]]; then
        # shellcheck disable=SC2016 # Expanded later by unattended-upgrades.
        origins_block='    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
    else
        # shellcheck disable=SC2016 # Expanded later by unattended-upgrades.
        origins_block='    "origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu";
    "origin=Ubuntu,archive=${distro_codename},label=Ubuntu";
    // ESM (Ubuntu Pro): enabled manually with ubuntu-advantage; ignored when not enabled:
    // "origin=UbuntuESM,archive=${distro_codename}-infra-security,label=UbuntuESM";'
    fi

    # U3: opțional — actualizări și pentru repo-urile third-party (Docker/Tailscale)
    if [[ "$UPDATE_THIRD_PARTY" == "yes" ]]; then
        origins_block+=$'\n    "origin=Docker,codename=${distro_codename}";'
        origins_block+=$'\n    "origin=Tailscale,codename=${distro_codename}";'
    fi

    # U1/U2: directive suplimentare, după valoarea implicită "false" (ultima câștigă)
    local extra_block=""
    if [[ -n "$MAIL_ADDR" ]]; then
        extra_block+="Unattended-Upgrade::Mail \"$MAIL_ADDR\";"$'\n'
        extra_block+='Unattended-Upgrade::MailReport "on-change";'$'\n'
    fi
    if [[ -n "$AUTO_REBOOT" ]]; then
        extra_block+='Unattended-Upgrade::Automatic-Reboot "true";'$'\n'
        extra_block+="Unattended-Upgrade::Automatic-Reboot-Time \"$AUTO_REBOOT\";"$'\n'
    fi

    write_file /etc/apt/apt.conf.d/52-bootstrap-security 0644 <<EOF
# Automatic updates limited to the distribution's security origins.
Unattended-Upgrade::Origins-Pattern {
${origins_block}
};

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
${extra_block}
EOF

    run systemctl enable --now apt-daily.timer 2>/dev/null \
        || warn "Could not enable apt-daily.timer."
    run systemctl enable --now apt-daily-upgrade.timer 2>/dev/null \
        || warn "Could not enable apt-daily-upgrade.timer."
    ok "Automatic security updates are enabled."
}

# B4: cheia Docker trebuie să aibă exact fingerprintul pinuit; mismatch → șterge + die.
verify_docker_key_fingerprint() {
    local keyfile="$1"
    local out

    out="$(cmd_gpg --show-keys --with-colons "$keyfile" 2>/dev/null || true)"
    if ! grep -q "$DOCKER_GPG_FINGERPRINT" <<<"$out"; then
        run rm -f "$keyfile"
        die 1 "The Docker key does not have the expected fingerprint (${DOCKER_GPG_FINGERPRINT}). I deleted $keyfile; check the source/network (possible MITM) and rerun."
    fi
    log_write INFO "Docker key verified: fingerprint ${DOCKER_GPG_FINGERPRINT}"
}

# B4: cheia Tailscale doar validată ca PGP; fingerprint în log, FĂRĂ pin (rotație liberă).
verify_tailscale_key() {
    local keyfile="$1"
    local out fpr

    out="$(cmd_gpg --show-keys --with-colons "$keyfile" 2>/dev/null || true)"
    fpr="$(grep -E '^fpr:' <<<"$out" | awk -F: '{print $10}' | head -1)"
    if [[ -z "$fpr" ]]; then
        run rm -f "$keyfile"
        die 1 "The Tailscale key is not a valid PGP keyring; I deleted $keyfile. Check the source/network and rerun."
    fi
    log_write INFO "Valid Tailscale key (PGP), fingerprint: ${fpr} (not pinned, may be rotated)"
}

setup_docker_repository() {
    info "Configuring the official Docker stable repository..."

    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL "${DOCKER_REPO_URL}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "Real run: verifying the Docker key fingerprint (${DOCKER_GPG_FINGERPRINT}) with gpg --show-keys."
    else
        verify_docker_key_fingerprint /etc/apt/keyrings/docker.asc
    fi

    write_file /etc/apt/sources.list.d/docker.sources 0644 <<EOF
Types: deb
URIs: ${DOCKER_REPO_URL}
Suites: ${CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

setup_tailscale_repository() {
    info "Configuring the official Tailscale stable repository..."

    run install -m 0755 -d /usr/share/keyrings
    run curl -fsSL "${TAILSCALE_REPO_URL}/${CODENAME}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    run chmod a+r /usr/share/keyrings/tailscale-archive-keyring.gpg

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "Real run: validating the Tailscale key as PGP with gpg --show-keys (not pinned)."
    else
        verify_tailscale_key /usr/share/keyrings/tailscale-archive-keyring.gpg
    fi

    # R2: curățenie — un tailscale.list vechi (rulări cu scriptul original)
    # ar produce „configured multiple times”; îl eliminăm
    local old_list="${DS_TAILSCALE_OLD_LIST:-/etc/apt/sources.list.d/tailscale.list}"
    if [[ -e "$old_list" ]]; then
        log_write INFO "Removing old ${old_list} (replaced by tailscale.sources)"
        run rm -f "$old_list"
    fi

    # B4/R2: repo deb822 scris local, nu descărcat
    write_file /etc/apt/sources.list.d/tailscale.sources 0644 <<EOF
Types: deb
URIs: ${TAILSCALE_REPO_URL}
Suites: ${CODENAME}
Components: main
Signed-By: /usr/share/keyrings/tailscale-archive-keyring.gpg
EOF
}

# B8: Docker în LXC neprivilegiat are nevoie de nesting pe host
detect_lxc_docker() {
    DOCKER_LXC_NO_NESTING=no
    [[ "$INSTALL_DOCKER" == "yes" ]] || return 0
    if command -v systemd-detect-virt >/dev/null 2>&1 \
        && cmd_detect_virt --quiet --container \
        && [[ -r /proc/1/uid_map ]]; then
        local uid_outside
        uid_outside="$(awk 'NR == 1 {print $2}' /proc/1/uid_map)"
        if [[ -n "$uid_outside" && "$uid_outside" != "0" ]]; then
            DOCKER_LXC_NO_NESTING=yes
        fi
    fi
}

# D1: elimină pachetele conflictuale cu Docker (doar remove, fără purge)
remove_docker_conflicts() {
    local present=() pkg

    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        if cmd_dpkg -s "$pkg" >/dev/null 2>&1; then
            present+=("$pkg")
        fi
    done

    if (( ${#present[@]} > 0 )); then
        info "Removing packages that conflict with Docker: ${present[*]}"
        run apt-get "${APT_OPTS[@]}" remove "${present[@]}"
    else
        log_write INFO "D1: no packages conflict with Docker"
    fi

    if command -v snap >/dev/null 2>&1 && cmd_snap list docker >/dev/null 2>&1; then
        info "Removing the docker snap..."
        run snap remove docker
    fi
}

install_docker() {
    info "Installing Docker Engine, Buildx and the Docker Compose plugin..."
    if [[ "$DOCKER_LXC_NO_NESTING" == "yes" ]]; then
        warn "Unprivileged LXC: Docker requires nesting enabled on the host (security.nesting=true); the service may not start in the guest."
    fi
    run apt-get "${APT_OPTS[@]}" install \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin
    # B8: pornirea serviciului nu trebuie să aborteze instalarea
    if run systemctl enable --now docker.service; then
        ok "Docker installed."
    else
        warn "Docker is installed but the service did not start; check nesting (LXC) and 'journalctl -u docker'."
    fi

    configure_docker_config
    configure_docker_user
}

# C4: JSON-ul cu setările gestionate de noi (folosit de merge_docker_config)
docker_managed_settings_json() {
    local pool_json="null"
    if [[ -n "$DOCKER_POOL" ]]; then
        pool_json="[{\"base\": \"$DOCKER_POOL\", \"size\": 24}]"
    fi
    local ip_json="null"
    if [[ "$DOCKER_BIND_LOCALHOST" == "yes" ]]; then
        ip_json='"127.0.0.1"'
    fi
    printf '{"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}, "live-restore": true, "no-new-privileges": true, "default-address-pools": %s, "ip": %s}' "$pool_json" "$ip_json"
}

# Îmbină setările gestionate în daemon.json. Cheile existente ale utilizatorului
# câștigă; completăm doar ce lipsește (inclusiv sub-chei în log-opts).
# Ieșire: JSON-ul îmbinat. rc: 0 = schimbat, 2 = deja la zi, 1 = fișier invalid.
merge_docker_config() {
    local file="$1"
    local rc=0
    cmd_python3 - "$file" "$(docker_managed_settings_json)" <<'PY'
import json, sys

file = sys.argv[1]
wanted = json.loads(sys.argv[2])
wanted = {k: v for k, v in wanted.items() if v is not None}

try:
    with open(file) as f:
        current = json.load(f)
except FileNotFoundError:
    current = {}

if not isinstance(current, dict):
    sys.exit(1)

def deep_fill(dst, src):
    changed = False
    for k, v in src.items():
        if k not in dst:
            dst[k] = v
            changed = True
        elif isinstance(v, dict) and isinstance(dst[k], dict):
            changed = deep_fill(dst[k], v) or changed
    return changed

if deep_fill(current, wanted):
    print(json.dumps(current, indent=2, sort_keys=True))
    sys.exit(0)
sys.exit(2)
PY
    rc=$?
    return "$rc"
}

# C4 (D2-D4): daemon.json — merge, backup timestampat, validare JSON,
# restart doar la schimbare efectivă.
configure_docker_config() {
    if [[ "$INSTALL_DOCKER" != "yes" || "$DOCKER_CONFIG" != "yes" ]]; then
        return 0
    fi

    local file="${DS_DOCKER_DAEMON:-/etc/docker/daemon.json}"
    local merged="" rc=0 stamp backup=""

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "Merging /etc/docker/daemon.json: log-opts 10m x 3, live-restore, no-new-privileges${DOCKER_POOL:+, default-address-pools from $DOCKER_POOL}${DOCKER_BIND_LOCALHOST:+, ip=127.0.0.1}; existing user keys are preserved; docker restart only if the file changes."
        return 0
    fi

    run install -d -m 0755 "$(dirname "$file")"

    if [[ -f "$file" ]] && ! cmd_python3 -m json.tool "$file" >/dev/null 2>&1; then
        warn "Existing daemon.json is invalid JSON; not modifying it — fix $file manually."
        return 0
    fi

    merged="$(merge_docker_config "$file")" || rc=$?
    if [[ "$rc" == "1" ]]; then
        warn "Existing daemon.json is not a valid JSON object; not modifying it."
        return 0
    fi
    if [[ "$rc" == "2" ]]; then
        info "daemon.json already has the managed settings; docker is not restarted."
        return 0
    fi

    if [[ -f "$file" ]]; then
        stamp="$(date +%Y%m%d-%H%M%S)"
        backup="$file.bak-$stamp"
        run cp -p "$file" "$backup"
    fi

    printf '%s\n' "$merged" | write_file "$file" 0644

    if ! cmd_python3 -m json.tool "$file" >/dev/null 2>&1; then
        if [[ -n "$backup" && -f "$backup" ]]; then
            run cp -p "$backup" "$file"
            warn "daemon.json written was invalid; restored the backup."
        else
            run rm -f "$file"
            warn "daemon.json written was invalid; deleted the new file."
        fi
        die 1 "JSON validation failed after writing $file."
    fi

    run systemctl restart docker.service
    ok "daemon.json updated (log rotation 10m x 3, live-restore, no-new-privileges); docker restarted."
}

# D4: opțional — adaugă un user existent în grupul docker (echivalent root)
configure_docker_user() {
    if [[ "$INSTALL_DOCKER" != "yes" || -z "$DOCKER_USER" ]]; then
        return 0
    fi

    warn "$DOCKER_USER becomes root-equivalent through the docker group (access to /var/run/docker.sock)."
    run usermod -aG docker "$DOCKER_USER"
    ok "User $DOCKER_USER is in the docker group (relogin required)."
}

install_tailscale() {
    info "Installing Tailscale stable..."
    # F1: subcomanda 'install' lipsa → apt eșua pe mașină reală
    run apt-get "${APT_OPTS[@]}" install tailscale
    if run systemctl enable --now tailscaled.service; then
        ok "Tailscale installed and tailscaled started."
    else
        warn "Tailscale is installed but tailscaled did not start. Check /dev/net/tun and the service log, especially in LXC."
    fi
}

# A3: restaurarea unui drop-in la conținutul anterior (sau ștergerea lui)
restore_ssh_dropin() {
    local path="$1" backup="$2" had="$3"
    if [[ "$had" == "yes" && -n "$backup" && -f "$backup" ]]; then
        cp -p "$backup" "$path"
    else
        rm -f "$path"
    fi
}

# A3: sshd -T reflectă politica ssh-keys-only?
sshd_effective_keys_only() {
    local out
    out="$(cmd_sshd -T 2>/dev/null || true)"
    grep -qiE '^passwordauthentication no$' <<<"$out" || return 1
    grep -qiE '^kbdinteractiveauthentication no$' <<<"$out" || return 1
    grep -qiE '^permitrootlogin (without-password|prohibit-password)$' <<<"$out" || return 1
    return 0
}

configure_ssh() {
    [[ "$MANAGE_SSH" == "yes" ]] || return 0
    local sshd_dir="${DS_SSH_CONFIG_DIR:-/etc/ssh/sshd_config.d}"
    local config_90="$sshd_dir/90-bootstrap-security.conf"
    local config_00="$sshd_dir/00-bootstrap-security.conf"
    local backup90="" backup00="" had90=no had00=no
    local allow_line=""

    if [[ -n "$ALLOW_USERS" ]]; then
        allow_line="AllowUsers ${ALLOW_USERS//,/ }"
    fi

    run mkdir -p "$sshd_dir"
    run install -d -m 0755 /run/sshd

    if [[ "$DRY_RUN" != "yes" ]]; then
        if [[ -f "$config_90" ]]; then
            backup90="$(mktemp)"
            cp -p "$config_90" "$backup90"
            had90=yes
        fi
        if [[ "$SSH_KEYS_ONLY" == "yes" && -f "$config_00" ]]; then
            backup00="$(mktemp)"
            cp -p "$config_00" "$backup00"
            had00=yes
        fi
    fi

    write_file "$config_90" 0644 <<EOF
# Managed by debian-setup.sh
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 5
${allow_line}
EOF

    # A2: drop-in 00- (înaintea lui 50-cloud-init.conf) pentru politica keys-only
    if [[ "$SSH_KEYS_ONLY" == "yes" ]]; then
        write_file "$config_00" 0644 <<'EOF'
# Managed by debian-setup.sh (ssh-keys-only)
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
    fi

    # sshd -t cu rollback pentru ambele drop-in-uri (doar în rularea reală)
    if [[ "$DRY_RUN" != "yes" ]]; then
        if ! cmd_sshd -t; then
            restore_ssh_dropin "$config_90" "$backup90" "$had90"
            if [[ "$SSH_KEYS_ONLY" == "yes" ]]; then
                restore_ssh_dropin "$config_00" "$backup00" "$had00"
            fi
            [[ -z "$backup90" ]] || rm -f "$backup90"
            [[ -z "$backup00" ]] || rm -f "$backup00"
            die 1 "SSH configuration is invalid; changes were rolled back."
        fi
        [[ -z "$backup90" ]] || rm -f "$backup90"

        # A3: valorile EFECTIVE (sshd -T) trebuie să reflecte politica ssh-keys-only
        if [[ "$SSH_KEYS_ONLY" == "yes" ]]; then
            if ! sshd_effective_keys_only; then
                restore_ssh_dropin "$config_00" "$backup00" "$had00"
                [[ -z "$backup00" ]] || rm -f "$backup00"
                die 1 "sshd -T shows values different from the ssh-keys-only policy (passwordauthentication/kbdinteractiveauthentication/permitrootlogin); restored $config_00. Check other drop-ins (e.g. 50-cloud-init.conf)."
            fi
            ok "The ssh-keys-only policy is active and effective (sshd -T)."
            [[ -z "$backup00" ]] || rm -f "$backup00"
        fi
    fi

    run systemctl enable --now ssh.service 2>/dev/null \
        || run systemctl enable --now sshd.service 2>/dev/null \
        || warn "Could not start the SSH service automatically."

    # B6: cu socket-activation (Debian 13 / Ubuntu >= 22.10) reload-ul serviciului
    # nu aplică nimic; se repornește ssh.socket și se verifică portul.
    if [[ "$SSH_SOCKET_ACTIVE" == "yes" ]]; then
        run systemctl restart ssh.socket
        if [[ "$DRY_RUN" != "yes" ]]; then
            verify_ssh_listening
        fi
    else
        run systemctl reload ssh.service 2>/dev/null \
            || run systemctl reload sshd.service 2>/dev/null \
            || true
    fi

    if [[ "$DRY_RUN" != "yes" ]]; then
        ok "SSH configuration is valid."
    fi
}

# Export UFW înainte de reset: status numbered în log + copie /etc/ufw în /var/backups/
backup_ufw_before_reset() {
    local stamp backup_dir
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="/var/backups/ufw-$stamp"

    info "Saving the existing UFW rules before reset..."
    if [[ "$DRY_RUN" == "yes" ]]; then
        run ufw status numbered
    else
        log_write INFO "ufw status numbered (before reset):
$(ufw status numbered 2>/dev/null || true)"
    fi
    run install -d -m 0700 "$backup_dir"
    run cp -a /etc/ufw "$backup_dir/"
    if [[ "$DRY_RUN" != "yes" ]]; then
        ok "UFW backup in $backup_dir."
    fi
}

# B7: asigură IPV6=yes în /etc/default/ufw (idempotent)
set_ufw_ipv6() {
    local file="${DS_UFW_DEFAULT:-/etc/default/ufw}"

    if [[ -r "$file" ]] && grep -q '^IPV6=yes' "$file"; then
        log_write INFO "IPV6=yes already set in $file"
        return 0
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '%s[DRY-RUN]%s setting IPV6=yes in %s\n' "${CYAN}" "${NC}" "$file"
        return 0
    fi

    if [[ -f "$file" ]] && grep -q '^IPV6=' "$file"; then
        run sed -i 's/^IPV6=.*/IPV6=yes/' "$file"
    else
        printf 'IPV6=yes\n' | run tee -a "$file" >/dev/null
    fi
    log_write WRITE "$file (IPV6=yes)"
    ok "IPV6=yes in $file."
}

configure_ufw() {
    local cidr

    if [[ "$SKIP_FIREWALL" == "yes" ]]; then
        warn "Keeping UFW unchanged (explicitly skipped or container restrictions)."
        return 0
    fi

    info "Configuring UFW..."

    if [[ "$RESET_FIREWALL" == "yes" ]]; then
        backup_ufw_before_reset
        run ufw --force reset
    fi

    set_ufw_ipv6

    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw logging low

    # B5: regulile CIDR rămân permanente
    for cidr in "${SSH_CIDRS[@]}"; do
        run ufw allow from "$cidr" to any port "$SSH_PORT" proto tcp comment 'SSH trusted network'
    done

    # B5: reguli pe interfață, adăugate PESTE CIDR-uri, nu în locul lor
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        run ufw allow in on tailscale0 to any port "$SSH_PORT" proto tcp comment 'SSH over tailscale0'
    fi
    if [[ -n "$WIREGUARD_IFACE" ]]; then
        run ufw allow in on "$WIREGUARD_IFACE" to any port "$SSH_PORT" proto tcp comment "SSH over $WIREGUARD_IFACE"
    fi

    # Nu deschidem 80/443. Cloudflare Tunnel face conexiuni outbound.
    run ufw --force enable
    ok "UFW enabled; public ports $SSH_PORT, 80 and 443 are not open globally."
}

configure_fail2ban() {
    if [[ "$INSTALL_FAIL2BAN" != "yes" ]]; then
        return 0
    fi

    if [[ "$SKIP_FIREWALL" == "yes" ]]; then
        warn "Keeping Fail2Ban unchanged: the UFW integration is skipped."
        return 0
    fi

    info "Configuring Fail2Ban for SSH..."
    run install -d -m 0755 /etc/fail2ban/jail.d

    # B3: ignoreip din CIDR-urile SSH + IP-ul sesiunii, dacă e cunoscut
    local ignoreip="127.0.0.1/8 ::1"
    local cidr
    for cidr in "${SSH_CIDRS[@]}"; do
        ignoreip+=" $cidr"
    done
    if [[ -n "$SSH_SOURCE_IP" ]]; then
        ignoreip+=" $SSH_SOURCE_IP"
    fi

    write_file /etc/fail2ban/jail.d/sshd-bootstrap.local 0644 <<EOF
[sshd]
enabled = true
backend = systemd
port = ${SSH_PORT}
banaction = ufw
maxretry = 5
findtime = 10m
bantime = 1h
ignoreip = ${ignoreip}
EOF

    run systemctl enable --now fail2ban.service
    run systemctl restart fail2ban.service

    if [[ "$DRY_RUN" == "yes" ]]; then
        ok "Fail2Ban active for SSH."
    else
        verify_fail2ban_jail
    fi
}

# B2: după pornire, jail-ul sshd trebuie să fie activ
verify_fail2ban_jail() {
    if cmd_fail2ban_client status sshd >/dev/null 2>&1; then
        ok "Fail2Ban active for SSH (sshd jail active)."
    else
        warn "Fail2Ban is running but the sshd jail does not respond; check 'fail2ban-client status sshd' and the log."
    fi
}

selection_is_noop() {
    # Fail2Ban is intentionally absent here: this UFW integration never installs
    # or configures it when SKIP_FIREWALL=yes, regardless of its selected flag.
    [[ "$MANAGE_SSH" == "no" && "$SKIP_FIREWALL" == "yes" && "$SKIP_UPGRADE" == "yes"
        && "$INSTALL_DOCKER" == "no" && "$INSTALL_TAILSCALE" == "no"
        && "$INSTALL_AUTO_UPDATES" == "no" && -z "$CREATE_USER" ]]
}

bootstrap() {
    if selection_is_noop; then
        info "No changes selected; leaving the system without APT operations."
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    if [[ "$WIZARD" == "yes" || "$MANAGE_SSH" == "no" || "$SKIP_FIREWALL" == "yes" ]]; then
        # Do not ask needrestart to restart unrelated/preserved services automatically.
        export NEEDRESTART_MODE=l
    fi

    info "Updating the APT index..."
    run apt-get "${APT_OPTS[@]}" update

    if [[ "$SKIP_UPGRADE" != "yes" ]]; then
        info "Upgrading Debian (full-upgrade)..."
        run apt-get "${APT_OPTS[@]}" full-upgrade
        ok "Debian upgraded."
    fi

    info "Installing the base packages..."
    local base_packages=(
        ca-certificates
        curl
        gnupg
        iproute2
        python3-minimal
        sudo
    )
    [[ "$MANAGE_SSH" != "yes" ]] || base_packages+=(openssh-server)
    [[ "$SKIP_FIREWALL" == "yes" ]] || base_packages+=(ufw)
    if [[ "$INSTALL_FAIL2BAN" == "yes" && "$SKIP_FIREWALL" != "yes" ]]; then
        base_packages+=(python3-systemd)
    fi
    if [[ "$INSTALL_AUTO_UPDATES" == "yes" ]]; then
        base_packages+=(unattended-upgrades)
    fi
    run apt-get "${APT_OPTS[@]}" install "${base_packages[@]}"
    ok "Base packages installed."

    configure_created_user

    check_current_session_allowed

    configure_auto_updates

    if [[ "$INSTALL_DOCKER" == "yes" ]]; then
        remove_docker_conflicts
        detect_lxc_docker
        setup_docker_repository
    fi
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        setup_tailscale_repository
    fi

    if [[ "$INSTALL_DOCKER" == "yes" || "$INSTALL_TAILSCALE" == "yes" ]]; then
        info "Updating the APT index for the official repositories..."
        run apt-get "${APT_OPTS[@]}" update
    fi

    if [[ "$INSTALL_DOCKER" == "yes" ]]; then
        install_docker
    fi

    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        install_tailscale
    fi

    if [[ "$INSTALL_FAIL2BAN" == "yes" && "$SKIP_FIREWALL" != "yes" ]]; then
        info "Installing Fail2Ban..."
        run apt-get "${APT_OPTS[@]}" install fail2ban
    fi

    configure_ssh
    configure_ufw
    configure_fail2ban

    # U-verificare fail-loud: originea de securitate trebuie să apară
    if [[ "$INSTALL_AUTO_UPDATES" == "yes" ]]; then
        if [[ "$DRY_RUN" == "yes" ]]; then
            info "At the end: checking that 'unattended-upgrade --dry-run --debug' lists ${CODENAME}-security."
        else
            verify_unattended_origins
        fi
    fi
}

# ------------------------------------------------------------
# Verificare și mesaj final
# ------------------------------------------------------------

verify_installation() {
    echo
    echo "============================================================"
    echo " VERIFICATION"
    echo "============================================================"
    echo

    if [[ "$INSTALL_DOCKER" == "yes" ]]; then
        echo "--- Docker ---"
        docker --version || true
        docker compose version || true
    fi

    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        echo
        echo "--- Tailscale ---"
        tailscale version || true
        systemctl is-active tailscaled.service || true
    fi

    if [[ "$SKIP_FIREWALL" != "yes" ]]; then
        echo
        echo "--- UFW ---"
        ufw status verbose || true
    fi

    if [[ "$INSTALL_AUTO_UPDATES" == "yes" ]]; then
        echo
        echo "--- Automatic security updates ---"
        systemctl is-enabled apt-daily.timer 2>/dev/null || true
        systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true
        systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-pager 2>/dev/null || true
    fi

    if [[ "$INSTALL_FAIL2BAN" == "yes" && "$SKIP_FIREWALL" != "yes" ]]; then
        echo
        echo "--- Fail2Ban ---"
        fail2ban-client status sshd 2>/dev/null || true
    fi

    echo
    echo "--- Listening ports ---"
    ss -lntup || true
}

# starea unui serviciu systemd (în dry-run: doar „planificat”)
svc_status() {
    local unit="$1"
    if [[ "$DRY_RUN" == "yes" ]]; then
        printf 'planned'
        return 0
    fi
    if cmd_systemctl is-active --quiet "$unit" 2>/dev/null; then
        printf 'active'
    else
        printf 'INACTIVE'
    fi
}

final_notes() {
    echo
    echo "============================================================"
    echo " DONE — SUMMARY"
    echo "============================================================"
    echo
    echo "Mode:           ${MODE:-?} (distro ${DISTRO:-?} / ${CODENAME:-?})"
    echo "SSH config:     $([[ "$MANAGE_SSH" == "yes" ]] && echo managed || echo KEPT)"
    if [[ "$SKIP_FIREWALL" == "yes" ]]; then
        echo "SSH firewall:   KEPT; existing access was not reconfigured"
    else
        echo "SSH:            port ${SSH_PORT}, allowed from: ${SSH_CIDRS[*]}"
    fi
    if [[ -n "$WIREGUARD_IFACE" ]]; then
        echo "                + rule on interface ${WIREGUARD_IFACE}"
    fi
    echo "Services:"
    if [[ "$INSTALL_DOCKER" == "yes" ]]; then
        echo "  docker:       installed; service: $(svc_status docker.service)"
    else
        echo "  docker:       skipped"
    fi
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        echo "  tailscale:    installed; tailscaled: $(svc_status tailscaled.service)"
    else
        echo "  tailscale:    skipped"
    fi
    if [[ "$SKIP_FIREWALL" == "yes" ]]; then
        echo "  ufw:          KEPT (explicitly skipped / container restrictions)"
    else
        echo "  ufw:          $(svc_status ufw.service)"
    fi
    if [[ "$INSTALL_FAIL2BAN" == "yes" && "$SKIP_FIREWALL" != "yes" ]]; then
        echo "  fail2ban:     $(svc_status fail2ban.service)"
    else
        echo "  fail2ban:     skipped"
    fi
    echo
    echo "Next steps:"
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        echo "  - sudo tailscale up   (Tailscale authentication is manual)"
    fi
    if [[ -f /var/run/reboot-required ]]; then
        echo "  - REBOOT REQUIRED: /var/run/reboot-required exists."
    else
        echo "  - check whether a reboot is needed after updates (/var/run/reboot-required)."
    fi
    echo
    echo "Warnings:"

    if [[ "$INSTALL_DOCKER" == "yes" ]]; then
        warn "For Cloudflare Tunnel, avoid ports: in Docker Compose; use the same Docker network as the application."
        warn "Docker can bypass UFW rules for published ports; do not publish ports on 0.0.0.0 without an explicit rule."
        warn "No automatic DOCKER-USER rules: for per-container filtering, add them manually (e.g. iptables -I DOCKER-USER -i eth0 -p tcp --dport 5432 -j DROP)."
    fi

    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        warn "Tailscale is not authenticated automatically. Run: sudo tailscale up"
    fi

    if [[ "$RESET_FIREWALL" != "yes" ]]; then
        warn "Existing UFW rules were not deleted. For a fully clean policy, use --reset-firewall on a server prepared for bootstrap."
    fi
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {
    trap on_error ERR

    parse_args "$@"

    if [[ "$PRINT_VERSION" == "yes" ]]; then
        printf 'debian-setup.sh %s\n' "$VERSION"
        exit 0
    fi

    if [[ "$PRINT_CONFIG" == "yes" ]]; then
        print_config
        exit 0
    fi

    guard_test_overrides
    validate_selection

    if [[ "$INSPECT" == "yes" ]]; then
        detect_distro
        detect_ssh_port
        detect_ssh_source
        DETECTED_LAN_CIDR="$(detect_lan_cidr || true)"
        print_inventory
        return 0
    fi

    open_log
    log_write INFO "Start debian-setup.sh ${VERSION} (pid $$)"

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "--dry-run mode: only the plan is shown; nothing is changed."
    fi

    preflight
    print_detection
    print_plan_summary

    if [[ "$DRY_RUN" != "yes" && "$NONINTERACTIVE" != "yes" ]]; then
        local apply_default=y
        [[ "$WIZARD" != "yes" ]] || apply_default=n
        if ! yes_no "Apply this configuration?" "$apply_default"; then
            log_write INFO "Cancelled by the user before any change"
            exit 0
        fi
    fi

    bootstrap

    if [[ "$DRY_RUN" != "yes" ]]; then
        verify_installation
    fi

    final_notes
    log_write INFO "Completed successfully"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
