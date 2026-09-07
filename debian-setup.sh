#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Debian server bootstrap — Docker, Compose, UFW, Fail2Ban,
# Tailscale și SSH privat.
#
# Debian 12 / 13. Docker și Tailscale sunt instalate din
# repository-urile oficiale, pe canalul stable.
#
# Cloudflare Tunnel nu este configurat aici. El rulează ulterior
# prin Docker Compose și nu necesită porturile 80/443 inbound.
#
# Exemple:
#   sudo bash debian-setup.sh
#   sudo bash debian-setup.sh --mode lan
#   sudo bash debian-setup.sh -y --mode vps --wireguard-cidr 10.8.0.0/24
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

NONINTERACTIVE=no
MODE=""
LAN_CIDR=""
WIREGUARD_CIDR=""
TAILSCALE_CIDR="100.64.0.0/10"
INSTALL_DOCKER=yes
INSTALL_TAILSCALE=yes
INSTALL_FAIL2BAN=yes
RESET_FIREWALL=no
SKIP_UPGRADE=no
ALLOW_CURRENT_SSH=no

SKIP_FIREWALL=no
SSH_SOURCE_IP=""
DETECTED_LAN_CIDR=""
VERSION_CODENAME=""
SSH_CIDRS=()

usage() {
    cat <<'EOF'
Debian server bootstrap — Docker, Compose, UFW, Fail2Ban, Tailscale

Usage:
  sudo bash debian-setup.sh [opțiuni]

Opțiuni:
  -y, --yes                  Non-interactiv; necesită --mode
  --mode lan|vps             LAN = SSH din LAN/VPN; VPS = SSH doar din VPN
  --lan-cidr CIDR            Subnetul LAN permis pentru SSH
  --wireguard-cidr CIDR      Subnetul sau sursa WireGuard permisă pentru SSH
  --no-docker                Nu instala Docker Engine + Compose plugin
  --no-tailscale             Nu instala Tailscale
  --no-fail2ban              Nu instala/configura Fail2Ban
  --reset-firewall           Resetează regulile UFW existente înainte de configurare
  --allow-current-ssh        Permite explicit IP-ul sesiunii SSH curente
  --skip-upgrade             Nu executa apt full-upgrade
  -h, --help

Comportament de rețea:
  LAN:
    SSH este permis din --lan-cidr, --wireguard-cidr și Tailscale.
  VPS:
    SSH public nu este permis; SSH este permis doar din WireGuard/Tailscale.

Tailscale folosește canalul oficial stable. Autentificarea rămâne manuală:
  sudo tailscale up

Cloudflare Tunnel nu are nevoie de porturile 80/443 deschise.
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
            (( octet <= 255 )) || return 1
        done
        (( prefix <= 32 )) || return 1
        return 0
    fi

    if [[ "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]]; then
        prefix="${value##*/}"
        (( prefix <= 128 )) || return 1
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
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        SSH_SOURCE_IP="$(awk '{print $1}' <<< "$SSH_CONNECTION")"
    elif [[ -n "${SSH_CLIENT:-}" ]]; then
        SSH_SOURCE_IP="$(awk '{print $1}' <<< "$SSH_CLIENT")"
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
    echo " Debian server bootstrap"
    echo "============================================================"
    echo
    echo "Sistem:       ${PRETTY_NAME:-Debian}"
    echo "Codename:     ${VERSION_CODENAME:-necunoscut}"
    echo "Mod rețea:    ${MODE:-nesetat}"
    echo "LAN CIDR:     ${LAN_CIDR:-nesetat}"
    echo "WireGuard:    ${WIREGUARD_CIDR:-nesetat}"
    echo "Tailscale:    $([[ "$INSTALL_TAILSCALE" == "yes" ]] && echo "${TAILSCALE_CIDR}" || echo NU)"
    echo
}

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            NONINTERACTIVE=yes
            shift
            ;;
        --mode)
            [[ $# -ge 2 ]] || die "Lipsește valoarea pentru --mode."
            MODE="${2,,}"
            shift 2
            ;;
        --lan-cidr)
            [[ $# -ge 2 ]] || die "Lipsește valoarea pentru --lan-cidr."
            LAN_CIDR="$2"
            shift 2
            ;;
        --wireguard-cidr)
            [[ $# -ge 2 ]] || die "Lipsește valoarea pentru --wireguard-cidr."
            WIREGUARD_CIDR="$2"
            shift 2
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
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Opțiune necunoscută: $1 (vezi --help)"
            ;;
    esac
done

# ------------------------------------------------------------
# Preflight
# ------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Rulează scriptul cu sudo sau ca root."
[[ -r /etc/os-release ]] || die "Nu găsesc /etc/os-release."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "Scriptul este destinat Debian."

DEBIAN_VERSION="${VERSION_ID%%.*}"
if [[ "$DEBIAN_VERSION" != "12" && "$DEBIAN_VERSION" != "13" ]]; then
    die "Sunt suportate Debian 12 și 13; detectat: ${PRETTY_NAME:-necunoscut}."
fi

VERSION_CODENAME="${VERSION_CODENAME:-}"
if [[ -z "$VERSION_CODENAME" ]]; then
    case "$DEBIAN_VERSION" in
        12) VERSION_CODENAME=bookworm ;;
        13) VERSION_CODENAME=trixie ;;
    esac
fi

require_tty_or_yes
detect_ssh_source
DETECTED_LAN_CIDR="$(detect_lan_cidr || true)"

if [[ -z "$MODE" ]]; then
    if [[ "$NONINTERACTIVE" == "yes" ]]; then
        die "În modul non-interactiv trebuie să specifici --mode lan sau --mode vps."
    fi

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

[[ "$MODE" == "lan" || "$MODE" == "vps" ]] \
    || die "--mode trebuie să fie lan sau vps."

if [[ -z "$LAN_CIDR" && "$MODE" == "lan" ]]; then
    if [[ "$NONINTERACTIVE" == "yes" ]]; then
        LAN_CIDR="$DETECTED_LAN_CIDR"
    else
        read -r -p "CIDR LAN [${DETECTED_LAN_CIDR:-ex. 192.168.1.0/24}]: " LAN_CIDR
        LAN_CIDR="${LAN_CIDR:-$DETECTED_LAN_CIDR}"
    fi
fi

if [[ -n "$LAN_CIDR" ]]; then
    valid_cidr "$LAN_CIDR" || die "LAN CIDR invalid: $LAN_CIDR"
fi

if [[ -n "$WIREGUARD_CIDR" ]]; then
    valid_cidr "$WIREGUARD_CIDR" || die "WireGuard CIDR invalid: $WIREGUARD_CIDR"
elif [[ "$NONINTERACTIVE" != "yes" ]]; then
    if yes_no "Permitești SSH din WireGuard?" y; then
        read -r -p "Subnetul WireGuard sau sursa văzută de server (ex. 10.8.0.0/24): " WIREGUARD_CIDR
        [[ -z "$WIREGUARD_CIDR" ]] || valid_cidr "$WIREGUARD_CIDR" \
            || die "WireGuard CIDR invalid: $WIREGUARD_CIDR"
    fi
fi

if [[ "$NONINTERACTIVE" != "yes" ]]; then
    yes_no "Instalez Docker Engine și Docker Compose plugin?" y \
        && INSTALL_DOCKER=yes || INSTALL_DOCKER=no
    yes_no "Instalez Tailscale din repository-ul oficial stable?" y \
        && INSTALL_TAILSCALE=yes || INSTALL_TAILSCALE=no
    yes_no "Instalez și configurez Fail2Ban pentru SSH?" y \
        && INSTALL_FAIL2BAN=yes || INSTALL_FAIL2BAN=no
fi

if [[ -n "$LAN_CIDR" ]]; then
    add_ssh_cidr "$LAN_CIDR"
fi
if [[ -n "$WIREGUARD_CIDR" ]]; then
    add_ssh_cidr "$WIREGUARD_CIDR"
fi
if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
    add_ssh_cidr "$TAILSCALE_CIDR"
fi

if [[ "$ALLOW_CURRENT_SSH" == "yes" && -n "$SSH_SOURCE_IP" ]]; then
    if [[ "$SSH_SOURCE_IP" == *:* ]]; then
        add_ssh_cidr "${SSH_SOURCE_IP}/128"
    else
        add_ssh_cidr "${SSH_SOURCE_IP}/32"
    fi
fi

if [[ ${#SSH_CIDRS[@]} -eq 0 ]]; then
    die "Nu există nicio rețea permisă pentru SSH. Configurează WireGuard/Tailscale sau --lan-cidr."
fi

# Detectează doar cazul în care firewall-ul din guest nu poate funcționa.
if command -v systemd-detect-virt >/dev/null 2>&1 \
    && systemd-detect-virt --quiet --container \
    && [[ -r /proc/1/uid_map ]]; then
    uid_outside="$(awk 'NR == 1 {print $2}' /proc/1/uid_map)"
    if [[ -n "$uid_outside" && "$uid_outside" != "0" ]]; then
        SKIP_FIREWALL=yes
        warn "LXC neprivilegiat detectat: UFW/Fail2Ban nu vor fi activate în guest."
    fi
fi

print_detection

echo "============================================================"
echo " CONFIGURAȚIE"
echo "============================================================"
echo
echo "Docker + Compose:       $INSTALL_DOCKER"
echo "Tailscale:              $INSTALL_TAILSCALE"
echo "Fail2Ban:               $INSTALL_FAIL2BAN"
echo "Firewall UFW:            $([[ "$SKIP_FIREWALL" == "yes" ]] && echo 'sarit în LXC neprivilegiat' || echo DA)"
echo "Reset reguli UFW:        $RESET_FIREWALL"
echo "Upgrade Debian:          $([[ "$SKIP_UPGRADE" == "yes" ]] && echo NU || echo DA)"
echo "SSH permis din:          ${SSH_CIDRS[*]}"
if [[ -n "$SSH_SOURCE_IP" ]]; then
    echo "SSH curent din:          $SSH_SOURCE_IP"
fi
echo

if [[ "$NONINTERACTIVE" != "yes" ]]; then
    yes_no "Aplic această configurație?" y || exit 0
fi

# ------------------------------------------------------------
# Base packages and repositories
# ------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

info "Actualizez indexul APT..."
apt-get update

if [[ "$SKIP_UPGRADE" != "yes" ]]; then
    info "Actualizez Debian (full-upgrade)..."
    apt-get "${APT_OPTS[@]}" full-upgrade
    ok "Debian actualizat."
fi

info "Instalez pachetele de bază..."
apt-get install "${APT_OPTS[@]}" \
    ca-certificates \
    curl \
    gnupg \
    iproute2 \
    openssh-server \
    python3-minimal \
    sudo \
    ufw
ok "Pachetele de bază sunt instalate."

# Dacă sesiunea SSH curentă nu este în una dintre rețelele configurate,
# refuzăm activarea firewall-ului pentru a evita lockout-ul accidental.
if [[ "$SKIP_FIREWALL" != "yes" && -n "$SSH_SOURCE_IP" && "$ALLOW_CURRENT_SSH" != "yes" ]]; then
    current_allowed=no
    for cidr in "${SSH_CIDRS[@]}"; do
        if ip_in_cidr "$SSH_SOURCE_IP" "$cidr"; then
            current_allowed=yes
            break
        fi
    done

    if [[ "$current_allowed" != "yes" ]]; then
        die "Sesiunea SSH curentă ($SSH_SOURCE_IP) nu este acoperită de regulile propuse. Configurează CIDR-ul corect, rulează din consolă sau folosește explicit --allow-current-ssh."
    fi
fi

setup_docker_repository() {
    info "Configurez repository-ul oficial Docker stable..."

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

setup_tailscale_repository() {
    info "Configurez repository-ul oficial Tailscale stable..."

    install -m 0755 -d /usr/share/keyrings
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${VERSION_CODENAME}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    chmod a+r /usr/share/keyrings/tailscale-archive-keyring.gpg

    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${VERSION_CODENAME}.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list
}

if [[ "$INSTALL_DOCKER" == "yes" ]]; then
    setup_docker_repository
fi
if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
    setup_tailscale_repository
fi

if [[ "$INSTALL_DOCKER" == "yes" || "$INSTALL_TAILSCALE" == "yes" ]]; then
    info "Actualizez indexul APT pentru repository-urile oficiale..."
    apt-get update
fi

if [[ "$INSTALL_DOCKER" == "yes" ]]; then
    info "Instalez Docker Engine, Buildx și Docker Compose plugin..."
    apt-get install "${APT_OPTS[@]}" \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin
    systemctl enable --now docker.service
    ok "Docker instalat."
fi

if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
    info "Instalez Tailscale stable..."
    apt-get install "${APT_OPTS[@]}" tailscale
    systemctl enable --now tailscaled.service
    ok "Tailscale instalat și tailscaled pornit."
fi

if [[ "$INSTALL_FAIL2BAN" == "yes" && "$SKIP_FIREWALL" != "yes" ]]; then
    info "Instalez Fail2Ban..."
    apt-get install "${APT_OPTS[@]}" fail2ban
fi

# ------------------------------------------------------------
# SSH baseline
# ------------------------------------------------------------

configure_ssh() {
    local config_file=/etc/ssh/sshd_config.d/90-bootstrap-security.conf
    local backup_file
    local had_config=no

    mkdir -p /etc/ssh/sshd_config.d
    backup_file="$(mktemp)"

    if [[ -f "$config_file" ]]; then
        cp -p "$config_file" "$backup_file"
        had_config=yes
    fi

    cat >"$config_file" <<'EOF'
# Managed by debian-setup.sh
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 5
EOF

    if ! sshd -t; then
        if [[ "$had_config" == "yes" ]]; then
            cp -p "$backup_file" "$config_file"
        else
            rm -f "$config_file"
        fi
        rm -f "$backup_file"
        die "Configurația SSH este invalidă; modificarea a fost anulată."
    fi

    rm -f "$backup_file"

    systemctl enable --now ssh.service 2>/dev/null \
        || systemctl enable --now sshd.service 2>/dev/null \
        || warn "Nu am putut porni automat serviciul SSH."
    systemctl reload ssh.service 2>/dev/null \
        || systemctl reload sshd.service 2>/dev/null \
        || true
    ok "Configurația SSH este validă."
}

configure_ssh

# ------------------------------------------------------------
# UFW
# ------------------------------------------------------------

configure_ufw() {
    local cidr

    if [[ "$SKIP_FIREWALL" == "yes" ]]; then
        warn "Sar configurarea UFW; firewall-ul trebuie configurat pe hostul LXC."
        return 0
    fi

    info "Configurez UFW..."

    if [[ "$RESET_FIREWALL" == "yes" ]]; then
        ufw --force reset
    fi

    ufw default deny incoming
    ufw default allow outgoing
    ufw logging low

    for cidr in "${SSH_CIDRS[@]}"; do
        ufw allow from "$cidr" to any port 22 proto tcp comment 'SSH trusted network'
    done

    # Nu deschidem 80/443. Cloudflare Tunnel face conexiuni outbound.
    ufw --force enable
    ok "UFW activat; porturile publice 22, 80 și 443 nu sunt deschise global."
}

configure_ufw

# ------------------------------------------------------------
# Fail2Ban
# ------------------------------------------------------------

configure_fail2ban() {
    if [[ "$INSTALL_FAIL2BAN" != "yes" ]]; then
        return 0
    fi

    if [[ "$SKIP_FIREWALL" == "yes" ]]; then
        warn "Sar Fail2Ban în LXC neprivilegiat; protecția trebuie făcută pe host."
        return 0
    fi

    info "Configurez Fail2Ban pentru SSH..."
    install -d -m 0755 /etc/fail2ban/jail.d
    cat >/etc/fail2ban/jail.d/sshd-bootstrap.local <<'EOF'
[sshd]
enabled = true
backend = auto
banaction = ufw
maxretry = 5
findtime = 10m
bantime = 1h
EOF

    systemctl enable --now fail2ban.service
    systemctl restart fail2ban.service
    ok "Fail2Ban activ pentru SSH."
}

configure_fail2ban

# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------

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

if [[ "$INSTALL_FAIL2BAN" == "yes" && "$SKIP_FIREWALL" != "yes" ]]; then
    echo
    echo "--- Fail2Ban ---"
    fail2ban-client status sshd 2>/dev/null || true
fi

echo
echo "--- Listening ports ---"
ss -lntup || true

echo
echo "============================================================"
echo " DONE"
echo "============================================================"
echo

if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
    warn "Tailscale nu este autentificat automat. Rulează: sudo tailscale up"
fi

if [[ "$INSTALL_DOCKER" == "yes" ]]; then
    warn "Pentru Cloudflare Tunnel, evită ports: în Docker Compose; folosește aceeași rețea Docker cu aplicația."
    warn "Docker poate ocoli regulile UFW pentru porturi publicate; nu publica porturi pe 0.0.0.0 fără o regulă explicită."
fi

if [[ "$RESET_FIREWALL" != "yes" ]]; then
    warn "Regulile UFW existente nu au fost șterse. Pentru o politică complet curată, folosește --reset-firewall pe un server pregătit pentru bootstrap."
fi
