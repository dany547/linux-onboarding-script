#!/usr/bin/env bash
set -Eeuo pipefail

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

VERSION="2.6.0"
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
        warn "Nu pot scrie logul în $LOG_FILE; continu fără log în fișier."
    fi
}

# trap ERR: raportează linia și comanda care a eșuat, apoi exit 1.
on_error() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-?}"
    local cmd="${BASH_COMMAND:-necunoscută}"

    log_write ERROR "Eșec la linia ${line_no}: ${cmd} (cod ${exit_code})"
    printf '%s[ERROR]%s Eroare la linia %s: %s (cod %s)%s\n' \
        "${RED}" "${NC}" "${line_no}" "${cmd}" "${exit_code}" \
        "$(if [[ -n "$LOG_FD" ]]; then printf ', vezi %s' "$LOG_FILE"; fi)" >&2
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
        printf '%s[DRY-RUN]%s scriu %s (mod %s):\n' "${CYAN}" "${NC}" "$path" "$mode"
        sed 's/^/    | /'
        return 0
    fi

    log_write WRITE "$path (mod $mode)"
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
  sudo bash debian-setup.sh [opțiuni]

Opțiuni:
  -y, --yes                  Non-interactiv; necesită --mode
  --mode lan|vps             LAN = SSH din LAN/VPN; VPS = SSH doar din VPN
  --lan-cidr CIDR            Subnetul LAN permis pentru SSH
  --wireguard-cidr CIDR      Subnetul sau sursa WireGuard permisă pentru SSH
  --wireguard-iface IFACE    Regulă UFW suplimentară 'in on IFACE' pentru SSH
                             (peste regulile CIDR, nu în locul lor)
  --config FILE              Încarcă setări din FILE (linii KEY=value, fără shell;
                             cheile permise sunt cele listate de --print-config;
                             argumentele din linia de comandă au prioritate)
  --print-config             Afișează configurația efectivă (KEY=value) și iese
  --dry-run                  Afișează planul complet (comenzi, fișiere, reguli UFW)
                             fără nicio mutație; merge și ca non-root cu DS_ROOT_OK=1
  --no-docker                Nu instala Docker Engine + Compose plugin
  --no-tailscale             Nu instala Tailscale
  --no-fail2ban              Nu instala/configura Fail2Ban
  --no-auto-updates          Nu activa unattended-upgrades pentru update-uri de securitate
  --reset-firewall           Resetează regulile UFW existente înainte de configurare
  --allow-current-ssh        Permite explicit IP-ul sesiunii SSH curente
  --skip-upgrade             Nu executa apt full-upgrade
  --docker-pool CIDR         Pool implicit de rețele Docker (default-address-pools,
                             subreți de /24; ex. 10.200.0.0/16)
  --docker-bind-localhost    Publicările de porturi se leagă implicit la 127.0.0.1
                             (cheia "ip" din daemon.json). Fără ea Docker leagă pe
                             0.0.0.0 și poate ocoli regulile UFW!
  --no-docker-config         Nu atinge /etc/docker/daemon.json
  --docker-user USER         Adaugă USER în grupul docker — echivalent root!
  --create-user NAME         Creează (sau refolosește) un user cu shell bash, în grupul
                             sudo, parolă blocată; instalare idempotentă
  --no-sudo-nopasswd         Cu --create-user: nu scrie sudoers NOPASSWD și nu blochează
                             parola (seteaz-o manual cu passwd)
  --ssh-key-file CALE        Instalează cheia publică din CALE pentru --create-user
                             (sau pentru root). PREFERAT: cheia nu apare în lista
                             de procese, spre deosebire de --ssh-key
  --ssh-key CHEIE            Cheie publică SSH (ssh-ed25519 AAAA... comment); vizibilă
                             în process list — folosește --ssh-key-file când poți
  --ssh-keys-only            Politică strictă: autentificare doar cu chei (drop-in
                             00-bootstrap-security.conf + verificare sshd -T);
                             precondiție: minim un cont privilegiat are cheie validă
  --allow-users U1,U2        AllowUsers în sshd; trebuie să includă userul curent
                             sau userul din --create-user, altfel exit 4
  --auto-reboot HH:MM        Permite reboot-ul automat al serverului la ora dată
  --mail ADRESĂ              Trimite rapoartele unattended la ADRESĂ (necesită MTA)
  --update-third-party       Actualizări automate și pentru repo-urile Docker/Tailscale
                             (implicit doar originile oficiale de securitate)
  --strict                   Dacă verificarea unattended-upgrades eșuează la final →
                             exit 1 (implicit: doar warn puternic)
  --version                  Afișează versiunea și iese
  -h, --help

Comportament de rețea:
  LAN:
    SSH este permis din --lan-cidr, --wireguard-cidr și Tailscale.
  VPS:
    SSH public nu este permis; SSH este permis doar din WireGuard/Tailscale.

Tailscale folosește canalul oficial stable. Autentificarea rămâne manuală:
  sudo tailscale up

Cloudflare Tunnel nu are nevoie de porturile 80/443 deschise.

