#!/bin/sh
# ============================================================
# alpine-setup.sh — Alpine Linux stable server backend
# Additive to debian-setup.sh; English-only; POSIX sh (BusyBox ash).
#
# Platform: Alpine Linux stable v3.24.x ONLY (3.24 / 3.24.<patch>),
# validated from /etc/os-release parsed as data (never sourced).
# Edge, older, newer and non-Alpine systems are rejected (exit 3).
#
# Packages come ONLY from the already-configured official Alpine
# repositories (v3.24 main + community must both be present; edge
# lines are refused; repositories are never modified). Services are
# managed with OpenRC only (rc-update / rc-service); the Tailscale
# init script is named "tailscale" (not tailscaled).
#
# Preserve-only by design — any explicit positive request is rejected
# BEFORE mutation (exit 2): SSH configuration, firewall, Fail2Ban,
# user provisioning, automatic updates. No SSH/firewall/auth code
# exists here; config keys for those areas accept only the preserve
# value.
#
# Safety properties:
#   - --config parses KEY=value lines as data (no eval, no source);
#     CLI always overrides config regardless of argument order
#     (scan_configs "$@" runs first, parse_args "$@" runs second).
#   - Wizard is opt-in; every default is No (preserve); EOF on any
#     prompt or the final apply confirmation exits 2 fail-closed.
#   - --inspect: read-only, no root, no log, no mutation.
#   - --dry-run: prints the real command plan, mutates nothing,
#     works as non-root; no booted-OpenRC requirement.
#   - Root is required only for actual apply; all-preserved
#     selections run zero mutating commands (no apk at all).
#   - Real apply with selected services requires a booted OpenRC
#     environment (/run/openrc) and fails BEFORE any apk command.
#   - DS_* test overrides are honored only in --dry-run or DS_TEST=1
#     environments (only DS_OS_RELEASE / DS_REPOSITORIES read-path
#     overrides); in a real run any DS_* variable => exit 2.
#   - Sourcing this file runs nothing (basename source guard).
#
# Exit codes: 0 ok; 1 execution error; 2 invalid/unsupported
# arguments/config; 3 unsupported OS/precondition; 4 reserved.
# ============================================================

set -eu

VERSION="2.8.1"
SCRIPT_NAME="alpine-setup.sh"
ALPINE_STABLE_BRANCH="3.24"
LOG_FILE="/var/log/alpine-setup.log"
CR=$(printf '\r')

PRINT_HELP=no
PRINT_VERSION=no
PRINT_CONFIG=no
INSPECT=no
DRY_RUN=no
WIZARD=no
NONINTERACTIVE=no
MODE=""
INSTALL_DOCKER=no
INSTALL_TAILSCALE=no
SKIP_UPGRADE=yes
MANAGE_SSH=no
SKIP_FIREWALL=yes
INSTALL_FAIL2BAN=no
INSTALL_AUTO_UPDATES=no
EXPLICIT=""
LOG_ENABLED=no
APK_PKGS=""

die() {
    di_code=1
    case "${1:-}" in
        '' | *[!0-9]*) : ;;
        *) di_code="$1"; shift ;;
    esac
    printf '[ERROR] %s\n' "$*" >&2
    exit "$di_code"
}

log_write() {
    if [ "$LOG_ENABLED" = yes ]; then
        printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" || :
    fi
    return 0
}

info() {
    printf '[INFO] %s\n' "$1"
    log_write INFO "$1"
}

warn() {
    printf '[WARN] %s\n' "$1" >&2
    log_write WARN "$1"
}

# run CMD ARGS... — mutation wrapper: dry-run prints the plan only.
run() {
    if [ "$DRY_RUN" = yes ]; then
        printf '[DRY-RUN] + %s\n' "$*"
        return 0
    fi
    log_write RUN "$*"
    if ! "$@"; then
        die 1 "Command failed: $*"
    fi
}