Coduri de ieșire: 0 ok, 1 eroare, 2 argumente invalide,
3 precondiție/OS nesuportat, 4 risc de lockout.
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
        read -r -p "$prompt [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -r -p "$prompt [y/N]: " answer
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
        die "Fără TTY. Rulează interactiv sau cu -y și opțiunile necesare."
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
        die 4 "Sesiune SSH detectată (sshd în lanțul de procese), dar IP-ul sursă nu poate fi determinat (tipic sub sudo/su). Rulează din nou cu DS_SSH_SOURCE=<IP> sau folosește --allow-current-ssh."
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
        ok "sshd ascultă pe portul $SSH_PORT."
    else
        warn "sshd nu ascultă (încă) pe portul $SSH_PORT; verifică ssh.socket/serviciul sshd."
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
    echo "Sistem:       ${PRETTY_NAME:-Debian/Ubuntu}"
    echo "Distro:       ${DISTRO:-?}"
    echo "Codename:     ${CODENAME:-necunoscut}"
    echo "Mod rețea:    ${MODE:-nesetat}"
    echo "Port SSH:     $SSH_PORT"
    echo "LAN CIDR:     ${LAN_CIDR:-nesetat}"
    echo "WireGuard:    ${WIREGUARD_CIDR:-nesetat}${WIREGUARD_IFACE:+ (interfață $WIREGUARD_IFACE)}"
    echo "Tailscale:    $([[ "$INSTALL_TAILSCALE" == "yes" ]] && echo "$TAILSCALE_CIDR + $TAILSCALE_IPV6_CIDR" || echo NU)"
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
    echo " CONFIGURAȚIE"
    echo "============================================================"
    echo
    echo "Docker + Compose:       $INSTALL_DOCKER"
    echo "Tailscale:              $INSTALL_TAILSCALE"
    echo "Fail2Ban:               $INSTALL_FAIL2BAN"
    echo "Auto-updates securitate: $INSTALL_AUTO_UPDATES"
    echo "Firewall UFW:            $([[ "$SKIP_FIREWALL" == "yes" ]] && echo 'sarit în LXC neprivilegiat' || echo DA)"
    echo "Reset reguli UFW:        $RESET_FIREWALL"
    echo "Upgrade Debian:          $([[ "$SKIP_UPGRADE" == "yes" ]] && echo NU || echo DA)"
    echo "Port SSH:                $SSH_PORT"
    echo "SSH permis din:          ${SSH_CIDRS[*]}"
    echo "Sesiune SSH detectată:   $SSH_SESSION_IS_SSH"
    if [[ -n "$WIREGUARD_IFACE" ]]; then
        echo "Interfață WireGuard:     $WIREGUARD_IFACE"
    fi
    if [[ -n "$SSH_SOURCE_IP" ]]; then
        echo "SSH curent din:          $SSH_SOURCE_IP"
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

    [[ -r "$os_file" ]] || die 3 "Nu pot citi $os_file."

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
        warn "Derivat Debian detectat (ID=${id}, ID_LIKE=${id_like}); este tratat ca Debian. Combinatia nu este testată oficial."
    elif [[ " $id_like " == *" ubuntu "* || " $id_like " == *" debian "* ]]; then
        DISTRO="ubuntu"
        warn "Derivat Ubuntu detectat (ID=${id}, ID_LIKE=${id_like}); este tratat ca Ubuntu. Combinatia nu este testată oficial."
    else
        die 3 "Distribuție nesuportată: ${PRETTY_NAME:-${id:-necunoscută}}. Sunt suportate Debian 12/13, Ubuntu 22.04/24.04 și derivatele lor."
    fi

    if [[ "$DISTRO" == "debian" ]]; then
        if [[ "$id" == "debian" ]]; then
            major="${version_id%%.*}"
            if [[ "$major" != "12" && "$major" != "13" ]]; then
                die 3 "Sunt suportate Debian 12 și 13; detectat: ${PRETTY_NAME:-necunoscut}."
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
                die 3 "Sunt suportate Ubuntu 22.04 și 24.04; detectat: ${PRETTY_NAME:-necunoscut}."
            fi
        fi
        CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    fi

    [[ -n "$CODENAME" ]] \
        || die 3 "Nu pot determina codename-ul distribuției (${PRETTY_NAME:-${id:-necunoscută}})."

    # R3: codename cunoscut? Primar necunoscut → die 3; derivat necunoscut → warn.
    local known_codename=no c
    for c in bookworm trixie jammy noble; do
        if [[ "$CODENAME" == "$c" ]]; then
            known_codename=yes
        fi
    done
    if [[ "$known_codename" != "yes" ]]; then
        if [[ "$id" == "debian" || "$id" == "ubuntu" ]]; then
            die 3 "Codename necunoscut pentru ${id}: '${CODENAME}'. Sunt suportate: bookworm, trixie, jammy, noble."
        fi
        warn "Derivat ${id}: codename '${CODENAME}' nu e în lista cunoscută (bookworm/trixie/jammy/noble); repo-urile oficial e posibil să nu aibă suite pentru el."
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
            die 2 "DS_TAILSCALE_OLD_LIST trebuie să fie sub /etc/apt/sources.list.d/."
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
        die 2 "Variabile de test DS_* detectate la rulare reală (${found}). Șterge-le din mediu sau folosește --dry-run (în medii de test: DS_TEST=1)."
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
        die 2 "Nu pot citi fișierul de configurare: $file"
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # ignoră liniile goale și comentariile
        if [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        if [[ "$line" != *"="* ]]; then
            die 2 "Linie invalidă în $file (format așteptat KEY=value): $line"
        fi

        raw_key="${line%%=*}"
        value="${line#*=}"
        key="${raw_key//[[:space:]]/}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        case "$key" in
            MODE)
                [[ "$value" == "lan" || "$value" == "vps" ]] \
                    || die 2 "MODE trebuie să fie lan sau vps (în $file)."
                ;;
            LAN_CIDR|WIREGUARD_CIDR|TAILSCALE_CIDR|TAILSCALE_IPV6_CIDR)
                valid_cidr "$value" || die 2 "$key invalid în $file: $value"
                ;;
            WIREGUARD_IFACE)
                [[ "$value" =~ ^[A-Za-z0-9._-]{1,15}$ ]] \
                    || die 2 "WIREGUARD_IFACE invalid în $file: $value"
                ;;
            DOCKER_POOL)
                valid_cidr "$value" || die 2 "DOCKER_POOL invalid în $file: $value"
                ;;
            DOCKER_CONFIG|DOCKER_BIND_LOCALHOST)
                [[ "$value" == "yes" || "$value" == "no" ]] \
                    || die 2 "$key trebuie să fie yes sau no (în $file)."
                ;;
            DOCKER_USER)
                [[ -n "$value" ]] || die 2 "DOCKER_USER nu poate fi gol (în $file)."
                ;;
            CREATE_USER)
                [[ "$value" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
                    || die 2 "CREATE_USER invalid în $file: $value"
                ;;
            SSH_KEY_FILE)
                [[ -n "$value" ]] || die 2 "SSH_KEY_FILE nu poate fi gol (în $file)."
                ;;
            ALLOW_USERS)
                local u
                for u in ${value//,/ }; do
                    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
                        || die 2 "ALLOW_USERS invalid în $file: $u"
                done
                ;;
            AUTO_REBOOT)
                [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
                    || die 2 "AUTO_REBOOT invalid în $file (format HH:MM): $value"
                ;;
            MAIL_ADDR)
                [[ "$value" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] \
                    || die 2 "MAIL_ADDR invalid în $file: $value"
                ;;
            SSH_KEYS_ONLY|UPDATE_THIRD_PARTY|SUDO_NOPASSWD)
                [[ "$value" == "yes" || "$value" == "no" ]] \
                    || die 2 "$key trebuie să fie yes sau no (în $file)."
                ;;
            INSTALL_DOCKER|INSTALL_TAILSCALE|INSTALL_FAIL2BAN|INSTALL_AUTO_UPDATES|RESET_FIREWALL|SKIP_UPGRADE|ALLOW_CURRENT_SSH)
                [[ "$value" == "yes" || "$value" == "no" ]] \
                    || die 2 "$key trebuie să fie yes sau no (în $file)."
                ;;
            *)
                die 2 "Cheie nepermisă în $file: $key"
                ;;
        esac

        printf -v "$key" '%s' "$value"
    done <"$file"

    log_write INFO "Configurație încărcată din $file"
}