# read_answer PROMPT — yes only on y/yes; anything else (incl. empty)
# means No; EOF exits 2 before anything is applied.
read_answer() {
    ra_answer=""
    printf '%s' "$1"
    if ! read -r ra_answer; then
        die 2 "Input closed (EOF); configuration cancelled without applying anything."
    fi
    case "$ra_answer" in
        y | yes | Y | YES) return 0 ;;
        *) return 1 ;;
    esac
}

mark_explicit() {
    case " $EXPLICIT " in
        *" $1 "*) : ;;
        *) EXPLICIT="$EXPLICIT $1" ;;
    esac
    return 0
}

usage() {
    cat <<'EOF'
Alpine Linux stable server bootstrap — Docker + Compose, Tailscale (apk/OpenRC)

Usage:
  sh alpine-setup.sh [options]  # run as root to apply changes

Options:
  -h, --help              Show this help and exit
      --version           Print the script version and exit
      --inspect           Read-only inventory: no root, no log, no mutation
      --print-config      Print effective configuration (KEY=value) and exit
      --config FILE       KEY=value config file (parsed as data, no
                          eval/source); CLI arguments always win
      --dry-run           Print the full command plan without mutating;
                          works as non-root
      --wizard            Opt-in conservative assistant; every default is
                          No (preserve); EOF cancels before any change
  -y, --yes               Non-interactive; REQUIRES explicit --mode
      --mode lan|vps      Declarative target (informational on this
                          backend; no firewall rules are managed)
      --docker            Install Docker + Compose from Alpine repos
      --no-docker         Preserve (default: nothing installed)
      --tailscale         Install Tailscale from Alpine repos
      --no-tailscale      Preserve (default)
      --upgrade           Run full "apk upgrade" (default: skipped)
      --skip-upgrade      Preserve (default)
      --no-ssh            Preserve SSH configuration (default; the only
                          accepted SSH posture on Alpine)
      --no-firewall       Preserve firewall rules (default; the only
                          accepted firewall posture on Alpine)
      --no-fail2ban       Omit Fail2Ban (default; unsupported on Alpine)
      --no-auto-updates   Omit auto-updates (default; no safe
                          security-only apk mechanism exists)

Rejected before any mutation (exit 2): --manage-ssh, --reset-firewall,
--allow-current-ssh, --wireguard-iface, --lan-cidr, --wireguard-cidr,
--create-user, --ssh-key, --ssh-key-file, --ssh-keys-only, --allow-users,
--docker-user, --no-sudo-nopasswd, --mail, --auto-reboot,
--update-third-party, --strict, --docker-pool, --docker-bind-localhost,
--no-docker-config, and any unknown option.

Platform policy:
  - ID=alpine with VERSION_ID 3.24 / 3.24.<numeric patch> only; edge,
    older, newer or unknown releases exit 3.
  - Package installation requires v3.24 main AND community already in
    /etc/apk/repositories; edge lines are refused (no repository
    mixing). Repositories are never modified.
  - Apply requires root and a booted OpenRC system (/run/openrc).
  - Services: rc-update add <svc> default; rc-service <svc> start only
    if not running. Docker service: docker. Tailscale service:
    tailscale (its init script runs tailscaled). VPN authentication
    ("tailscale up") is never automated.
  - All-preserved selection runs zero mutating commands.

Config file keys (KEY=value, validated exactly): MODE (lan|vps),
INSTALL_DOCKER, INSTALL_TAILSCALE, SKIP_UPGRADE (yes|no), and the
preserve-only MANAGE_SSH=no, SKIP_FIREWALL=yes, INSTALL_FAIL2BAN=no,
INSTALL_AUTO_UPDATES=no (any other value or key exits 2).

Exit codes: 0 ok, 1 execution error, 2 invalid/unsupported arguments or
configuration, 3 unsupported OS/precondition, 4 reserved (lockout risk;
unused — this backend never touches SSH or firewall state).
EOF
    printf 'Version: %s (platform: Alpine Linux %s.x stable)\n' \
        "$VERSION" "$ALPINE_STABLE_BRANCH"
}

# ------------------------------------------------------------
# OS detection and repositories (both parsed as DATA, never sourced)
# ------------------------------------------------------------
os_release_field() { # FILE FIELD -> value on stdout (may be empty)
    orf_val=""
    [ -r "$1" ] || return 0
    while IFS= read -r orf_line || [ -n "$orf_line" ]; do
        case "$orf_line" in
            "$2="*)
                orf_val=${orf_line#"$2="}
                case "$orf_val" in
                    '"'*) orf_val=${orf_val#\"}; orf_val=${orf_val%\"} ;;
                    "'"*) orf_val=${orf_val#\'}; orf_val=${orf_val%\'} ;;
                esac
                break
                ;;
        esac
    done <"$1"
    printf '%s' "$orf_val"
}

detect_distro() {
    dd_file=${DS_OS_RELEASE:-/etc/os-release}
    [ -r "$dd_file" ] || die 3 "Cannot read $dd_file; cannot identify the distribution."
    DD_ID=$(os_release_field "$dd_file" ID)
    DD_VER=$(os_release_field "$dd_file" VERSION_ID)
    DD_PRETTY=$(os_release_field "$dd_file" PRETTY_NAME)
    if [ "$DD_ID" != "alpine" ]; then
        die 3 "Unsupported distribution: ${DD_PRETTY:-${DD_ID:-unknown}}. This backend supports Alpine Linux stable ${ALPINE_STABLE_BRANCH}.x only."
    fi
    case "$DD_VER" in
        3.24) : ;;
        3.24.*)
            dd_patch=${DD_VER#3.24.}
            case "$dd_patch" in
                '' | *[!0-9]*)
                    die 3 "Unsupported Alpine release '$DD_VER'. Supported: stable 3.24 and 3.24.<numeric patch> only (edge/alpha/older/newer are rejected; switch repositories manually — this script never edits them)."
                    ;;
            esac
            ;;
        *) die 3 "Unsupported Alpine release '${DD_VER:-unknown}'. Supported: stable 3.24 and 3.24.<numeric patch> only (edge/alpha/older/newer are rejected; switch repositories manually — this script never edits them)." ;;
    esac
}

# Repositories are read-only facts. Every non-comment line must be a
# stable v3.24 main or community entry (exact /v3.24/main or
# /v3.24/community, optional trailing slash); anything else (edge,
# other branches, malformed lines) is rejected. Tagged entries
# ("@tag repo") are validated but do NOT satisfy the untagged
# (default) repository requirement, because tagged repos are not
# used for default dependency resolution. The file is never modified.
check_repositories() {
    cr_file=${DS_REPOSITORIES:-/etc/apk/repositories}
    [ -r "$cr_file" ] || die 3 "Cannot read $cr_file; apk repositories are not configured (fix manually; this script never edits repository configuration)."
    CR_MAIN=no
    CR_COMMUNITY=no
    while IFS= read -r cr_line || [ -n "$cr_line" ]; do
        cr_line=${cr_line%"$CR"}
        cr_line=${cr_line#"${cr_line%%[![:space:]]*}"}
        cr_line=${cr_line%"${cr_line##*[![:space:]]}"}
        case "$cr_line" in
            '' | '#'*) continue ;;
        esac
        cr_tagged=no
        case "$cr_line" in
            '@'*)
                cr_tagged=yes
                cr_tag=${cr_line%%[[:space:]]*}
                cr_line=${cr_line#"$cr_tag"}
                cr_line=${cr_line#"${cr_line%%[![:space:]]*}"}
                cr_line=${cr_line%"${cr_line##*[![:space:]]}"}
                ;;
        esac
        case "$cr_line" in
            */v3.24/main | */v3.24/main/ | */v3.24/community | */v3.24/community/) : ;;
            *) die 3 "Unsupported or malformed repository line in $cr_file: '$cr_line'. Only stable v3.24 main/community entries are allowed (edge, other branches and malformed lines are refused; edit $cr_file manually — this script never modifies it)." ;;
        esac
        if [ "$cr_tagged" = no ]; then
            case "$cr_line" in
                */v3.24/main*) CR_MAIN=yes ;;
                *) CR_COMMUNITY=yes ;;
            esac
        fi
    done <"$cr_file"
    if [ "$CR_MAIN" != yes ] || [ "$CR_COMMUNITY" != yes ]; then
        die 3 "Untagged Alpine v3.24 'main' AND 'community' repositories must BOTH be configured (main=$CR_MAIN community=$CR_COMMUNITY; tagged '@'-entries do not count). Add e.g. https://dl-cdn.alpinelinux.org/alpine/v3.24/community to $cr_file manually, then retry."
    fi
}