# Parsare centralizată: --config se procesează într-o primă trecere,
# ca orice flag din linia de comandă să suprascrie valorile din fișier.
parse_args() {
    local args=("$@")
    local i

    for ((i = 0; i < ${#args[@]}; i++)); do
        if [[ "${args[i]}" == "--config" ]]; then
            if (( i + 1 >= ${#args[@]} )); then
                die 2 "Lipsește valoarea pentru --config."
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
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --mode."
                MODE="${2,,}"
                shift 2
                ;;
            --lan-cidr)
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --lan-cidr."
                LAN_CIDR="$2"
                shift 2
                ;;
            --wireguard-cidr)
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --wireguard-cidr."
                WIREGUARD_CIDR="$2"
                shift 2
                ;;
            --wireguard-iface)
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --wireguard-iface."
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
            --no-docker)
                INSTALL_DOCKER=no
                shift
                ;;
            --no-tailscale)
                INSTALL_TAILSCALE=no
                shift
                ;;
            --no-fail2ban)
                INSTALL_FAIL2BAN=no
                shift
                ;;
            --no-auto-updates)
                INSTALL_AUTO_UPDATES=no
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
                shift
                ;;
            --docker-pool)
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --docker-pool."
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
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --docker-user."
                DOCKER_USER="$2"
                shift 2
                ;;
            --create-user)
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --create-user."
                CREATE_USER="$2"
                shift 2
                ;;
            --ssh-key-file)
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --ssh-key-file."
                SSH_KEY_FILE="$2"
                shift 2
                ;;
            --ssh-key)
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --ssh-key."
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
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --allow-users."
                ALLOW_USERS="$2"
                shift 2
                ;;
            --auto-reboot)
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --auto-reboot."
                AUTO_REBOOT="$2"
                shift 2
                ;;
            --mail)
                [[ $# -ge 2 ]] || die 2 "Lipsește valoarea pentru --mail."
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
                die 2 "Opțiune necunoscută: $1 (vezi --help)"
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
        warn "Rulez ca non-root în --dry-run (DS_ROOT_OK=1); nu se execută nicio mutație."
        return 0
    fi
    die 3 "Rulează scriptul cu sudo sau ca root."
}

check_proxmox() {
    if command -v pveversion >/dev/null 2>&1; then
        die 3 "Proxmox VE detectat (pveversion). Acest script nu trebuie rulat pe hostul Proxmox; folosește-l în VM sau LXC."
    fi
}

resolve_mode() {
    if [[ -z "$MODE" ]]; then
        if [[ "$DRY_RUN" == "yes" ]]; then
            MODE=lan
            info "DRY-RUN fără --mode: folosesc implicit lan (schimbă cu --mode)."
        elif [[ "$NONINTERACTIVE" == "yes" ]]; then
            die "În modul non-interactiv trebuie să specifici --mode lan sau --mode vps."
        else
            echo "Unde rulează această mașină?"
            echo "  1) LAN — SSH din rețeaua locală și VPN"
            echo "  2) VPS — SSH doar din VPN"
            read -r -p "Alege [1]: " mode_answer
            mode_answer="${mode_answer:-1}"
            case "$mode_answer" in
                1) MODE=lan ;;
                2) MODE=vps ;;
                *) die "Mod invalid: $mode_answer" ;;
            esac
        fi
    fi

    [[ "$MODE" == "lan" || "$MODE" == "vps" ]] \
        || die 2 "--mode trebuie să fie lan sau vps."
}

resolve_lan_cidr() {
    if [[ -z "$LAN_CIDR" && "$MODE" == "lan" ]]; then
        if [[ "$DRY_RUN" == "yes" || "$NONINTERACTIVE" == "yes" ]]; then
            LAN_CIDR="$DETECTED_LAN_CIDR"
        else
            read -r -p "CIDR LAN [${DETECTED_LAN_CIDR:-ex. 192.168.1.0/24}]: " LAN_CIDR
            LAN_CIDR="${LAN_CIDR:-$DETECTED_LAN_CIDR}"
        fi
    fi

    if [[ -n "$LAN_CIDR" ]]; then
        valid_cidr "$LAN_CIDR" || die "LAN CIDR invalid: $LAN_CIDR"
    fi
}

resolve_wireguard_cidr() {
    if [[ -n "$WIREGUARD_CIDR" ]]; then
        valid_cidr "$WIREGUARD_CIDR" || die "WireGuard CIDR invalid: $WIREGUARD_CIDR"
    elif [[ "$DRY_RUN" != "yes" && "$NONINTERACTIVE" != "yes" ]]; then
        if yes_no "Permitești SSH din WireGuard?" y; then
            read -r -p "Subnetul WireGuard sau sursa văzută de server (ex. 10.8.0.0/24): " WIREGUARD_CIDR
            [[ -z "$WIREGUARD_CIDR" ]] || valid_cidr "$WIREGUARD_CIDR" \
                || die "WireGuard CIDR invalid: $WIREGUARD_CIDR"
        fi
    fi

    # B5: interfață WireGuard pentru reguli UFW 'in on <iface>'
    if [[ -n "$WIREGUARD_IFACE" ]]; then
        [[ "$WIREGUARD_IFACE" =~ ^[A-Za-z0-9._-]{1,15}$ ]] \
            || die 2 "Nume interfață WireGuard invalid: $WIREGUARD_IFACE"
    fi
}

resolve_feature_flags() {
    # În --dry-run păstrăm valorile implicite (da pentru toate componentele).
    if [[ "$DRY_RUN" == "yes" || "$NONINTERACTIVE" == "yes" ]]; then
        return 0
    fi

    yes_no "Instalez Docker Engine și Docker Compose plugin?" y \
        && INSTALL_DOCKER=yes || INSTALL_DOCKER=no
    yes_no "Instalez Tailscale din repository-ul oficial stable?" y \
        && INSTALL_TAILSCALE=yes || INSTALL_TAILSCALE=no
    yes_no "Instalez și configurez Fail2Ban pentru SSH?" y \
        && INSTALL_FAIL2BAN=yes || INSTALL_FAIL2BAN=no
    yes_no "Activez actualizările automate de securitate?" y \
        && INSTALL_AUTO_UPDATES=yes || INSTALL_AUTO_UPDATES=no
}