# ------------------------------------------------------------
# Read-only facts (apk / OpenRC; safe without root)
# ------------------------------------------------------------
pkg_state() {
    if command -v apk >/dev/null 2>&1 && apk info -e "$1" >/dev/null 2>&1; then
        printf installed
    else
        printf 'absent-or-unknown'
    fi
}

svc_exists() {
    [ -x "/etc/init.d/$1" ]
}

svc_running() {
    command -v rc-service >/dev/null 2>&1 && rc-service "$1" status >/dev/null 2>&1
}

svc_enabled() {
    command -v rc-update >/dev/null 2>&1 && rc-update show default 2>/dev/null | awk '{print $1}' | grep -qx -- "$1"
}

print_svc_line() {
    psl_state=unknown
    psl_runlevel=unknown
    if svc_exists "$1"; then
        psl_init=yes
        if [ -e /run/openrc/softlevel ] && command -v rc-service >/dev/null 2>&1; then
            if svc_running "$1"; then psl_state=running; else psl_state=stopped; fi
        fi
        if command -v rc-update >/dev/null 2>&1; then
            if svc_enabled "$1"; then psl_runlevel=enabled; else psl_runlevel=disabled; fi
        fi
    else
        psl_init=no
    fi
    printf 'Service %-10s init=%s state=%s runlevel-default=%s\n' \
        "$1" "$psl_init" "$psl_state" "$psl_runlevel"
    return 0
}

# ------------------------------------------------------------
# Config file (KEY=value as data; no eval, no source)
# ------------------------------------------------------------
load_config() {
    lc_file="$1"
    [ -r "$lc_file" ] || die 2 "Cannot read config file: $lc_file"
    while IFS= read -r lc_line || [ -n "$lc_line" ]; do
        lc_line=${lc_line%"$CR"}
        case "$lc_line" in
            '' | '#'*) continue ;;
            *=*) : ;;
            *) die 2 "Invalid line in $lc_file (expected KEY=value): $lc_line" ;;
        esac
        lc_key=${lc_line%%=*}
        lc_val=${lc_line#*=}
        case "$lc_key" in
            '' | *[!A-Z0-9_]*) die 2 "Invalid key in $lc_file: $lc_key" ;;
        esac
        lc_val=${lc_val#"${lc_val%%[![:space:]]*}"}
        lc_val=${lc_val%"${lc_val##*[![:space:]]}"}
        case "$lc_key" in
            MODE)
                case "$lc_val" in
                    lan | vps) MODE="$lc_val" ;;
                    *) die 2 "MODE must be lan or vps in $lc_file (got: $lc_val)" ;;
                esac
                ;;
            INSTALL_DOCKER | INSTALL_TAILSCALE | SKIP_UPGRADE)
                case "$lc_val" in
                    yes | no) : ;;
                    *) die 2 "$lc_key must be yes or no in $lc_file (got: $lc_val)" ;;
                esac
                case "$lc_key" in
                    INSTALL_DOCKER) INSTALL_DOCKER="$lc_val" ;;
                    INSTALL_TAILSCALE) INSTALL_TAILSCALE="$lc_val" ;;
                    SKIP_UPGRADE) SKIP_UPGRADE="$lc_val" ;;
                esac
                ;;
            MANAGE_SSH)
                [ "$lc_val" = no ] || die 2 "MANAGE_SSH=$lc_val rejected: SSH management is unsupported on Alpine; only MANAGE_SSH=no (preserve) is accepted."
                ;;
            SKIP_FIREWALL)
                [ "$lc_val" = yes ] || die 2 "SKIP_FIREWALL=$lc_val rejected: firewall management is unsupported on Alpine; only SKIP_FIREWALL=yes (preserve) is accepted."
                ;;
            INSTALL_FAIL2BAN)
                [ "$lc_val" = no ] || die 2 "INSTALL_FAIL2BAN=$lc_val rejected: Fail2Ban is unsupported on Alpine in this release; only INSTALL_FAIL2BAN=no is accepted."
                ;;
            INSTALL_AUTO_UPDATES)
                [ "$lc_val" = no ] || die 2 "INSTALL_AUTO_UPDATES=$lc_val rejected: no safe security-only auto-update mechanism exists on Alpine; only INSTALL_AUTO_UPDATES=no is accepted."
                ;;
            *) die 2 "Configuration key not supported by the Alpine backend: $lc_key (allowed: MODE INSTALL_DOCKER INSTALL_TAILSCALE SKIP_UPGRADE MANAGE_SSH SKIP_FIREWALL INSTALL_FAIL2BAN INSTALL_AUTO_UPDATES)" ;;
        esac
        mark_explicit "$lc_key"
    done <"$lc_file"
    return 0
}

# Config files are scanned first with their own positional params; the
# CLI is parsed afterwards from the SAME untouched "$@", so CLI wins
# regardless of argument order.
scan_configs() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --config)
                [ "$#" -ge 2 ] || die 2 "Missing value for --config."
                load_config "$2"
                shift 2
                ;;
            *) shift ;;
        esac
    done
    return 0
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h | --help) PRINT_HELP=yes ;;
            --version) PRINT_VERSION=yes ;;
            --inspect) INSPECT=yes ;;
            --print-config) PRINT_CONFIG=yes ;;
            --dry-run) DRY_RUN=yes ;;
            --wizard) WIZARD=yes ;;
            -y | --yes) NONINTERACTIVE=yes ;;
            --mode)
                [ "$#" -ge 2 ] || die 2 "Missing value for --mode."
                case "$2" in
                    lan | vps) MODE="$2" ;;
                    *) die 2 "--mode must be lan or vps (got: $2)" ;;
                esac
                shift
                ;;
            --config)
                [ "$#" -ge 2 ] || die 2 "Missing value for --config."
                shift
                ;;
            --docker) INSTALL_DOCKER=yes; mark_explicit INSTALL_DOCKER ;;
            --no-docker) INSTALL_DOCKER=no; mark_explicit INSTALL_DOCKER ;;
            --tailscale) INSTALL_TAILSCALE=yes; mark_explicit INSTALL_TAILSCALE ;;
            --no-tailscale) INSTALL_TAILSCALE=no; mark_explicit INSTALL_TAILSCALE ;;
            --upgrade) SKIP_UPGRADE=no; mark_explicit SKIP_UPGRADE ;;
            --skip-upgrade) SKIP_UPGRADE=yes; mark_explicit SKIP_UPGRADE ;;
            --no-ssh | --no-firewall | --no-fail2ban | --no-auto-updates) : ;;
            --manage-ssh | --reset-firewall | --allow-current-ssh | --wireguard-iface | --lan-cidr | --wireguard-cidr | --create-user | --ssh-key | --ssh-key-file | --ssh-keys-only | --allow-users | --docker-user | --no-sudo-nopasswd | --mail | --auto-reboot | --update-third-party | --strict | --docker-pool | --docker-bind-localhost | --no-docker-config)
                die 2 "$1 is not supported on the Alpine backend (SSH/firewall/auth/user/Fail2Ban/auto-update policy is preserve-only in this release). Nothing was changed."
                ;;
            *) die 2 "Unknown option: $1 (supported options are listed by --help)" ;;
        esac
        shift
    done
    return 0
}