# C4: validare timpurie pentru flag-urile Docker
resolve_docker_flags() {
    if [[ -n "$DOCKER_POOL" ]]; then
        valid_cidr "$DOCKER_POOL" || die 2 "Docker pool CIDR invalid: $DOCKER_POOL"
    fi
    if [[ -n "$DOCKER_USER" ]] && ! cmd_getent passwd "$DOCKER_USER" >/dev/null 2>&1; then
        die 2 "Utilizatorul '$DOCKER_USER' nu există; creează-l înainte sau omite --docker-user."
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
        warn "Conexiuni SSH active din surse neacoperite de CIDR-urile permise: ${UNCOVERED_PEERS}— verifică --lan-cidr/--wireguard-cidr; la rularea reală se cere decizie explicită (--allow-current-ssh sau confirmare)."
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
        die 2 "Nume de utilizator invalid: $CREATE_USER"
    fi

    if [[ -n "$SSH_KEY_FILE" && -n "$SSH_KEY" ]]; then
        die 2 "Folosește doar una: --ssh-key-file sau --ssh-key."
    fi

    if [[ -n "$SSH_KEY_FILE" ]]; then
        if [[ ! -r "$SSH_KEY_FILE" ]]; then
            die 2 "Nu pot citi fișierul de cheie: $SSH_KEY_FILE"
        fi
        if ! cmd_ssh_keygen -lf "$SSH_KEY_FILE" >/dev/null 2>&1; then
            die 2 "Fișierul $SSH_KEY_FILE nu conține o cheie publică SSH validă."
        fi
    fi

    if [[ -n "$SSH_KEY" ]] && ! validate_ssh_public_key "$SSH_KEY"; then
        die 2 "Cheia SSH dată prin --ssh-key nu este validă."
    fi

    if [[ -n "$ALLOW_USERS" ]]; then
        local found=no cur
        for u in ${ALLOW_USERS//,/ }; do
            if [[ ! "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
                die 2 "Utilizator invalid în --allow-users: '$u'"
            fi
            cur="$(current_admin_user)"
            if [[ "$u" == "$cur" || "$u" == "$CREATE_USER" ]]; then
                found=yes
            fi
        done
        if [[ "$found" != "yes" ]]; then
            die 4 "--allow-users nu îl include pe utilizatorul curent ($cur) și nici pe userul din --create-user; te-ai bloca de la SSH. Adaugă-l în listă."
        fi
    fi

    if [[ -n "$AUTO_REBOOT" && ! "$AUTO_REBOOT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        die 2 "Ora invalidă pentru --auto-reboot (format HH:MM): $AUTO_REBOOT"
    fi

    if [[ -n "$MAIL_ADDR" && ! "$MAIL_ADDR" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]]; then
        die 2 "Adresă de mail invalidă: $MAIL_ADDR"
    fi

    # U2: fără MTA, rapoartele pe e-mail nu pot pleca
    if [[ -n "$MAIL_ADDR" ]] && ! command -v sendmail >/dev/null 2>&1 && ! command -v mail >/dev/null 2>&1; then
        warn "Nu găsesc un MTA (sendmail/mail): rapoartele către $MAIL_ADDR nu vor pleca. Instalează mailutils/postfix."
    fi

    # A2/F3: precondiție hard pentru --ssh-keys-only — cine rămâne cu login capabil?
    if [[ "$SSH_KEYS_ONLY" == "yes" ]]; then
        local capable="" cur_admin
        capable="$(ssh_login_capable_users || true)"
        if [[ -z "$capable" ]]; then
            die 4 "Precondiția --ssh-keys-only nu este îndeplinită: niciun cont privilegiat (root/sudo) nu are o cheie SSH validă în authorized_keys. Instalează una cu --create-user + --ssh-key-file sau adaugă manual o cheie pentru root, apoi reia."
        fi
        if [[ "$SSH_SESSION_IS_SSH" == "yes" ]]; then
            cur_admin="$(current_admin_user)"
            if ! grep -qx -- "$cur_admin" <<<"$capable"; then
                die 4 "--ssh-keys-only: contul curent '$cur_admin' nu va mai putea face login (fără cheie validă${ALLOW_USERS:+ / exclus de --allow-users}). Adaugă-i o cheie sau include-l în --allow-users, altfel te blochezi."
            fi
        else
            info "Consolă: --ssh-keys-only activează login doar pe chei; asigură-te că ai acces alternativ."
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
        die 4 "Nu există nicio rețea permisă pentru SSH. Configurează WireGuard/Tailscale sau --lan-cidr."
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
            warn "LXC neprivilegiat detectat: UFW/Fail2Ban nu vor fi activate în guest."
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

    resolve_mode
    resolve_lan_cidr
    resolve_wireguard_cidr
    resolve_feature_flags
    resolve_docker_flags
    resolve_ssh_hardening
    build_ssh_cidrs
    warn_uncovered_established
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
        ok "unattended-upgrades folosește originea de securitate a distribuției (${CODENAME}-security)."
        return 0
    fi

    if [[ "$STRICT" == "yes" ]]; then
        die 1 "Verificarea unattended-upgrades a eșuat: originea '${CODENAME}-security' nu apare în 'unattended-upgrade --dry-run --debug'. Actualizările automate de securitate NU funcționează. (--strict)"
    fi
    warn "VERIFICARE UNATTENDED: originea '${CODENAME}-security' nu apare în 'unattended-upgrade --dry-run --debug'. Actualizările automate de securitate s-ar putea să NU funcționeze; verifică manual. (folosește --strict pentru exit 1)"
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
            log_write INFO "Permit acces SSH pentru ${cand} (--allow-current-ssh)"
        done
        return 0
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
        warn "Sesiuni neacoperite de regulile propuse (${uncovered}); la rularea reală se cere confirmare explicită sau --allow-current-ssh."
        return 0
    fi

    if [[ "$NONINTERACTIVE" == "yes" ]]; then
        die 4 "Sesiuni SSH neacoperite de regulile propuse: ${uncovered}. Folosește --allow-current-ssh, corectează --lan-cidr/--wireguard-cidr sau setează DS_SSH_SOURCE=IP."
    fi

    warn "Sesiuni SSH neacoperite de regulile propuse: ${uncovered}."
    if yes_no "Confirmi că aceste sesiuni pierd accesul SSH și ai acces alternativ (consolă/Tailscale/WireGuard)?" n; then
        log_write INFO "Sesiuni SSH neacoperite confirmate explicit de utilizator"
        return 0
    fi
    die 4 "Nu activez firewall-ul fără acces SSH confirmat. Folosește --allow-current-ssh, corectează CIDR-urile sau setează DS_SSH_SOURCE=IP."
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

    info "Configurez utilizatorul $CREATE_USER..."

    if ! cmd_getent passwd "$CREATE_USER" >/dev/null 2>&1; then
        run useradd -m -s /bin/bash "$CREATE_USER"
        created_now=yes
        ok "Utilizatorul $CREATE_USER a fost creat (shell bash)."
    else
        info "Utilizatorul $CREATE_USER există deja; îl reutilizez."
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
            ok "Cheia SSH a fost instalată pentru $target_user."
        else
            info "Cheia este deja în authorized_keys pentru $target_user; nu duplic."
        fi
        run chown "$target_user:$target_user" "$home/.ssh"
        run chmod 0700 "$home/.ssh"
        key_installed=yes
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
        if [[ "$SUDO_NOPASSWD" == "yes" ]]; then
            warn "--no-sudo-nopasswd: nu scriu sudoers și nu blochez parola; seteaz-o manual cu passwd."
        else
            info "Scriu sudoers NOPASSWD pentru $CREATE_USER (validat cu visudo) și blochez parola."
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
        warn "--no-sudo-nopasswd: nu scriu sudoers și nu blochez parola; seteaz-o manual cu 'passwd $CREATE_USER'."
    elif [[ "$created_now" != "yes" ]] && ! user_password_locked "$CREATE_USER"; then
        warn "$CREATE_USER există cu parolă activă: nu blochez parola și nu acord NOPASSWD (folosește contul cum e sau gestionează-l manual)."
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
                die 1 "Validarea sudoers a eșuat (visudo -cf); nu instalez $sudoers_file."
            fi
            run install -d -m 0755 "$sudoers_dir"
            run install -m 0440 "$tmp" "$sudoers_file"
            rm -f "$tmp"
            run passwd -l "$CREATE_USER"
            ok "$CREATE_USER: sudo NOPASSWD (sudoers validat) + parolă blocată."
        else
            warn "$CREATE_USER: fără cheie validă instalată — nu blochez parola (risc de lockout); instalează o cheie sau seteaz-o manual."
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

    info "Configurez actualizările automate de securitate..."

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
    // ESM (Ubuntu Pro): se activează manual cu ubuntu-advantage; neactivat e ignorat:
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
# Actualizări automate limitate la originile de securitate ale distribuției.
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
        || warn "Nu am putut activa apt-daily.timer."
    run systemctl enable --now apt-daily-upgrade.timer 2>/dev/null \
        || warn "Nu am putut activa apt-daily-upgrade.timer."
    ok "Actualizările automate de securitate sunt activate."
}

# B4: cheia Docker trebuie să aibă exact fingerprintul pinuit; mismatch → șterge + die.
verify_docker_key_fingerprint() {
    local keyfile="$1"
    local out

    out="$(cmd_gpg --show-keys --with-colons "$keyfile" 2>/dev/null || true)"
    if ! grep -q "$DOCKER_GPG_FINGERPRINT" <<<"$out"; then
        run rm -f "$keyfile"
        die 1 "Cheia Docker nu are fingerprintul așteptat (${DOCKER_GPG_FINGERPRINT}). Am șters $keyfile; verifică sursa/rețeaua (posibil MITM) și reia."
    fi
    log_write INFO "Cheia Docker verificată: fingerprint ${DOCKER_GPG_FINGERPRINT}"
}

# B4: cheia Tailscale doar validată ca PGP; fingerprint în log, FĂRĂ pin (rotație liberă).
verify_tailscale_key() {
    local keyfile="$1"
    local out fpr

    out="$(cmd_gpg --show-keys --with-colons "$keyfile" 2>/dev/null || true)"
    fpr="$(grep -E '^fpr:' <<<"$out" | awk -F: '{print $10}' | head -1)"
    if [[ -z "$fpr" ]]; then
        run rm -f "$keyfile"
        die 1 "Cheia Tailscale nu este un keyring PGP valid; am șters $keyfile. Verifică sursa/rețeaua și reia."
    fi
    log_write INFO "Cheie Tailscale validă (PGP), fingerprint: ${fpr} (fără pin, poate fi rotită)"
}

setup_docker_repository() {
    info "Configurez repository-ul oficial Docker stable..."

    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL "${DOCKER_REPO_URL}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "La rularea reală: verific fingerprintul cheii Docker (${DOCKER_GPG_FINGERPRINT}) cu gpg --show-keys."
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
    info "Configurez repository-ul oficial Tailscale stable..."

    run install -m 0755 -d /usr/share/keyrings
    run curl -fsSL "${TAILSCALE_REPO_URL}/${CODENAME}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    run chmod a+r /usr/share/keyrings/tailscale-archive-keyring.gpg

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "La rularea reală: validez cheia Tailscale ca PGP cu gpg --show-keys (fără pin)."
    else
        verify_tailscale_key /usr/share/keyrings/tailscale-archive-keyring.gpg
    fi

    # R2: curățenie — un tailscale.list vechi (rulări cu scriptul original)
    # ar produce „configured multiple times”; îl eliminăm
    local old_list="${DS_TAILSCALE_OLD_LIST:-/etc/apt/sources.list.d/tailscale.list}"
    if [[ -e "$old_list" ]]; then
        log_write INFO "Elimin vechiul ${old_list} (înlocuit de tailscale.sources)"
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
        info "Elimin pachetele conflictuale cu Docker: ${present[*]}"
        run apt-get "${APT_OPTS[@]}" remove "${present[@]}"
    else
        log_write INFO "D1: nu există pachete conflictuale cu Docker"
    fi

    if command -v snap >/dev/null 2>&1 && cmd_snap list docker >/dev/null 2>&1; then
        info "Elimin snap-ul docker..."
        run snap remove docker
    fi
}

install_docker() {
    info "Instalez Docker Engine, Buildx și Docker Compose plugin..."
    if [[ "$DOCKER_LXC_NO_NESTING" == "yes" ]]; then
        warn "LXC neprivilegiat: Docker necesită nesting activat pe host (security.nesting=true); serviciul s-ar putea să nu pornească în guest."
    fi
    run apt-get "${APT_OPTS[@]}" install \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin
    # B8: pornirea serviciului nu trebuie să aborteze instalarea
    if run systemctl enable --now docker.service; then
        ok "Docker instalat."
    else
        warn "Docker este instalat, dar serviciul nu a pornit; verifică nesting-ul (LXC) și 'journalctl -u docker'."
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
        info "Îmbin /etc/docker/daemon.json: log-opts 10m x 3, live-restore, no-new-privileges${DOCKER_POOL:+, default-address-pools din $DOCKER_POOL}${DOCKER_BIND_LOCALHOST:+, ip=127.0.0.1}; cheile existente ale utilizatorului se păstrează; restart docker doar dacă fișierul se schimbă."
        return 0
    fi

    run install -d -m 0755 "$(dirname "$file")"

    if [[ -f "$file" ]] && ! cmd_python3 -m json.tool "$file" >/dev/null 2>&1; then
        warn "daemon.json existent este JSON invalid; nu îl modific — corectează manual $file."
        return 0
    fi

    merged="$(merge_docker_config "$file")" || rc=$?
    if [[ "$rc" == "1" ]]; then
        warn "daemon.json existent nu este un obiect JSON valid; nu îl modific."
        return 0
    fi
    if [[ "$rc" == "2" ]]; then
        info "daemon.json este deja la setările gestionate; docker nu este repornit."
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
            warn "daemon.json scris era invalid; am restaurat backupul."
        else
            run rm -f "$file"
            warn "daemon.json scris era invalid; am șters fișierul nou."
        fi
        die 1 "Validarea JSON a eșuat după scrierea $file."
    fi

    run systemctl restart docker.service
    ok "daemon.json actualizat (log rotation 10m x 3, live-restore, no-new-privileges); docker repornit."
}

# D4: opțional — adaugă un user existent în grupul docker (echivalent root)
configure_docker_user() {
    if [[ "$INSTALL_DOCKER" != "yes" || -z "$DOCKER_USER" ]]; then
        return 0
    fi

    warn "$DOCKER_USER devine echivalent-root prin grupul docker (acces la /var/run/docker.sock)."
    run usermod -aG docker "$DOCKER_USER"
    ok "Utilizatorul $DOCKER_USER este în grupul docker (relogare necesară)."
}

install_tailscale() {
    info "Instalez Tailscale stable..."
    # F1: subcomanda 'install' lipsa → apt eșua pe mașină reală
    run apt-get "${APT_OPTS[@]}" install tailscale
    if run systemctl enable --now tailscaled.service; then
        ok "Tailscale instalat și tailscaled pornit."
    else
        warn "Tailscale este instalat, dar tailscaled nu a pornit. Verifică /dev/net/tun și jurnalul serviciului, mai ales în LXC."
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
            die 1 "Configurația SSH este invalidă; modificările au fost anulate."
        fi
        [[ -z "$backup90" ]] || rm -f "$backup90"

        # A3: valorile EFECTIVE (sshd -T) trebuie să reflecte politica ssh-keys-only
        if [[ "$SSH_KEYS_ONLY" == "yes" ]]; then
            if ! sshd_effective_keys_only; then
                restore_ssh_dropin "$config_00" "$backup00" "$had00"
                [[ -z "$backup00" ]] || rm -f "$backup00"
                die 1 "sshd -T arată valori diferite de politica ssh-keys-only (passwordauthentication/kbdinteractiveauthentication/permitrootlogin); am restaurat $config_00. Verifică alte drop-in-uri (ex. 50-cloud-init.conf)."
            fi
            ok "Politica ssh-keys-only este activă și efectivă (sshd -T)."
            [[ -z "$backup00" ]] || rm -f "$backup00"
        fi
    fi

    run systemctl enable --now ssh.service 2>/dev/null \
        || run systemctl enable --now sshd.service 2>/dev/null \
        || warn "Nu am putut porni automat serviciul SSH."

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
        ok "Configurația SSH este validă."
    fi
}

# Export UFW înainte de reset: status numbered în log + copie /etc/ufw în /var/backups/
backup_ufw_before_reset() {
    local stamp backup_dir
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="/var/backups/ufw-$stamp"

    info "Salvez regulile UFW existente înainte de reset..."
    if [[ "$DRY_RUN" == "yes" ]]; then
        run ufw status numbered
    else
        log_write INFO "ufw status numbered (înainte de reset):
$(ufw status numbered 2>/dev/null || true)"
    fi
    run install -d -m 0700 "$backup_dir"
    run cp -a /etc/ufw "$backup_dir/"
    if [[ "$DRY_RUN" != "yes" ]]; then
        ok "Backup UFW în $backup_dir."
    fi
}

# B7: asigură IPV6=yes în /etc/default/ufw (idempotent)
set_ufw_ipv6() {
    local file="${DS_UFW_DEFAULT:-/etc/default/ufw}"

    if [[ -r "$file" ]] && grep -q '^IPV6=yes' "$file"; then
        log_write INFO "IPV6=yes deja setat în $file"
        return 0
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
        printf '%s[DRY-RUN]%s setez IPV6=yes în %s\n' "${CYAN}" "${NC}" "$file"
        return 0
    fi

    if [[ -f "$file" ]] && grep -q '^IPV6=' "$file"; then
        run sed -i 's/^IPV6=.*/IPV6=yes/' "$file"
    else
        printf 'IPV6=yes\n' | run tee -a "$file" >/dev/null
    fi
    log_write WRITE "$file (IPV6=yes)"
    ok "IPV6=yes în $file."
}

configure_ufw() {
    local cidr

    if [[ "$SKIP_FIREWALL" == "yes" ]]; then
        warn "Sar configurarea UFW; firewall-ul trebuie configurat pe hostul LXC."
        return 0
    fi

    info "Configurez UFW..."

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
    ok "UFW activat; porturile publice $SSH_PORT, 80 și 443 nu sunt deschise global."
}

configure_fail2ban() {
    if [[ "$INSTALL_FAIL2BAN" != "yes" ]]; then
        return 0
    fi

    if [[ "$SKIP_FIREWALL" == "yes" ]]; then
        warn "Sar Fail2Ban în LXC neprivilegiat; protecția trebuie făcută pe host."
        return 0
    fi

    info "Configurez Fail2Ban pentru SSH..."
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
        ok "Fail2Ban activ pentru SSH."
    else
        verify_fail2ban_jail
    fi
}

# B2: după pornire, jail-ul sshd trebuie să fie activ
verify_fail2ban_jail() {
    if cmd_fail2ban_client status sshd >/dev/null 2>&1; then
        ok "Fail2Ban activ pentru SSH (jail sshd activ)."
    else
        warn "Fail2Ban rulează, dar jail-ul sshd nu răspunde; verifică 'fail2ban-client status sshd' și jurnalul."
    fi
}

bootstrap() {
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a

    info "Actualizez indexul APT..."
    run apt-get "${APT_OPTS[@]}" update

    if [[ "$SKIP_UPGRADE" != "yes" ]]; then
        info "Actualizez Debian (full-upgrade)..."
        run apt-get "${APT_OPTS[@]}" full-upgrade
        ok "Debian actualizat."
    fi

    info "Instalez pachetele de bază..."
    local base_packages=(
        ca-certificates
        curl
        gnupg
        iproute2
        openssh-server
        python3-minimal
        python3-systemd
        sudo
        ufw
    )
    if [[ "$INSTALL_AUTO_UPDATES" == "yes" ]]; then
        base_packages+=(unattended-upgrades)
    fi
    run apt-get "${APT_OPTS[@]}" install "${base_packages[@]}"
    ok "Pachetele de bază sunt instalate."

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
        info "Actualizez indexul APT pentru repository-urile oficiale..."
        run apt-get "${APT_OPTS[@]}" update
    fi

    if [[ "$INSTALL_DOCKER" == "yes" ]]; then
        install_docker
    fi

    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        install_tailscale
    fi

    if [[ "$INSTALL_FAIL2BAN" == "yes" && "$SKIP_FIREWALL" != "yes" ]]; then
        info "Instalez Fail2Ban..."
        run apt-get "${APT_OPTS[@]}" install fail2ban
    fi

    configure_ssh
    configure_ufw
    configure_fail2ban

    # U-verificare fail-loud: originea de securitate trebuie să apară
    if [[ "$INSTALL_AUTO_UPDATES" == "yes" ]]; then
        if [[ "$DRY_RUN" == "yes" ]]; then
            info "La final: verific că 'unattended-upgrade --dry-run --debug' listează ${CODENAME}-security."
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
    echo " VERIFICARE"
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
        printf 'planificat'
        return 0
    fi
    if cmd_systemctl is-active --quiet "$unit" 2>/dev/null; then
        printf 'activ'
    else
        printf 'INACTIV'
    fi
}

final_notes() {
    echo
    echo "============================================================"
    echo " DONE — REZUMAT"
    echo "============================================================"
    echo
    echo "Mod:            ${MODE:-?} (distro ${DISTRO:-?} / ${CODENAME:-?})"
    echo "SSH:            port ${SSH_PORT}, permis din: ${SSH_CIDRS[*]}"
    if [[ -n "$WIREGUARD_IFACE" ]]; then
        echo "                + regulă pe interfața ${WIREGUARD_IFACE}"
    fi
    echo "Servicii:"
    if [[ "$INSTALL_DOCKER" == "yes" ]]; then
        echo "  docker:       instalat; serviciul: $(svc_status docker.service)"
    else
        echo "  docker:       sărit"
    fi
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        echo "  tailscale:    instalat; tailscaled: $(svc_status tailscaled.service)"
    else
        echo "  tailscale:    sărit"
    fi
    if [[ "$SKIP_FIREWALL" == "yes" ]]; then
        echo "  ufw:          sărit (LXC neprivilegiat)"
    else
        echo "  ufw:          $(svc_status ufw.service)"
    fi
    if [[ "$INSTALL_FAIL2BAN" == "yes" && "$SKIP_FIREWALL" != "yes" ]]; then
        echo "  fail2ban:     $(svc_status fail2ban.service)"
    else
        echo "  fail2ban:     sărit"
    fi
    echo
    echo "Pași următori:"
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        echo "  - sudo tailscale up   (autentificarea Tailscale e manuală)"
    fi
    if [[ -f /var/run/reboot-required ]]; then
        echo "  - REBOOT NECESAR: /var/run/reboot-required există."
    else
        echo "  - verifică dacă e nevoie de reboot după update-uri (/var/run/reboot-required)."
    fi
    echo
    echo "Avertismente:"

    if [[ "$INSTALL_DOCKER" == "yes" ]]; then
        warn "Pentru Cloudflare Tunnel, evită ports: în Docker Compose; folosește aceeași rețea Docker cu aplicația."
        warn "Docker poate ocoli regulile UFW pentru porturi publicate; nu publica porturi pe 0.0.0.0 fără o regulă explicită."
        warn "Fără reguli DOCKER-USER automate: pentru filtrare pe container, adaugă-le manual (ex: iptables -I DOCKER-USER -i eth0 -p tcp --dport 5432 -j DROP)."
    fi

    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        warn "Tailscale nu este autentificat automat. Rulează: sudo tailscale up"
    fi

    if [[ "$RESET_FIREWALL" != "yes" ]]; then
        warn "Regulile UFW existente nu au fost șterse. Pentru o politică complet curată, folosește --reset-firewall pe un server pregătit pentru bootstrap."
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

    open_log
    log_write INFO "Start debian-setup.sh ${VERSION} (pid $$)"

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "Mod --dry-run: se afișează doar planul; nu se face nicio modificare."
    fi

    preflight
    print_detection
    print_plan_summary

    if [[ "$DRY_RUN" != "yes" && "$NONINTERACTIVE" != "yes" ]]; then
        if ! yes_no "Aplic această configurație?" y; then
            log_write INFO "Anulat de utilizator înainte de orice modificare"
            exit 0
        fi
    fi

    bootstrap

    if [[ "$DRY_RUN" != "yes" ]]; then
        verify_installation
    fi

    final_notes
    log_write INFO "Finalizat cu succes"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