# DS_* overrides: dry-run allows everything (nothing mutates);
# DS_TEST=1 allows only the two read-path overrides; a real run
# rejects any DS_* variable before mutating anything.
guard_ds_overrides() {
    if [ "$DRY_RUN" = yes ]; then
        return 0
    fi
    gd_names=$(env | sed -n 's/^\(DS_[A-Za-z0-9_]*\)=.*/\1/p')
    [ -n "$gd_names" ] || return 0
    if [ "${DS_TEST:-}" = "1" ]; then
        for gd_v in $gd_names; do
            case "$gd_v" in
                DS_TEST | DS_OS_RELEASE | DS_REPOSITORIES) : ;;
                *) die 2 "Unknown DS_ test override '$gd_v' outside --dry-run is not allowed." ;;
            esac
        done
        return 0
    fi
    die 2 "DS_* test variables detected in a real run ($gd_names); remove them from the environment or use --dry-run (test environments: DS_TEST=1)."
}

validate_selection() {
    if [ "$WIZARD" = yes ] && [ "$NONINTERACTIVE" = yes ]; then
        die 2 "--wizard requires interaction; do not combine it with -y/--yes."
    fi
    if [ "$NONINTERACTIVE" = yes ] && [ -z "$MODE" ]; then
        die 2 "--mode lan|vps is required with -y/--yes (non-interactive apply needs an explicit mode)."
    fi
    return 0
}

# Wizard (opt-in; every default is No = preserve; EOF fail-closed).
# Explicit CLI/config markers suppress the matching question.
run_wizard() {
    if [ "$WIZARD" != yes ]; then
        return 0
    fi
    printf '%s\n' "Wizard: Enter keeps the conservative default (No = preserve). EOF cancels before any change."
    case " $EXPLICIT " in
        *" INSTALL_DOCKER "*) : ;;
        *) if read_answer "Install Docker Engine + Compose from the Alpine repositories? [y/N]: "; then INSTALL_DOCKER=yes; mark_explicit INSTALL_DOCKER; fi ;;
    esac
    case " $EXPLICIT " in
        *" INSTALL_TAILSCALE "*) : ;;
        *) if read_answer "Install Tailscale from the Alpine repositories? [y/N]: "; then INSTALL_TAILSCALE=yes; mark_explicit INSTALL_TAILSCALE; fi ;;
    esac
    case " $EXPLICIT " in
        *" SKIP_UPGRADE "*) : ;;
        *)
            if read_answer "Run a full 'apk upgrade' now (upgrades ALL packages)? [y/N]: "; then
                SKIP_UPGRADE=no
            else
                SKIP_UPGRADE=yes
            fi
            mark_explicit SKIP_UPGRADE
            ;;
    esac
    return 0
}

# ------------------------------------------------------------
# Reporting
# ------------------------------------------------------------
print_config() {
    printf 'MODE=%s\n' "$MODE"
    printf 'INSTALL_DOCKER=%s\n' "$INSTALL_DOCKER"
    printf 'INSTALL_TAILSCALE=%s\n' "$INSTALL_TAILSCALE"
    printf 'SKIP_UPGRADE=%s\n' "$SKIP_UPGRADE"
    printf 'MANAGE_SSH=%s\n' "$MANAGE_SSH"
    printf 'SKIP_FIREWALL=%s\n' "$SKIP_FIREWALL"
    printf 'INSTALL_FAIL2BAN=%s\n' "$INSTALL_FAIL2BAN"
    printf 'INSTALL_AUTO_UPDATES=%s\n' "$INSTALL_AUTO_UPDATES"
}

print_inventory() {
    printf 'READ-ONLY INVENTORY — no configuration is changed\n'
    printf 'OS: %s (ID=%s VERSION_ID=%s); architecture: %s\n' \
        "${DD_PRETTY:-unknown}" "${DD_ID:-unknown}" "${DD_VER:-unknown}" "$(uname -m)"
    if command -v apk >/dev/null 2>&1; then
        printf 'apk: available (%s)\n' "$(command -v apk)"
    else
        printf 'apk: NOT FOUND\n'
    fi
    printf 'Package docker:             %s\n' "$(pkg_state docker)"
    printf 'Package docker-cli-compose: %s\n' "$(pkg_state docker-cli-compose)"
    printf 'Package tailscale:          %s\n' "$(pkg_state tailscale)"
    print_svc_line docker
    print_svc_line tailscale
    if [ -e /etc/docker/daemon.json ]; then
        printf 'Configuration exists: /etc/docker/daemon.json (contents not collected)\n'
    fi
    printf 'SSH/firewall/Fail2Ban/auto-updates: PRESERVED by design; never inspected for modification\n'
    printf 'Public exposure and VPN reachability: UNKNOWN (not inferred)\n'
    return 0
}

print_plan() {
    pp_title=" ALPINE ONBOARDING PLAN"
    if [ "$DRY_RUN" = yes ]; then
        pp_title="$pp_title (DRY-RUN — nothing will be changed)"
    fi
    echo "============================================================"
    echo "$pp_title"
    echo "============================================================"
    printf 'Mode: %s\n' "${MODE:-<unset; informational only on this backend>}"
    if [ "$INSTALL_DOCKER" = yes ]; then
        printf 'Docker + Compose:  install via apk; rc-update add docker default; start if not running\n'
    else
        printf 'Docker + Compose:  PRESERVE (nothing installed or touched)\n'
    fi
    if [ "$INSTALL_TAILSCALE" = yes ]; then
        printf 'Tailscale:         install via apk; rc-update add tailscale default; start if not running\n'
    else
        printf 'Tailscale:         PRESERVE (nothing installed or touched)\n'
    fi
    if [ "$SKIP_UPGRADE" = yes ]; then
        printf 'apk upgrade:       skipped (preserve)\n'
    else
        printf 'apk upgrade:       full upgrade requested\n'
    fi
    printf 'SSH/firewall/Fail2Ban/auto-updates: PRESERVED (unsupported by design; zero changes)\n'
    return 0
}

# ------------------------------------------------------------
# Apply path
# ------------------------------------------------------------
build_package_list() {
    APK_PKGS=""
    if [ "$INSTALL_DOCKER" = yes ] && [ "$INSTALL_TAILSCALE" = yes ]; then
        APK_PKGS="openrc docker docker-cli-compose docker-openrc tailscale tailscale-openrc"
    elif [ "$INSTALL_DOCKER" = yes ]; then
        APK_PKGS="openrc docker docker-cli-compose docker-openrc"
    elif [ "$INSTALL_TAILSCALE" = yes ]; then
        APK_PKGS="openrc tailscale tailscale-openrc"
    fi
    return 0
}

ensure_service() {
    svc_exists "$1" || [ "$DRY_RUN" = yes ] || die 1 "Init script /etc/init.d/$1 is missing after package installation; aborting."
    if svc_enabled "$1"; then
        info "Service $1 already in runlevel default; leaving runlevel configuration unchanged."
    else
        run rc-update add "$1" default
    fi
    if svc_running "$1"; then
        info "Service $1 already running; not restarted."
    else
        run rc-service "$1" start
    fi
    return 0
}

require_booted_openrc() {
    if [ -n "$APK_PKGS" ] && [ "$DRY_RUN" != yes ] && [ ! -e /run/openrc/softlevel ]; then
        die 3 "No booted OpenRC system detected (/run/openrc/softlevel missing). Refusing to install or start services; nothing was changed. Run this on a booted Alpine 3.24.x system."
    fi
}

apply_changes() {
    build_package_list
    if [ -z "$APK_PKGS" ] && [ "$SKIP_UPGRADE" = yes ]; then
        info "Nothing to do: every component is preserved; zero mutating commands will run."
        return 0
    fi
    require_booted_openrc
    run apk update
    if [ "$SKIP_UPGRADE" = no ]; then
        run apk upgrade
    fi
    if [ -n "$APK_PKGS" ]; then
        # shellcheck disable=SC2086
        run apk add $APK_PKGS
        if [ "$INSTALL_DOCKER" = yes ]; then
            ensure_service docker
        fi
        if [ "$INSTALL_TAILSCALE" = yes ]; then
            ensure_service tailscale
        fi
    fi
    return 0
}

verify_installation() {
    if [ -z "$APK_PKGS" ]; then
        return 0
    fi
    # shellcheck disable=SC2086
    for vi_pkg in $APK_PKGS; do
        apk info -e "$vi_pkg" >/dev/null 2>&1 || die 1 "Verification failed: package $vi_pkg is not installed."
    done
    if [ "$INSTALL_DOCKER" = yes ]; then
        svc_running docker || die 1 "Verification failed: service docker is not running after start."
    fi
    if [ "$INSTALL_TAILSCALE" = yes ]; then
        svc_running tailscale || die 1 "Verification failed: service tailscale is not running after start."
    fi
    return 0
}

final_notes() {
    if [ "$INSTALL_TAILSCALE" = yes ]; then
        info "Tailscale is installed and its service started; authentication is manual: run 'tailscale up' as root (never automated by this script)."
    fi
    info "No SSH, firewall, Fail2Ban or auto-update policy was configured by this backend."
    if [ "$SKIP_UPGRADE" = no ]; then
        warn "Full apk upgrade was requested: it may also upgrade preserved services and run their package scripts."
    fi
    if [ "$LOG_ENABLED" = yes ]; then
        info "Log written to $LOG_FILE."
    fi
    return 0
}

require_root() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    die 3 "Root privileges are required to apply changes. Run as root (or use configured doas/sudo), or use --dry-run / --inspect without root."
}

open_log() {
    if [ "$DRY_RUN" = yes ]; then
        return 0
    fi
    ol_umask=$(umask)
    umask 077
    if : >>"$LOG_FILE" 2>/dev/null; then
        LOG_ENABLED=yes
    else
        warn "Cannot write log file $LOG_FILE; continuing without a file log."
    fi
    umask "$ol_umask"
    return 0
}

# ------------------------------------------------------------
# Entry point
# ------------------------------------------------------------
main() {
    scan_configs "$@"
    parse_args "$@"

    if [ "$PRINT_VERSION" = yes ]; then
        printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"
        exit 0
    fi
    if [ "$PRINT_HELP" = yes ]; then
        usage
        exit 0
    fi
    if [ "$PRINT_CONFIG" = yes ]; then
        print_config
        exit 0
    fi

    guard_ds_overrides
    validate_selection

    if [ "$INSPECT" = yes ]; then
        detect_distro
        print_inventory
        exit 0
    fi

    run_wizard
    detect_distro
    build_package_list
    # Repositories gate apk upgrade too, even with no package installs.
    if [ -n "$APK_PKGS" ] || [ "$SKIP_UPGRADE" = no ]; then
        check_repositories
    fi

    # An all-preserved selection exits here: no root, no log, no
    # confirmation, zero mutating commands — even as non-root.
    if [ -z "$APK_PKGS" ] && [ "$SKIP_UPGRADE" = yes ]; then
        print_plan
        info "Nothing to do: every component is preserved; zero mutating commands run."
        exit 0
    fi

    if [ "$DRY_RUN" = yes ]; then
        info "Dry-run: printing the plan only; nothing below mutates anything."
        print_plan
        apply_changes
        info "Dry-run complete; nothing was changed."
        exit 0
    fi

    require_root
    require_booted_openrc
    print_plan

    if [ "$NONINTERACTIVE" != yes ]; then
        if ! read_answer "Apply this configuration now? [y/N]: "; then
            log_write INFO "Cancelled by user before any mutation."
            info "Cancelled; nothing was changed."
            exit 0
        fi
    fi

    open_log
    log_write INFO "Start $SCRIPT_NAME $VERSION (pid $$)"
    apply_changes
    verify_installation
    final_notes
    log_write INFO "Completed successfully."
}

# Source guard: run main() only when executed as this script; when
# sourced by unit tests, nothing executes.
case "${0##*/}" in
    "$SCRIPT_NAME") main "$@" ;;
esac
