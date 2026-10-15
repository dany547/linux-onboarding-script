#!/usr/bin/env bash
# Teste unitare pentru debian-setup.sh — rulează ca non-root, fără rețea.
# Usage: bash tests/run.sh
# shellcheck disable=SC1090,SC2034  # surse dinamice ($SCRIPT) și var asignate pt. subshell-uri
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1   # caile relative din examples/ (SSH_KEY_FILE) se rezolva predictibil
SCRIPT="$ROOT/debian-setup.sh"
FIXTURES="$ROOT/tests/fixtures"

# F6: suita e ermetică — nu moștenește DS_* și variabilele de configurare din
# mediul apelant (regresie: rularea cu DS_ROOT_OK=1 exportat trebuie să treacă).
# Numele trebuie ținute în sync cu CONFIG_KEYS din debian-setup.sh
# (testul „Curățenie: flag-uri/CONFIG_KEYS/--print-config” verifică perechile).
while IFS= read -r c6_v; do
    if [[ "$c6_v" != "DS_TEST" ]]; then
        unset "$c6_v" 2>/dev/null || true
    fi
done < <(compgen -e | grep '^DS_' || true)
for c6_v in MODE LAN_CIDR WIREGUARD_CIDR WIREGUARD_IFACE TAILSCALE_CIDR \
    TAILSCALE_IPV6_CIDR INSTALL_DOCKER INSTALL_TAILSCALE INSTALL_FAIL2BAN \
    INSTALL_AUTO_UPDATES RESET_FIREWALL SKIP_UPGRADE ALLOW_CURRENT_SSH \
    DOCKER_CONFIG DOCKER_POOL DOCKER_BIND_LOCALHOST DOCKER_USER CREATE_USER \
    SSH_KEY_FILE SSH_KEY SSH_KEYS_ONLY ALLOW_USERS SUDO_NOPASSWD AUTO_REBOOT \
    MAIL_ADDR UPDATE_THIRD_PARTY; do
    unset "$c6_v" 2>/dev/null || true
done
export DS_TEST=1

PASS=0
FAIL=0
TMP_RUN="$(mktemp -d)"
trap 'rm -rf "$TMP_RUN"' EXIT

# încarcă funcțiile scriptului pentru testele directe; guard-ul de sourcing
# nu are efecte laterale în afară de variabile și `set -Eeuo pipefail`,
# pe care le relaxăm ca testele să poată verifica coduri de eroare.
# shellcheck source=../debian-setup.sh
source "$SCRIPT"
set +e
set +o pipefail

t_pass() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

# rulează comanda în subshell; verifică codul de ieșire
expect_rc() { # descriere cod_asteptat comanda...
    local desc="$1" want="$2"
    shift 2
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "$got" == "$want" ]]; then
        t_pass "$desc"
    else
        t_fail "$desc (exit $got, așteptat $want)"
    fi
}

# verifică perechea (ieșire, cod) produsă de un subshell
check_sub() { # descriere want_out want_rc got_out got_rc
    local desc="$1" want_out="$2" want_rc="$3" got_out="$4" got_rc="$5"
    if [[ "$got_out" == "$want_out" && "$got_rc" == "$want_rc" ]]; then
        t_pass "$desc"
    else
        t_fail "$desc (primit rc=$got_rc out=«$got_out», așteptat rc=$want_rc out=«$want_out»)"
    fi
}

# subshell care încarcă scriptul și apelează detect_distro pe un fixture;
# iese cu codul lui die în caz de refuz
detect_in_sub() { # fixture
    source "$SCRIPT"
    DS_OS_RELEASE="$FIXTURES/$1"
    detect_distro >/dev/null 2>&1
    printf '%s|%s' "${DISTRO:-}" "${CODENAME:-}"
}

# subshell pentru parse_args (poate apela die)
run_in_sub() { # funcție de test definită mai jos
    source "$SCRIPT"
    "$@"
}

contains() { # text_text subșir
    printf '%s' "$1" | grep -qF -- "$2"
}

line_of() { # text_text subșir → prima linie sau 0
    printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1
}

# ============================================================
echo "== valid_cidr =="
expect_rc "IPv4 simplu" 0 valid_cidr 192.168.1.0/24
expect_rc "IPv4 /8" 0 valid_cidr 10.0.0.0/8
expect_rc "octet cu zero în față (08) e baza 10, nu octal" 0 valid_cidr 192.168.008.0/24
expect_rc "prefix cu zero în față (/08)" 0 valid_cidr 10.0.0.0/08
expect_rc "octet 010 = 10 în baza 10" 0 valid_cidr 10.0.010.0/24
expect_rc "IPv6 Tailscale" 0 valid_cidr fd7a:115c:a1e0::/48
expect_rc "IPv6 /128" 0 valid_cidr 2001:db8::1/128
expect_rc "octet 256 refuzat" 1 valid_cidr 192.168.1.256/24
expect_rc "prefix /33 refuzat" 1 valid_cidr 192.168.1.0/33
expect_rc "prefix IPv6 /129 refuzat" 1 valid_cidr fd7a:115c:a1e0::/129
expect_rc "fără prefix refuzat" 1 valid_cidr 192.168.1.0
expect_rc "text aleator refuzat" 1 valid_cidr lan
expect_rc "gol refuzat" 1 valid_cidr ""

# ============================================================
echo "== ip_in_cidr =="
if command -v python3 >/dev/null 2>&1; then
    expect_rc "10.0.0.5 în 10.0.0.0/24" 0 ip_in_cidr 10.0.0.5 10.0.0.0/24
    expect_rc "192.168.1.5 NU e în 10.0.0.0/24" 1 ip_in_cidr 192.168.1.5 10.0.0.0/24
    expect_rc "100.64.1.2 în 100.64.0.0/10" 0 ip_in_cidr 100.64.1.2 100.64.0.0/10
    expect_rc "adresă invalidă" 1 ip_in_cidr 10.0.0.999 10.0.0.0/24
    expect_rc "CIDR invalid" 1 ip_in_cidr 10.0.0.5 10.0.0.0/33
else
    printf 'SKIP ip_in_cidr (python3 lipsește)\n'
fi

# ============================================================
echo "== detect_distro (layer distro) =="
out="$(detect_in_sub os-release.debian12)"; rc=$?
check_sub "debian12 → debian/bookworm" "debian|bookworm" 0 "$out" "$rc"

out="$(detect_in_sub os-release.debian13)"; rc=$?
check_sub "debian13 → debian/trixie" "debian|trixie" 0 "$out" "$rc"

out="$(detect_in_sub os-release.ubuntu22.04)"; rc=$?
check_sub "ubuntu22.04 → ubuntu/jammy" "ubuntu|jammy" 0 "$out" "$rc"

out="$(detect_in_sub os-release.ubuntu24.04)"; rc=$?
check_sub "ubuntu24.04 → ubuntu/noble" "ubuntu|noble" 0 "$out" "$rc"

out="$(detect_in_sub os-release.linuxmint)"; rc=$?
check_sub "linuxmint (ID_LIKE ubuntu) → ubuntu/jammy" "ubuntu|jammy" 0 "$out" "$rc"

out="$(detect_in_sub os-release.raspbian)"; rc=$?
check_sub "raspbian (ID_LIKE debian) → debian/bookworm" "debian|bookworm" 0 "$out" "$rc"

out="$(detect_in_sub os-release.arch)"; rc=$?
check_sub "arch refuzat cu exit 3" "" 3 "$out" "$rc"

out="$(detect_in_sub os-release.rocky)"; rc=$?
check_sub "rocky refuzat cu exit 3" "" 3 "$out" "$rc"

out="$(detect_in_sub os-release.debian11)"; rc=$?
check_sub "debian11 refuzat cu exit 3" "" 3 "$out" "$rc"

# URL-uri și origini de securitate din layer-ul distro
detect_layer() { # fixture
    source "$SCRIPT"
    DS_OS_RELEASE="$FIXTURES/$1"
    detect_distro >/dev/null 2>&1
    printf '%s\n%s\n%s' "$DOCKER_REPO_URL" "$TAILSCALE_REPO_URL" "${SECURITY_ORIGINS[0]}"
}

out="$(detect_layer os-release.debian12)"; rc=$?
check_sub "URL-uri debian12" \
    "https://download.docker.com/linux/debian
https://pkgs.tailscale.com/stable/debian
origin=Debian,codename=bookworm,label=Debian-Security" 0 "$out" "$rc"

out="$(detect_layer os-release.ubuntu24.04)"; rc=$?
check_sub "URL-uri ubuntu24.04" \
    "https://download.docker.com/linux/ubuntu
https://pkgs.tailscale.com/stable/ubuntu
origin=Ubuntu,archive=noble-security,label=Ubuntu" 0 "$out" "$rc"

# idempotență: a doua detecție dă aceleași valori
out="$(
    source "$SCRIPT"
    DS_OS_RELEASE="$FIXTURES/os-release.debian12"
    detect_distro >/dev/null 2>&1
    detect_distro >/dev/null 2>&1
    printf '%s|%s' "$DISTRO" "$CODENAME"
)"; rc=$?
check_sub "detect_distro idempotent" "debian|bookworm" 0 "$out" "$rc"

# ============================================================
echo "== parse_args =="
case_flags() { parse_args -y --mode vps --lan-cidr 10.0.0.0/24 --skip-upgrade; printf '%s|%s|%s|%s' "$MODE" "$NONINTERACTIVE" "$LAN_CIDR" "$SKIP_UPGRADE"; }
out="$(run_in_sub case_flags)"; rc=$?
check_sub "parse_args: flag-uri de bază" "vps|yes|10.0.0.0/24|yes" 0 "$out" "$rc"

case_noval() { parse_args --mode; }
out="$(run_in_sub case_noval)"; rc=$?
check_sub "parse_args: --mode fără valoare → exit 2" "" 2 "$out" "$rc"

case_unknown() { parse_args --nu-există; }
out="$(run_in_sub case_unknown)"; rc=$?
check_sub "parse_args: opțiune necunoscută → exit 2" "" 2 "$out" "$rc"

case_badmode() { parse_args --mode banana; printf '%s' "$MODE"; }
out="$(run_in_sub case_badmode)"; rc=$?
check_sub "parse_args: --mode acceptă sintactic orice, validarea e în preflight" "banana" 0 "$out" "$rc"

case_dryrun() { parse_args --dry-run --no-docker; printf '%s|%s' "$DRY_RUN" "$INSTALL_DOCKER"; }
out="$(run_in_sub case_dryrun)"; rc=$?
check_sub "parse_args: --dry-run --no-docker" "yes|no" 0 "$out" "$rc"

cat >"$TMP_RUN/good.conf" <<'EOF'
# config de test
MODE=vps
LAN_CIDR=10.10.0.0/24
INSTALL_DOCKER=no
EOF

case_config_ok() { parse_args --config "$TMP_RUN/good.conf"; printf '%s|%s|%s' "$MODE" "$LAN_CIDR" "$INSTALL_DOCKER"; }
out="$(run_in_sub case_config_ok)"; rc=$?
check_sub "parse_args: --config cu chei permise" "vps|10.10.0.0/24|no" 0 "$out" "$rc"

case_config_cli_wins() { parse_args --config "$TMP_RUN/good.conf" --mode lan; printf '%s' "$MODE"; }
out="$(run_in_sub case_config_cli_wins)"; rc=$?
check_sub "parse_args: CLI suprascrie config-ul" "lan" 0 "$out" "$rc"

cat >"$TMP_RUN/badkey.conf" <<'EOF'
MODE=vps
EVIL_KEY=1
EOF
case_config_badkey() { parse_args --config "$TMP_RUN/badkey.conf"; }
out="$(run_in_sub case_config_badkey)"; rc=$?
check_sub "parse_args: cheie nepermisă în config → exit 2" "" 2 "$out" "$rc"

cat >"$TMP_RUN/badval.conf" <<'EOF'
MODE=saturn
EOF
case_config_badval() { parse_args --config "$TMP_RUN/badval.conf"; }
out="$(run_in_sub case_config_badval)"; rc=$?
check_sub "parse_args: valoare MODE invalidă în config → exit 2" "" 2 "$out" "$rc"

cat >"$TMP_RUN/badline.conf" <<'EOF'
linie fără egal
EOF
case_config_badline() { parse_args --config "$TMP_RUN/badline.conf"; }
out="$(run_in_sub case_config_badline)"; rc=$?
check_sub "parse_args: linie fără KEY=value → exit 2" "" 2 "$out" "$rc"

case_config_missing() { parse_args --config "$TMP_RUN/nu-există.conf"; }
out="$(run_in_sub case_config_missing)"; rc=$?
check_sub "parse_args: fișier config lipsă → exit 2" "" 2 "$out" "$rc"

case_config_noval() { parse_args --config; }
out="$(run_in_sub case_config_noval)"; rc=$?
check_sub "parse_args: --config fără valoare → exit 2" "" 2 "$out" "$rc"

case_cidr_override() { parse_args --config "$TMP_RUN/good.conf" --lan-cidr 192.168.0.0/16; printf '%s' "$LAN_CIDR"; }
out="$(run_in_sub case_cidr_override)"; rc=$?
check_sub "parse_args: --lan-cidr suprascrie config-ul" "192.168.0.0/16" 0 "$out" "$rc"

# ============================================================
echo "== run() / write_file() cu dry-run =="
out="$(
    source "$SCRIPT"
    DRY_RUN=yes
    run apt-get update 2>/dev/null
)"; rc=$?
plain_out="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
if [[ "$rc" == "0" ]] && contains "$plain_out" "apt-get update" && contains "$plain_out" "DRY-RUN"; then
    t_pass "run() dry-run: tipărește comanda, nu o execută"
else
    t_fail "run() dry-run: tipărește comanda, nu o execută"
fi

out="$(
    source "$SCRIPT"
    DRY_RUN=yes
    printf 'linie1\nlinie2\n' | write_file "$TMP_RUN/plan.conf" 0644
)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "linie2" && [[ ! -e "$TMP_RUN/plan.conf" ]]; then
    t_pass "write_file() dry-run: afișează conținutul, nu creează fișierul"
else
    t_fail "write_file() dry-run: afișează conținutul, nu creează fișierul"
fi

out="$(
    source "$SCRIPT"
    DRY_RUN=no
    printf 'conținut real\n' | write_file "$TMP_RUN/real.conf" 0600
)"; rc=$?
if [[ "$rc" == "0" && -f "$TMP_RUN/real.conf" && "$(stat -c %a "$TMP_RUN/real.conf" 2>/dev/null)" == "600" ]] \
    && [[ "$(cat "$TMP_RUN/real.conf")" == "conținut real" ]]; then
    t_pass "write_file() real: scrie fișierul cu modul cerut"
else
    t_fail "write_file() real: scrie fișierul cu modul cerut"
fi

# ============================================================
echo "== subprocess: --version, --help, --print-config, dry-run =="
out="$(bash "$SCRIPT" --version)"; rc=$?
check_sub "--version" "debian-setup.sh $VERSION" 0 "$out" "$rc"

out="$(bash "$SCRIPT" --help)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "--dry-run" && contains "$out" "--config FILE"; then
    t_pass "--help: listează flag-urile noi"
else
    t_fail "--help: listează flag-urile noi"
fi

out="$(bash "$SCRIPT" --print-config --config "$TMP_RUN/good.conf")"; rc=$?
if [[ "$rc" == "0" ]] \
    && printf '%s\n' "$out" | grep -qx 'MODE=vps' \
    && printf '%s\n' "$out" | grep -qx 'LAN_CIDR=10.10.0.0/24' \
    && printf '%s\n' "$out" | grep -qx 'INSTALL_DOCKER=no' \
    && printf '%s\n' "$out" | grep -qx 'ALLOW_CURRENT_SSH=no'; then
    t_pass "--print-config: tipărește configurația efectivă"
else
    t_fail "--print-config: tipărește configurația efectivă"
fi

expect_rc "non-root fără DS_ROOT_OK → exit 3" 3 \
    env DS_OS_RELEASE="$FIXTURES/os-release.debian12" bash "$SCRIPT" --dry-run -y --mode lan

expect_rc "fixture arch → exit 3" 3 \
    env DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.arch" bash "$SCRIPT" --dry-run -y --mode lan

expect_rc "fixture rocky → exit 3" 3 \
    env DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.rocky" bash "$SCRIPT" --dry-run -y --mode lan

# guard pveversion (Proxmox) — cu un fals în PATH
mkdir -p "$TMP_RUN/bin-pve"
printf '#!/bin/sh\nexit 0\n' >"$TMP_RUN/bin-pve/pveversion"
chmod +x "$TMP_RUN/bin-pve/pveversion"
# mock systemd-detect-virt (nu container) — folosit de testele de lockout și de smoke
mkdir -p "$TMP_RUN/bin-novirt"
printf '#!/bin/sh\nexit 1\n' >"$TMP_RUN/bin-novirt/systemd-detect-virt"
chmod +x "$TMP_RUN/bin-novirt/systemd-detect-virt"
expect_rc "pveversion în PATH → exit 3" 3 \
    env PATH="$TMP_RUN/bin-pve:$PATH" DS_ROOT_OK=1 \
    DS_OS_RELEASE="$FIXTURES/os-release.debian12" bash "$SCRIPT" --dry-run -y --mode lan

# sesiune SSH (prin DS_SSH_SOURCE) neacoperită → risc de lockout.
# F2: în dry-run e doar warn (rc 0); exit 4 se verificate unitar, cu -y, sub
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" \
    DS_SSH_SOURCE=203.0.113.7 DS_ROOT_OK=1 \
    DS_OS_RELEASE="$FIXTURES/os-release.debian12" bash "$SCRIPT" --dry-run -y --mode lan \
    --lan-cidr 192.168.1.0/24 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" 'se cere confirmare explicită sau --allow-current-ssh'; then
    t_pass "F2: sesiune SSH neacoperită în dry-run → warn, rc 0"
else
    t_fail "F2: sesiune SSH neacoperită în dry-run → warn, rc 0 (rc=$rc)"
fi

out="$(
    source "$SCRIPT"
    DRY_RUN=no NONINTERACTIVE=yes ALLOW_CURRENT_SSH=no SKIP_FIREWALL=no UNCOVERED_PEERS=
    SSH_SOURCE_IP=203.0.113.7
    SSH_CIDRS=(192.168.1.0/24)
    check_current_session_allowed 2>/dev/null
    printf 'OK'
)"; rc=$?
check_sub "F2: sesiune SSH neacoperită (-y, rulare reală) → exit 4" "" 4 "$out" "$rc"

expect_rc "sesiune SSH acoperită cu --allow-current-ssh → exit 0" 0 \
    env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" \
    DS_SSH_SOURCE=203.0.113.7 DS_ROOT_OK=1 \
    DS_OS_RELEASE="$FIXTURES/os-release.debian12" bash "$SCRIPT" --dry-run -y --mode lan \
    --lan-cidr 192.168.1.0/24 --allow-current-ssh

# ============================================================
echo "== B1: detecție sesiune SSH (matrice mock) =="
# mock-uri: ss/who/sshd/systemctl citesc fixture-uri prin variabile FAKE_*
mkdir -p "$TMP_RUN/mocks"
cat >"$TMP_RUN/mocks/fake-ss" <<'EOF'
#!/bin/sh
# ignoră argumentele ss; emite ce e în FAKE_SS_FILE
[ -n "$FAKE_SS_FILE" ] && cat "$FAKE_SS_FILE"
exit 0
EOF
cat >"$TMP_RUN/mocks/fake-who" <<'EOF'
#!/bin/sh
[ -n "$FAKE_WHO_FILE" ] && cat "$FAKE_WHO_FILE"
exit 0
EOF
cat >"$TMP_RUN/mocks/fake-sshd" <<'EOF'
#!/bin/sh
[ -n "$FAKE_SSHD_FILE" ] && cat "$FAKE_SSHD_FILE"
exit 0
EOF
cat >"$TMP_RUN/mocks/fake-systemctl" <<'EOF'
#!/bin/sh
# is-active --quiet ssh.socket → codul din FAKE_SYSTEMCTL_ACTIVE
exit "${FAKE_SYSTEMCTL_ACTIVE:-1}"
EOF
# nu suntem într-un container (determinism pentru UFW/Fail2Ban în dry-run)
printf '#!/bin/sh\nexit 1\n' >"$TMP_RUN/mocks/systemd-detect-virt"
chmod +x "$TMP_RUN/mocks/"*

printf 'ESTAB 0 0 10.100.10.13:22 198.51.100.7:52344 users:(("sshd",pid=4242,fd=3))\n' >"$TMP_RUN/ss-withpid"
printf 'ESTAB 0 0 10.100.10.13:22 203.0.113.55:50000\n' >"$TMP_RUN/ss-nopid-one"
printf 'ESTAB 0 0 10.100.10.13:22 203.0.113.55:50000\nESTAB 0 0 10.100.10.13:22 198.51.100.7:51000\n' >"$TMP_RUN/ss-nopid-two"
printf 'port 2222\npermitrootlogin no\n' >"$TMP_RUN/sshd-t-2222"
printf 'dan     pts/0        2026-09-29 09:00 (192.0.2.77)\n' >"$TMP_RUN/who-ip"

# 1) env lipsă + fără sesiune SSH → rulează normal, fără IP detectat
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" DS_SSH_CHAIN=none \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "Sesiune SSH detectată:   no" && ! contains "$out" "SSH curent din"; then
    t_pass "B1: env lipsă, fără sesiune SSH → exit 0, fără IP"
else
    t_fail "B1: env lipsă, fără sesiune SSH → exit 0, fără IP (rc=$rc)"
fi

# 2) DS_SSH_SOURCE are prioritate
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" DS_SSH_CHAIN=none \
    DS_SSH_SOURCE=203.0.113.9 DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 203.0.113.0/24 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "SSH curent din:          203.0.113.9" \
    && contains "$out" "Sesiune SSH detectată:   yes"; then
    t_pass "B1: DS_SSH_SOURCE → IP sesiune detectat"
else
    t_fail "B1: DS_SSH_SOURCE → IP sesiune detectat (rc=$rc)"
fi

# 3) sub-sudo simulat: sshd în lanț (DS_SSHD_PID) + IP din ss (pid potrivit) + port din sshd -T
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" \
    DS_SSHD_PID=4242 DS_CMD_SS="$TMP_RUN/mocks/fake-ss" FAKE_SS_FILE="$TMP_RUN/ss-withpid" \
    DS_CMD_SSHD="$TMP_RUN/mocks/fake-sshd" FAKE_SSHD_FILE="$TMP_RUN/sshd-t-2222" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 198.51.100.0/24 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "SSH curent din:          198.51.100.7" \
    && contains "$out" "to any port 2222" && contains "$out" "port = 2222"; then
    t_pass "B1/B6: sudo simulat → IP din ss + port 2222 din sshd -T"
else
    t_fail "B1/B6: sudo simulat → IP din ss + port 2222 din sshd -T (rc=$rc)"
fi

# 4) sshd în lanț, IP necunoscut → exit 4 cu instrucțiuni
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" \
    DS_SSHD_PID=4242 DS_CMD_SS="$TMP_RUN/mocks/fake-ss" DS_CMD_WHO="$TMP_RUN/mocks/fake-who" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 2>&1)"; rc=$?
if [[ "$rc" == "4" ]] && contains "$out" "DS_SSH_SOURCE" && contains "$out" "--allow-current-ssh"; then
    t_pass "B1: sshd în lanț, IP necunoscut → exit 4 cu instrucțiuni"
else
    t_fail "B1: sshd în lanț, IP necunoscut → exit 4 cu instrucțiuni (rc=$rc)"
fi

# 5) sub-sudo, sesiune neacoperită: dry-run → warn (rc 0); -y real → exit 4 (unit mai jos)
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" \
    DS_SSHD_PID=4242 DS_CMD_SS="$TMP_RUN/mocks/fake-ss" FAKE_SS_FILE="$TMP_RUN/ss-withpid" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" 'se cere confirmare explicită sau --allow-current-ssh'; then
    t_pass "B1/F2: sub-sudo, sesiune neacoperită, dry-run → warn + rc 0"
else
    t_fail "B1/F2: sub-sudo, sesiune neacoperită, dry-run → warn + rc 0 (rc=$rc)"
fi
expect_rc "B1: sub-sudo + --allow-current-ssh (fără env SSH) → exit 0" 0 \
    env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" \
    DS_SSHD_PID=4242 DS_CMD_SS="$TMP_RUN/mocks/fake-ss" FAKE_SS_FILE="$TMP_RUN/ss-withpid" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --allow-current-ssh

# 6) fallback ss fără PID, o singură conexiune → IP unic acceptat
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" \
    DS_SSHD_PID=4242 DS_CMD_SS="$TMP_RUN/mocks/fake-ss" FAKE_SS_FILE="$TMP_RUN/ss-nopid-one" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 203.0.113.0/24 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "SSH curent din:          203.0.113.55"; then
    t_pass "B1: ss fără PID, conexiune unică → IP detectat"
else
    t_fail "B1: ss fără PID, conexiune unică → IP detectat (rc=$rc)"
fi

# 7) două conexiuni fără PID → ambiguu → exit 4
expect_rc "B1: ss fără PID, conexiuni multiple → exit 4" 4 \
    env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" \
    DS_SSHD_PID=4242 DS_CMD_SS="$TMP_RUN/mocks/fake-ss" FAKE_SS_FILE="$TMP_RUN/ss-nopid-two" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24

# 8) fallback who -m
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" \
    DS_SSHD_PID=4242 DS_CMD_SS="$TMP_RUN/mocks/fake-ss" DS_CMD_WHO="$TMP_RUN/mocks/fake-who" \
    FAKE_WHO_FILE="$TMP_RUN/who-ip" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.0.2.0/24 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "SSH curent din:          192.0.2.77"; then
    t_pass "B1: fallback who -m → IP detectat"
else
    t_fail "B1: fallback who -m → IP detectat (rc=$rc)"
fi

# 9) _proc_comm/_proc_ppid pe PID-ul propriu
out="$(
    source "$SCRIPT"
    printf '%s|%s' "$(_proc_comm "$$")" "$(_proc_ppid "$$" | tr -d '[:space:]')"
)"; rc=$?
ppid_val="${out#*|}"
if [[ "$rc" == "0" && "${out%%|*}" == "bash" && "$ppid_val" =~ ^[0-9]+$ ]]; then
    t_pass "B1: _proc_comm/_proc_ppid funcționează pe /proc"
else
    t_fail "B1: _proc_comm/_proc_ppid funcționează pe /proc (out=«$out»)"
fi

# ============================================================
echo "== log în fișier (fără ANSI, umask 077) =="
out="$(
    source "$SCRIPT"
    DRY_RUN=no
    LOG_FILE="$TMP_RUN/test.log"
    open_log
    info "mesaj de test"
    warn "avertisment de test"
    log_write INFO "final"
    printf '%s' "$LOG_FD"
)"; rc=$?
if [[ "$rc" == "0" && -n "$out" \
    && -f "$TMP_RUN/test.log" \
    && "$(stat -c %a "$TMP_RUN/test.log" 2>/dev/null)" == "600" \
    && ! "$(cat "$TMP_RUN/test.log")" == *$'\033'* \
    && "$(cat "$TMP_RUN/test.log")" == *"mesaj de test"* \
    && "$(cat "$TMP_RUN/test.log")" == *"avertisment de test"* ]]; then
    t_pass "log: scris fără ANSI, permisiuni 0600"
else
    t_fail "log: scris fără ANSI, permisiuni 0600"
fi

# în dry-run logul nu se deschide deloc
out="$(
    source "$SCRIPT"
    DRY_RUN=yes
    LOG_FILE="$TMP_RUN/test-dry.log"
    open_log
    log_write INFO "doar plan"
    printf '%s' "$LOG_FD"
)"
if [[ -z "$out" && ! -e "$TMP_RUN/test-dry.log" ]]; then
    t_pass "log: în dry-run nu se scrie"
else
    t_fail "log: în dry-run nu se scrie"
fi

# ------------------------------------------------------------
echo "== dry-run smoke (debian12, lan, full plan) =="
# mediul de dezvoltare e un LXC neprivilegiat → detecția reală ar sări UFW/Fail2Ban
# (comportament identic cu .orig). Pentru planul complet, mock-uim systemd-detect-virt
# (mock-ul bin-novirt e creat sus, împreună cu bin-pve).
SMOKE="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan \
    --lan-cidr 192.168.1.0/24 --wireguard-cidr 10.8.0.0/24 2>&1)"
SMOKE_RC=$?
if [[ "$SMOKE_RC" == "0" ]]; then t_pass "smoke debian12: exit 0"; else t_fail "smoke debian12: exit 0 (primit $SMOKE_RC)"; fi

smoke_has() { # descriere subșir
    if contains "$SMOKE" "$2"; then t_pass "$1"; else t_fail "$1"; fi
}
smoke_has "plan: apt-get update"        "apt-get"
smoke_has "plan: full-upgrade"          "full-upgrade"
smoke_has "plan: unattended-upgrades"   "unattended-upgrades"
smoke_has "plan: 20auto-upgrades"       "20auto-upgrades"
smoke_has "plan: docker.sources"        "docker.sources"
smoke_has "plan: suites bookworm"       "Suites: bookworm"
smoke_has "plan: repo docker debian"    "https://download.docker.com/linux/debian"
smoke_has "plan: tailscale bookworm"    "bookworm.noarmor.gpg"
smoke_has "plan: sshd config"           "90-bootstrap-security.conf"
smoke_has "plan: ufw lan cidr"          "192.168.1.0/24"
smoke_has "plan: ufw wg cidr"           "10.8.0.0/24"
smoke_has "plan: ufw tailscale cidr"    "100.64.0.0/10"
smoke_has "plan: ufw enable"            "ufw --force enable"
smoke_has "plan: jail fail2ban"         "sshd-bootstrap.local"
smoke_has "B5: CIDR Tailscale v6 permanent"  "ufw allow from fd7a:115c:a1e0::/48 to any port 22"
smoke_has "B5: regulă interfață tailscale0"   "ufw allow in on tailscale0 to any port 22"
smoke_has "B6: fallback port 22"          "to any port 22"
smoke_has "B3: ignoreip din SSH_CIDRS"    "ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24 10.8.0.0/24 100.64.0.0/10 fd7a:115c:a1e0::/48"
smoke_has "C3/B4: docker.sources Signed-By"   "Signed-By: /etc/apt/keyrings/docker.asc"
smoke_has "C3/B4/R2: tailscale.sources scris local"  "scriu /etc/apt/sources.list.d/tailscale.sources"
smoke_has "C3/B4: cheie Tailscale încă descărcată"  "bookworm.noarmor.gpg"
smoke_has "C3/B4: info verificare fingerprint Docker"  "verific fingerprintul cheii Docker"
smoke_has "C3/B2: jail backend systemd"       "backend = systemd"
smoke_has "C3/B2: python3-systemd în pachete"  "python3-systemd"
smoke_has "C3: gnupg în pachete de bază"       "gnupg"
smoke_has "C3/U: planifică verificarea unattended"  "unattended-upgrade --dry-run --debug"
smoke_has "C3/U: origins Debian placeholder"   'origin=Debian,codename=${distro_codename},label=Debian-Security'
smoke_has "C3/U: origins Debian security placeholder"  'codename=${distro_codename}-security'
if contains "$SMOKE" "tailscale-keyring.list"; then
    t_fail "C3/B4: .list Tailscale nu se mai descarcă"
else
    t_pass "C3/B4: .list Tailscale nu se mai descarcă"
fi
if contains "$SMOKE" "/etc/docker/daemon.json" && contains "$SMOKE" "live-restore" \
    && contains "$SMOKE" "no-new-privileges"; then
    t_pass "C4: planifică merge daemon.json (log rotation, live-restore, no-new-privileges)"
else
    t_fail "C4: planifică merge daemon.json (log rotation, live-restore, no-new-privileges)"
fi
if [[ "$SMOKE_RC" == "0" ]] && ! contains "$SMOKE" "Aplic această configurație?"; then
    t_pass "fără confirmare interactivă"
else
    t_fail "fără confirmare interactivă"
fi

# ordinea planului trebuie să respecte pipeline-ul: update → docker.sources → docker install → ufw → fail2ban
ord_update=$(line_of "$SMOKE" "apt-get")
ord_repo=$(line_of "$SMOKE" "docker.sources")
ord_docker=$(line_of "$SMOKE" "docker-compose-plugin")
ord_ufw=$(line_of "$SMOKE" "ufw --force enable")
ord_f2b=$(line_of "$SMOKE" "sshd-bootstrap.local")
if (( ord_update < ord_repo && ord_repo < ord_docker && ord_docker < ord_ufw && ord_ufw < ord_f2b )); then
    t_pass "smoke debian12: ordinea pașilor corectă"
else
    t_fail "smoke debian12: ordinea pașilor corectă ($ord_update,$ord_repo,$ord_docker,$ord_ufw,$ord_f2b)"
fi

# ------------------------------------------------------------
echo "== dry-run smoke (alte distro-uri) =="
SMOKE13="$(env -u SSH_CONNECTION -u SSH_CLIENT DS_SSH_CHAIN=none DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian13" \
    bash "$SCRIPT" --dry-run -y --mode vps --skip-upgrade 2>&1)"
if [[ "$?" == "0" ]] && contains "$SMOKE13" "Suites: trixie"; then
    t_pass "smoke debian13 (vps, fără upgrade): exit 0, trixie"
else
    t_fail "smoke debian13 (vps, fără upgrade): exit 0, trixie"
fi

SMOKE_U="$(env -u SSH_CONNECTION -u SSH_CLIENT DS_SSH_CHAIN=none DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.ubuntu24.04" \
    bash "$SCRIPT" --dry-run -y --mode lan 2>&1)"
if [[ "$?" == "0" ]] && contains "$SMOKE_U" "Suites: noble" && contains "$SMOKE_U" "linux/ubuntu"; then
    t_pass "smoke ubuntu24.04: exit 0, noble + repo ubuntu"
else
    t_fail "smoke ubuntu24.04: exit 0, noble + repo ubuntu"
fi

SMOKE_M="$(env -u SSH_CONNECTION -u SSH_CLIENT DS_SSH_CHAIN=none DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.linuxmint" \
    bash "$SCRIPT" --dry-run -y --mode lan 2>&1)"
if [[ "$?" == "0" ]] && contains "$SMOKE_M" "Derivat Ubuntu detectat"; then
    t_pass "smoke linuxmint: exit 0 cu warn de derivat"
else
    t_fail "smoke linuxmint: exit 0 cu warn de derivat"
fi

SMOKE_R="$(env -u SSH_CONNECTION -u SSH_CLIENT DS_SSH_CHAIN=none DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.raspbian" \
    bash "$SCRIPT" --dry-run -y --mode lan 2>&1)"
if [[ "$?" == "0" ]] && contains "$SMOKE_R" "Derivat Debian detectat"; then
    t_pass "smoke raspbian: exit 0 cu warn de derivat"
else
    t_fail "smoke raspbian: exit 0 cu warn de derivat"
fi

# dry-run nu scrie logul: LOG_FILE nu e creat de noi (folosim un path de test prin subprocess?
# logul merge în /var/log; în dry-run open_log() se întoarce devreme — verificăm indirect:
# rulăm din nou și ne asigurăm că nu apar erori de permisiuni și că exit code rămâne 0)
SMOKE_LOG="$(env -u SSH_CONNECTION -u SSH_CLIENT DS_SSH_CHAIN=none DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && ! contains "$SMOKE_LOG" "debian-setup.log"; then
    t_pass "dry-run nu atinge logul din /var/log"
else
    t_fail "dry-run nu atinge logul din /var/log"
fi

# ============================================================
echo "== C2: B5/B6/B7, export UFW =="
# B5: --wireguard-iface se adaugă PESTE regulile existente
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 --wireguard-iface wg0 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "ufw allow in on wg0 to any port 22" \
    && contains "$out" "ufw allow in on tailscale0 to any port 22" \
    && contains "$out" "Interfață WireGuard:     wg0"; then
    t_pass "B5: --wireguard-iface wg0 → regulă adăugată peste (tailscale0 rămâne)"
else
    t_fail "B5: --wireguard-iface wg0 → regulă adăugată peste (tailscale0 rămâne) (rc=$rc)"
fi

expect_rc "B5: --wireguard-iface invalid → exit 2" 2 \
    env DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --wireguard-iface "wg 0!"

# B5: unit check_current_session_allowed — vps non-interactiv fără acoperire
out="$(
    source "$SCRIPT"
    MODE=vps DRY_RUN=no NONINTERACTIVE=yes ALLOW_CURRENT_SSH=no SKIP_FIREWALL=no
    SSH_SOURCE_IP=203.0.113.50
    SSH_CIDRS=(100.64.0.0/10 fd7a:115c:a1e0::/48)
    check_current_session_allowed 2>/dev/null
    printf 'OK'
)"; rc=$?
check_sub "B5: vps -y, sesiune neacoperită → exit 4" "" 4 "$out" "$rc"

out="$(
    source "$SCRIPT"
    MODE=vps DRY_RUN=no NONINTERACTIVE=yes ALLOW_CURRENT_SSH=yes SKIP_FIREWALL=no
    SSH_SOURCE_IP=203.0.113.50
    SSH_CIDRS=(100.64.0.0/10 fd7a:115c:a1e0::/48 203.0.113.50/32)
    check_current_session_allowed 2>/dev/null
    printf 'OK'
)"; rc=$?
check_sub "B5: vps cu --allow-current-ssh (CIDR /32) → OK" "OK" 0 "$out" "$rc"

# B5: vps dry-run → warn, nu die
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" DS_SSH_CHAIN=none \
    DS_SSH_SOURCE=203.0.113.50 DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode vps 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "se cere confirmare explicită sau --allow-current-ssh"; then
    t_pass "B5: vps dry-run, sesiune neacoperită → warn, planul continuă"
else
    t_fail "B5: vps dry-run, sesiune neacoperită → warn, planul continuă (rc=$rc)"
fi

# B6: ssh.socket activ → restart ssh.socket în loc de reload
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" DS_SSH_CHAIN=none \
    DS_CMD_SYSTEMCTL="$TMP_RUN/mocks/fake-systemctl" FAKE_SYSTEMCTL_ACTIVE=0 \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian13" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "systemctl restart ssh.socket" \
    && ! contains "$out" "systemctl reload ssh.service"; then
    t_pass "B6: ssh.socket activ → restart ssh.socket, fără reload"
else
    t_fail "B6: ssh.socket activ → restart ssh.socket, fără reload (rc=$rc)"
fi

# B6: ssh.socket inactiv → reload clasic
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" DS_SSH_CHAIN=none \
    DS_CMD_SYSTEMCTL="$TMP_RUN/mocks/fake-systemctl" FAKE_SYSTEMCTL_ACTIVE=1 \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "systemctl reload ssh.service" \
    && ! contains "$out" "restart ssh.socket"; then
    t_pass "B6: ssh.socket inactiv → reload clasic"
else
    t_fail "B6: ssh.socket inactiv → reload clasic (rc=$rc)"
fi

# B7: IPV6=yes — fixture cu IPV6=no → planifică setarea; cu IPV6=yes → idempotent (tăcut)
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_UFW_DEFAULT="$FIXTURES/ufw-default.ipv6no" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "setez IPV6=yes în $FIXTURES/ufw-default.ipv6no"; then
    t_pass "B7: IPV6=no → planifică IPV6=yes"
else
    t_fail "B7: IPV6=no → planifică IPV6=yes (rc=$rc)"
fi

out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_UFW_DEFAULT="$FIXTURES/ufw-default.ipv6yes" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && ! contains "$out" "setez IPV6=yes"; then
    t_pass "B7: IPV6=yes deja setat → idempotent, fără modificare"
else
    t_fail "B7: IPV6=yes deja setat → idempotent, fără modificare (rc=$rc)"
fi

# B7: scriere reală pe copie de test (sed pe IPV6=no existent)
rc=0
(
    source "$SCRIPT"
    DRY_RUN=no
    cp "$FIXTURES/ufw-default.ipv6no" "$TMP_RUN/ufw-default"
    DS_UFW_DEFAULT="$TMP_RUN/ufw-default"
    set_ufw_ipv6 >/dev/null 2>&1
    set_ufw_ipv6 >/dev/null 2>&1
) || rc=$?
if [[ "$rc" == "0" ]] && [[ "$(grep -c '^IPV6=yes' "$TMP_RUN/ufw-default" 2>/dev/null)" == "1" ]]; then
    t_pass "B7: set_ufw_ipv6 real → IPV6=yes, idempotent"
else
    t_fail "B7: set_ufw_ipv6 real → IPV6=yes, idempotent"
fi

# export UFW înainte de reset: status numbered + copie /etc/ufw în /var/backups/
RESET_SMOKE="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 --reset-firewall 2>&1)"; rc=$?
ord_backup=$(line_of "$RESET_SMOKE" "/var/backups/ufw-")
ord_reset=$(line_of "$RESET_SMOKE" "ufw --force reset")
if [[ "$rc" == "0" ]] \
    && contains "$RESET_SMOKE" "ufw status numbered" \
    && contains "$RESET_SMOKE" "install -d -m 0700 /var/backups/ufw-" \
    && contains "$RESET_SMOKE" "cp -a /etc/ufw" \
    && (( ord_backup > 0 && ord_reset > ord_backup )); then
    t_pass "export UFW: backup (status+copie) înainte de reset"
else
    t_fail "export UFW: backup (status+copie) înainte de reset (rc=$rc, backup=$ord_backup, reset=$ord_reset)"
fi

# ============================================================
echo "== C3: B4 chei, origini unattended, B2/B8/D1 =="
# mock-uri C3
cat >"$TMP_RUN/mocks/fake-gpg" <<'EOF'
#!/bin/sh
case "${FAKE_GPG_MODE:-valid-docker}" in
  valid-docker) printf 'pub:-:4096:1:XYZ:1700000000:::-\nfpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:\nuid:::::::::Docker Release:\n' ;;
  valid-tailscale) printf 'pub:-:4096:1:ABC:1600000000:::-\nfpr:::::::::1234ABCD5678EF901234ABCD5678EF901234ABCD:\n' ;;
  invalid) printf 'not a key\n' ;;
esac
exit 0
EOF
cat >"$TMP_RUN/mocks/fake-dpkg" <<'EOF'
#!/bin/sh
# $1 = -s, $2 = pachet
case " $FAKE_DPKG_INSTALLED " in *" $2 "*) exit 0 ;; *) exit 1 ;; esac
EOF
cat >"$TMP_RUN/mocks/snap" <<'EOF'
#!/bin/sh
# trebuie să se numească „snap” (scriptul face command -v snap)
[ "$1" = "list" ] || exit 0
[ "$FAKE_SNAP_HAS_DOCKER" = "1" ] && exit 0
exit 1
EOF
cat >"$TMP_RUN/mocks/fake-f2b" <<'EOF'
#!/bin/sh
exit "${FAKE_F2B:-0}"
EOF
cat >"$TMP_RUN/mocks/fake-ua" <<'EOF'
#!/bin/sh
[ -n "$FAKE_UA_FILE" ] && cat "$FAKE_UA_FILE"
exit 0
EOF
cat >"$TMP_RUN/mocks/fake-visudo" <<'EOF'
#!/bin/sh
exit "${FAKE_VISUDO_RC:-0}"
EOF
cat >"$TMP_RUN/mocks/fake-passwd-P" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-S" ]; then printf '%s P 2024-01-01 0 99999 7 -1\n' "${2:-user}"; exit 0; fi
exit 0
EOF
chmod +x "$TMP_RUN/mocks/fake-gpg" "$TMP_RUN/mocks/fake-dpkg" \
    "$TMP_RUN/mocks/snap" "$TMP_RUN/mocks/fake-f2b" "$TMP_RUN/mocks/fake-ua" \
    "$TMP_RUN/mocks/fake-visudo" "$TMP_RUN/mocks/fake-passwd-P"

printf 'Checking: origin=Debian,codename=bookworm-security,label=Debian-Security\nAllowed origins are: origin=Debian,codename=bookworm,label=Debian-Security\n' >"$TMP_RUN/ua-ok"
printf 'Allowed origins are: origin=Debian,codename=bookworm\nnothing relevant\n' >"$TMP_RUN/ua-bad"

# B4: .sources Tailscale pe ubuntu24.04 — URIs/Suites/Signed-By locale
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.ubuntu24.04" \
    bash "$SCRIPT" --dry-run -y --mode vps --skip-upgrade 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" 'URIs: https://download.docker.com/linux/ubuntu' \
    && contains "$out" 'Suites: noble' \
    && contains "$out" 'URIs: https://pkgs.tailscale.com/stable/ubuntu' \
    && contains "$out" 'Signed-By: /usr/share/keyrings/tailscale-archive-keyring.gpg' \
    && ! contains "$out" 'tailscale-keyring.list' \
    && ! contains "$out" 'scriu /etc/apt/sources.list.d/tailscale.list'; then
    t_pass "B4: .sources docker+tailscale pe ubuntu24.04, deb822 local"
else
    t_fail "B4: .sources docker+tailscale pe ubuntu24.04, deb822 local (rc=$rc)"
fi

# B4: docker.sources pe debian13
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian13" \
    bash "$SCRIPT" --dry-run -y --mode vps --skip-upgrade 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" 'URIs: https://download.docker.com/linux/debian' \
    && contains "$out" 'Suites: trixie' \
    && contains "$out" 'Architectures: amd64'; then
    t_pass "B4: docker.sources pe debian13 (trixie)"
else
    t_fail "B4: docker.sources pe debian13 (trixie) (rc=$rc)"
fi

# B4: fingerprint Docker potrivit → ok, fișierul rămâne
: >"$TMP_RUN/docker.asc"
rc=0
(
    source "$SCRIPT"
    DRY_RUN=no
    export DS_CMD_GPG="$TMP_RUN/mocks/fake-gpg" FAKE_GPG_MODE=valid-docker
    verify_docker_key_fingerprint "$TMP_RUN/docker.asc"
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" && -f "$TMP_RUN/docker.asc" ]]; then
    t_pass "B4: fingerprint Docker potrivit → ok, cheia rămâne"
else
    t_fail "B4: fingerprint Docker potrivit → ok, cheia rămâne (rc=$rc)"
fi

# B4: fingerprint Docker greșit → die 1 + cheia ștearsă
: >"$TMP_RUN/docker-bad.asc"
rc=0
(
    source "$SCRIPT"
    DRY_RUN=no
    export DS_CMD_GPG="$TMP_RUN/mocks/fake-gpg" FAKE_GPG_MODE=valid-tailscale
    verify_docker_key_fingerprint "$TMP_RUN/docker-bad.asc"
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "1" && ! -e "$TMP_RUN/docker-bad.asc" ]]; then
    t_pass "B4: fingerprint Docker greșit → exit 1 + cheie ștearsă"
else
    t_fail "B4: fingerprint Docker greșit → exit 1 + cheie ștearsă (rc=$rc)"
fi

# B4: cheie Tailscale validă → fingerprint în log (fără ANSI)
: >"$TMP_RUN/ts.gpg"
rc=0
(
    source "$SCRIPT"
    DRY_RUN=no
    LOG_FILE="$TMP_RUN/c3.log"
    open_log
    export DS_CMD_GPG="$TMP_RUN/mocks/fake-gpg" FAKE_GPG_MODE=valid-tailscale
    verify_tailscale_key "$TMP_RUN/ts.gpg"
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" && -f "$TMP_RUN/ts.gpg" \
    && "$(cat "$TMP_RUN/c3.log" 2>/dev/null)" == *'1234ABCD5678EF901234ABCD5678EF901234ABCD'* \
    && ! "$(cat "$TMP_RUN/c3.log")" == *$'\033'* ]]; then
    t_pass "B4: cheie Tailscale validă → fingerprint în log"
else
    t_fail "B4: cheie Tailscale validă → fingerprint în log (rc=$rc)"
fi

# B4: cheie Tailscale invalidă → die 1 + ștearsă
: >"$TMP_RUN/ts-bad.gpg"
rc=0
(
    source "$SCRIPT"
    DRY_RUN=no
    export DS_CMD_GPG="$TMP_RUN/mocks/fake-gpg" FAKE_GPG_MODE=invalid
    verify_tailscale_key "$TMP_RUN/ts-bad.gpg"
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "1" && ! -e "$TMP_RUN/ts-bad.gpg" ]]; then
    t_pass "B4: cheie Tailscale invalidă → exit 1 + ștearsă"
else
    t_fail "B4: cheie Tailscale invalidă → exit 1 + ștearsă (rc=$rc)"
fi

# U: origini Ubuntu — security + ESM doar comentariu
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.ubuntu24.04" \
    bash "$SCRIPT" --dry-run -y --mode vps --skip-upgrade 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" 'origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu' \
    && contains "$out" 'origin=Ubuntu,archive=${distro_codename},label=Ubuntu' \
    && contains "$out" 'UbuntuESM'; then
    t_pass "C3/U: origins Ubuntu (security + plain + ESM comentariu)"
else
    t_fail "C3/U: origins Ubuntu (security + plain + ESM comentariu) (rc=$rc)"
fi

# U: verificare OK (originea apare în output-ul mock)
rc=0
(
    source "$SCRIPT"
    DS_OS_RELEASE="$FIXTURES/os-release.debian12"
    detect_distro >/dev/null 2>&1
    DRY_RUN=no STRICT=no
    export DS_CMD_UNATTENDED="$TMP_RUN/mocks/fake-ua" FAKE_UA_FILE="$TMP_RUN/ua-ok"
    verify_unattended_origins
) >"$TMP_RUN/ua-test.out" 2>&1 || rc=$?
if [[ "$rc" == "0" && "$(cat "$TMP_RUN/ua-test.out")" == *'folosește originea de securitate'* ]]; then
    t_pass "C3/U: verificare unattended reușită → ok"
else
    t_fail "C3/U: verificare unattended reușită → ok (rc=$rc)"
fi

# U: lipsă origine + --strict → exit 1
rc=0
(
    source "$SCRIPT"
    DS_OS_RELEASE="$FIXTURES/os-release.debian12"
    detect_distro >/dev/null 2>&1
    DRY_RUN=no STRICT=yes
    export DS_CMD_UNATTENDED="$TMP_RUN/mocks/fake-ua" FAKE_UA_FILE="$TMP_RUN/ua-bad"
    verify_unattended_origins
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "1" ]]; then
    t_pass "C3/U: lipsă origine + --strict → exit 1"
else
    t_fail "C3/U: lipsă origine + --strict → exit 1 (rc=$rc)"
fi

# U: lipsă origine fără --strict → warn puternic, rc 0
rc=0
(
    source "$SCRIPT"
    DS_OS_RELEASE="$FIXTURES/os-release.debian12"
    detect_distro >/dev/null 2>&1
    DRY_RUN=no STRICT=no
    export DS_CMD_UNATTENDED="$TMP_RUN/mocks/fake-ua" FAKE_UA_FILE="$TMP_RUN/ua-bad"
    verify_unattended_origins
) >"$TMP_RUN/ua-warn.out" 2>&1 || rc=$?
if [[ "$rc" == "0" && "$(cat "$TMP_RUN/ua-warn.out")" == *'VERIFICARE UNATTENDED'* ]]; then
    t_pass "C3/U: lipsă origine fără --strict → warn, rc 0"
else
    t_fail "C3/U: lipsă origine fără --strict → warn, rc 0 (rc=$rc)"
fi

# --strict se parsează
out="$(
    source "$SCRIPT"
    parse_args --strict
    printf '%s' "$STRICT"
)"; rc=$?
check_sub "C3/U: parse_args --strict" "yes" 0 "$out" "$rc"

# B2: jail-ul sshd activ → ok; pasiv → warn
rc=0
(
    source "$SCRIPT"
    DRY_RUN=no
    export DS_CMD_FAIL2BAN_CLIENT="$TMP_RUN/mocks/fake-f2b" FAKE_F2B=0
    verify_fail2ban_jail
) >"$TMP_RUN/f2b-ok.out" 2>&1 || rc=$?
if [[ "$rc" == "0" && "$(cat "$TMP_RUN/f2b-ok.out")" == *'jail sshd activ'* ]]; then
    t_pass "B2: jail sshd activ → ok"
else
    t_fail "B2: jail sshd activ → ok (rc=$rc)"
fi

rc=0
(
    source "$SCRIPT"
    DRY_RUN=no
    export DS_CMD_FAIL2BAN_CLIENT="$TMP_RUN/mocks/fake-f2b" FAKE_F2B=1
    verify_fail2ban_jail
) >"$TMP_RUN/f2b-bad.out" 2>&1 || rc=$?
if [[ "$rc" == "0" && "$(cat "$TMP_RUN/f2b-bad.out")" == *'nu răspunde'* ]]; then
    t_pass "B2: jail sshd pasiv → warn"
else
    t_fail "B2: jail sshd pasiv → warn (rc=$rc)"
fi

# B8: nesting lipsă → warn clar; cu nesting → fără warn; systemctl picat → warn, nu abort
out="$(
    source "$SCRIPT"
    DRY_RUN=yes INSTALL_DOCKER=yes SKIP_FIREWALL=no SSH_PORT=22
    SSH_CIDRS=(100.64.0.0/10)
    DOCKER_LXC_NO_NESTING=yes
    install_docker 2>/dev/null
)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" 'security.nesting'; then
    t_pass "B8: LXC fără nesting → warn clar"
else
    t_fail "B8: LXC fără nesting → warn clar (rc=$rc)"
fi

out="$(
    source "$SCRIPT"
    DRY_RUN=yes INSTALL_DOCKER=yes SKIP_FIREWALL=no SSH_PORT=22
    SSH_CIDRS=(100.64.0.0/10)
    DOCKER_LXC_NO_NESTING=no
    install_docker 2>/dev/null
)"; rc=$?
if [[ "$rc" == "0" ]] && ! contains "$out" 'security.nesting'; then
    t_pass "B8: nesting disponibil → fără warn"
else
    t_fail "B8: nesting disponibil → fără warn (rc=$rc)"
fi

out="$(
    source "$SCRIPT"
    DRY_RUN=no INSTALL_DOCKER=yes DOCKER_CONFIG=no SKIP_FIREWALL=no SSH_PORT=22
    SSH_CIDRS=(100.64.0.0/10)
    DOCKER_LXC_NO_NESTING=no
    run() {
        if [[ "${1:-}" == systemctl ]]; then return 1; fi
        return 0
    }
    install_docker 2>/dev/null
    printf 'DONE'
)"; rc=$?
if [[ "$rc" == "0" && "$out" == *DONE ]] && contains "$out" 'serviciul nu a pornit'; then
    t_pass "B8: systemctl picat → warn, instalarea continuă"
else
    t_fail "B8: systemctl picat → warn, instalarea continuă (rc=$rc)"
fi

# D1: pachete conflictuale prezente → remove (fără purge); snap docker prezent → snap remove
out="$(
    source "$SCRIPT"
    DRY_RUN=yes
    export DS_CMD_DPKG="$TMP_RUN/mocks/fake-dpkg" FAKE_DPKG_INSTALLED='docker.io containerd'
    export PATH="$TMP_RUN/mocks:$PATH" FAKE_SNAP_HAS_DOCKER=1
    remove_docker_conflicts 2>/dev/null
)"; rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" 'remove docker.io containerd' \
    && contains "$out" 'snap remove docker' \
    && ! contains "$out" 'purge'; then
    t_pass "D1: remove conflicte (fără purge) + snap remove"
else
    t_fail "D1: remove conflicte (fără purge) + snap remove (rc=$rc)"
fi

# D1: nimic instalat → nicio comandă de remove
out="$(
    source "$SCRIPT"
    DRY_RUN=yes
    export DS_CMD_DPKG="$TMP_RUN/mocks/fake-dpkg" FAKE_DPKG_INSTALLED=''
    export PATH="$TMP_RUN/mocks:$PATH" FAKE_SNAP_HAS_DOCKER=0
    remove_docker_conflicts 2>/dev/null
)"; rc=$?
if [[ "$rc" == "0" ]] && ! contains "$out" 'apt-get' && ! contains "$out" 'snap remove'; then
    t_pass "D1: fără conflicte → nicio mutație"
else
    t_fail "D1: fără conflicte → nicio mutație (rc=$rc)"
fi

# ============================================================
echo "== C4: merge daemon.json, flag-uri Docker =="
# merge pe fișier nou → toate setările gestionate
rc=0
out="$(
    source "$SCRIPT"
    DRY_RUN=no DOCKER_POOL='' DOCKER_BIND_LOCALHOST=no
    merge_docker_config "$TMP_RUN/daemon-nou.json"
)" || rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" '"log-driver": "json-file"' \
    && contains "$out" '"max-size": "10m"' \
    && contains "$out" '"max-file": "3"' \
    && contains "$out" '"live-restore": true' \
    && contains "$out" '"no-new-privileges": true'; then
    t_pass "C4: merge pe fișier nou → setările gestionate complete"
else
    t_fail "C4: merge pe fișier nou → setările gestionate complete (rc=$rc)"
fi

# merge cu chei existente ale utilizatorului → păstrate; doar ce lipsește se adaugă
printf '{"metrics-addr": "127.0.0.1:9323", "log-opts": {"max-size": "50m"}}\n' >"$TMP_RUN/daemon-user.json"
rc=0
out="$(
    source "$SCRIPT"
    DRY_RUN=no DOCKER_POOL='' DOCKER_BIND_LOCALHOST=no
    merge_docker_config "$TMP_RUN/daemon-user.json"
)" || rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" '"metrics-addr": "127.0.0.1:9323"' \
    && contains "$out" '"max-size": "50m"' \
    && contains "$out" '"max-file": "3"' \
    && contains "$out" '"live-restore": true' \
    && ! contains "$out" '"max-size": "10m"'; then
    t_pass "C4: cheile utilizatorului se păstrează (50m), se completează max-file/live-restore"
else
    t_fail "C4: cheile utilizatorului se păstrează (50m), se completează max-file/live-restore (rc=$rc)"
fi

# idempotență: setările gestionate deja prezente → rc 2, fără output
printf '{"live-restore": true, "log-driver": "json-file", "log-opts": {"max-file": "3", "max-size": "10m"}, "no-new-privileges": true}\n' >"$TMP_RUN/daemon-idem.json"
rc=0
out="$(
    source "$SCRIPT"
    DRY_RUN=no DOCKER_POOL='' DOCKER_BIND_LOCALHOST=no
    merge_docker_config "$TMP_RUN/daemon-idem.json"
)" || rc=$?
if [[ "$rc" == "2" && -z "$out" ]]; then
    t_pass "C4: daemon.json deja la zi → rc 2, fără schimbări"
else
    t_fail "C4: daemon.json deja la zi → rc 2, fără schimbări (rc=$rc)"
fi

# fișier invalid → rc 1; rădăcină non-obiect → rc 1
printf 'not-json{{\n' >"$TMP_RUN/daemon-bad.json"
printf '[1, 2]\n' >"$TMP_RUN/daemon-arr.json"
rc=0
(
    source "$SCRIPT"
    DRY_RUN=no DOCKER_POOL='' DOCKER_BIND_LOCALHOST=no
    merge_docker_config "$TMP_RUN/daemon-bad.json" >/dev/null
) || rc=$?
rc2=0
(
    source "$SCRIPT"
    DRY_RUN=no DOCKER_POOL='' DOCKER_BIND_LOCALHOST=no
    merge_docker_config "$TMP_RUN/daemon-arr.json" >/dev/null
) || rc2=$?
if [[ "$rc" == "1" && "$rc2" == "1" ]]; then
    t_pass "C4: fișier invalid / non-obiect → rc 1 (nu scrie nimic)"
else
    t_fail "C4: fișier invalid / non-obiect → rc 1 (rc=$rc, rc2=$rc2)"
fi

# --docker-pool → default-address-pools; --docker-bind-localhost → ip 127.0.0.1
printf '{}' >"$TMP_RUN/daemon-pool.json"
rc=0
out="$(
    source "$SCRIPT"
    DRY_RUN=no DOCKER_POOL=10.200.0.0/16 DOCKER_BIND_LOCALHOST=yes
    merge_docker_config "$TMP_RUN/daemon-pool.json"
)" || rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" '"base": "10.200.0.0/16"' \
    && contains "$out" '"size": 24' \
    && contains "$out" '"ip": "127.0.0.1"'; then
    t_pass "C4: docker-pool → default-address-pools; bind-localhost → ip 127.0.0.1"
else
    t_fail "C4: docker-pool → default-address-pools; bind-localhost → ip 127.0.0.1 (rc=$rc)"
fi

# flux real pe copie temporară: backup + restart o singură dată (idempotență)
rc=0
C4OUT="$(
    (
        source "$SCRIPT"
        DRY_RUN=no INSTALL_DOCKER=yes DOCKER_CONFIG=yes DOCKER_POOL=10.200.0.0/16 \
            DOCKER_BIND_LOCALHOST=no DOCKER_USER=
        export DS_DOCKER_DAEMON="$TMP_RUN/daemon-flow.json"
        printf '{"metrics-addr": "127.0.0.1:9323"}\n' >"$DS_DOCKER_DAEMON"
        run() {
            if [[ "${1:-}" == systemctl ]]; then printf 'RUN %s\n' "$*"; return 0; fi
            command "$@"
        }
        configure_docker_config
        configure_docker_config
    ) 2>&1
)" || rc=$?
restarts=$(printf '%s\n' "$C4OUT" | grep -c 'systemctl restart docker.service' || true)
backups=$(find "$TMP_RUN" -maxdepth 1 -name 'daemon-flow.json.bak-*' 2>/dev/null | wc -l)
if [[ "$rc" == "0" && "$restarts" == "1" && "$backups" == "1" \
    && "$(cat "$TMP_RUN/daemon-flow.json")" == *'metrics-addr'* \
    && "$(cat "$TMP_RUN/daemon-flow.json")" == *'live-restore'* ]]; then
    t_pass "C4: flux real → merge + backup + restart doar la prima rulare"
else
    t_fail "C4: flux real → merge + backup + restart doar la prima rulare (rc=$rc, restarts=$restarts, backups=$backups)"
fi

# flux real cu fișier invalid → warn, fișier neatins, rc 0
rc=0
C4BAD="$(
    (
        source "$SCRIPT"
        DRY_RUN=no INSTALL_DOCKER=yes DOCKER_CONFIG=yes DOCKER_POOL='' \
            DOCKER_BIND_LOCALHOST=no DOCKER_USER=
        export DS_DOCKER_DAEMON="$TMP_RUN/daemon-invalid.json"
        printf 'not-json{{\n' >"$DS_DOCKER_DAEMON"
        run() { command "$@"; }
        configure_docker_config 2>/dev/null
        printf 'CONTENT:%s' "$(cat "$DS_DOCKER_DAEMON")"
    ) 2>&1
)" || rc=$?
if [[ "$rc" == "0" && "$C4BAD" == *'JSON invalid'* && "$C4BAD" == *'CONTENT:not-json{{' ]]; then
    t_pass "C4: fișier existent invalid → warn, nu scrie nimic, continuă"
else
    t_fail "C4: fișier existent invalid → warn, nu scrie nimic, continuă (rc=$rc)"
fi

# parse_args pentru flag-urile noi
out="$(
    source "$SCRIPT"
    parse_args --docker-pool 10.200.0.0/24 --docker-bind-localhost --no-docker-config --docker-user dan
    printf '%s|%s|%s|%s' "$DOCKER_POOL" "$DOCKER_BIND_LOCALHOST" "$DOCKER_CONFIG" "$DOCKER_USER"
)"; rc=$?
check_sub "C4: parse_args --docker-*" "10.200.0.0/24|yes|no|dan" 0 "$out" "$rc"

# allowlist --config: chei Docker acceptate; DOCKER_POOL invalid → exit 2
cat >"$TMP_RUN/docker.conf" <<'EOF'
DOCKER_POOL=10.55.0.0/16
DOCKER_USER=ana
DOCKER_BIND_LOCALHOST=yes
EOF
out="$(
    source "$SCRIPT"
    parse_args --config "$TMP_RUN/docker.conf"
    printf '%s|%s|%s' "$DOCKER_POOL" "$DOCKER_USER" "$DOCKER_BIND_LOCALHOST"
)"; rc=$?
check_sub "C4: config acceptă chei Docker" "10.55.0.0/16|ana|yes" 0 "$out" "$rc"

cat >"$TMP_RUN/docker-bad.conf" <<'EOF'
DOCKER_POOL=banana
EOF
rc=0
(
    source "$SCRIPT"
    parse_args --config "$TMP_RUN/docker-bad.conf"
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "2" ]]; then
    t_pass "C4: config DOCKER_POOL invalid → exit 2"
else
    t_fail "C4: config DOCKER_POOL invalid → exit 2 (rc=$rc)"
fi

# preflight: --docker-pool invalid → exit 2
expect_rc "C4: --docker-pool invalid → exit 2" 2 \
    env -u SSH_CONNECTION -u SSH_CLIENT DS_SSH_CHAIN=none DS_ROOT_OK=1 \
    DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 --docker-pool banana

# preflight: --docker-user inexistent → exit 2
expect_rc "C4: --docker-user inexistent → exit 2" 2 \
    env -u SSH_CONNECTION -u SSH_CLIENT DS_SSH_CHAIN=none DS_ROOT_OK=1 \
    DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 --docker-user nu-exista-xyz

# --no-docker-config → planul nu atinge daemon.json
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 --no-docker-config 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && ! contains "$out" '/etc/docker/daemon.json'; then
    t_pass "C4: --no-docker-config → daemon.json neatins"
else
    t_fail "C4: --no-docker-config → daemon.json neatins (rc=$rc)"
fi

# --print-config include noile chei
out="$(bash "$SCRIPT" --print-config --docker-user dan --docker-pool 10.9.0.0/16)"; rc=$?
if [[ "$rc" == "0" ]] \
    && printf '%s\n' "$out" | grep -qx 'DOCKER_USER=dan' \
    && printf '%s\n' "$out" | grep -qx 'DOCKER_POOL=10.9.0.0/16' \
    && printf '%s\n' "$out" | grep -qx 'DOCKER_BIND_LOCALHOST=no' \
    && printf '%s\n' "$out" | grep -qx 'DOCKER_CONFIG=yes'; then
    t_pass "C4: --print-config include DOCKER_*"
else
    t_fail "C4: --print-config include DOCKER_*"
fi

# mesaj final: fără DOCKER-USER automat, dar cu instrucțiuni
out="$(
    source "$SCRIPT"
    DRY_RUN=yes INSTALL_DOCKER=yes INSTALL_TAILSCALE=no RESET_FIREWALL=no
    final_notes
)"; rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" 'DOCKER-USER' \
    && contains "$out" 'iptables -I DOCKER-USER'; then
    t_pass "C4: final_notes explică regulile DOCKER-USER manuale"
else
    t_fail "C4: final_notes explică regulile DOCKER-USER manuale (rc=$rc)"
fi

# ============================================================
echo "== C5: A1 user+cheie, A2/A3 keys-only, A4, U1-U3 =="
cat >"$TMP_RUN/mocks/fake-keygen-ok" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$TMP_RUN/mocks/fake-keygen-bad" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$TMP_RUN/mocks/fake-getent-c5" <<'EOF'
#!/bin/sh
if [ "$1" = "passwd" ]; then
  [ "${FAKE_GETENT_NOUSER:-}" = "1" ] && exit 2
  if [ -n "${FAKE_GETENT_FAIL_FIRST:-}" ]; then
    sf="${FAKE_GETENT_STATE:-/tmp/fake-getent.state}"
    if [ ! -f "$sf" ]; then : >"$sf"; exit 2; fi
  fi
  printf 'x:x:1000:1000::%s:/bin/bash\n' "${FAKE_GETENT_HOME:-/nonexistent}"
  exit 0
fi
if [ "$1" = "group" ]; then
  printf 'sudo:x:27:%s\n' "${FAKE_GETENT_SUDOERS:-}"
  exit 0
fi
exit 2
EOF
cat >"$TMP_RUN/mocks/fake-sshd-c5" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -t) exit "${FAKE_SSHD_T:-0}" ;;
  -T) [ -n "$FAKE_SSHD_T_OUT_FILE" ] && cat "$FAKE_SSHD_T_OUT_FILE"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP_RUN/mocks/fake-keygen-ok" "$TMP_RUN/mocks/fake-keygen-bad" \
    "$TMP_RUN/mocks/fake-getent-c5" "$TMP_RUN/mocks/fake-sshd-c5"

# A1: parse_args
out="$(
    source "$SCRIPT"
    parse_args --create-user dan --ssh-key-file /tmp/k.pub --ssh-keys-only --allow-users dan,alt2 --auto-reboot 03:30 --mail ops@ex.ro --update-third-party
    printf '%s|%s|%s|%s|%s|%s|%s' "$CREATE_USER" "$SSH_KEY_FILE" "$SSH_KEYS_ONLY" "$ALLOW_USERS" "$AUTO_REBOOT" "$MAIL_ADDR" "$UPDATE_THIRD_PARTY"
)"; rc=$?
check_sub "C5: parse_args flag-uri noi" "dan|/tmp/k.pub|yes|dan,alt2|03:30|ops@ex.ro|yes" 0 "$out" "$rc"

# A1: nume invalid → exit 2
expect_rc "C5/A1: --create-user invalid → exit 2" 2 \
    env DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --create-user 'Bad Name'

# A1: --ssh-key invalid → exit 2 (ssh-keygen mock care eșuează)
expect_rc "C5/A1: --ssh-key invalid → exit 2" 2 \
    env -u SSH_CONNECTION -u SSH_CLIENT DS_SSH_CHAIN=none DS_CMD_SSH_KEYGEN="$TMP_RUN/mocks/fake-keygen-bad" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 --create-user dan --ssh-key 'ssh-ed25519 GROASA'

# A1: ambele surse de cheie → exit 2
expect_rc "C5/A1: --ssh-key + --ssh-key-file → exit 2" 2 \
    env DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --create-user dan --ssh-key k --ssh-key-file f

# A1: plan dry-run pentru userul creat
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_CMD_SSH_KEYGEN="$TMP_RUN/mocks/fake-keygen-ok" \
    DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" FAKE_GETENT_NOUSER=1 \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 \
    --create-user c5user --ssh-key 'ssh-ed25519 AAAATEST dan@host' 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" 'useradd -m -s /bin/bash c5user' \
    && contains "$out" 'usermod -aG sudo c5user' \
    && contains "$out" 'Scriu sudoers NOPASSWD pentru c5user' \
    && contains "$out" '0700' && contains "$out" '0600'; then
    t_pass "C5/A1: plan user creat (sudo, parolă blocată, permisiuni .ssh)"
else
    t_fail "C5/A1: plan user creat (sudo, parolă blocată, permisiuni .ssh) (rc=$rc)"
fi

# A1: idempotență reală pe home temporar (getent mock; useradd/etc prin run-mock)
rc=0
C5A1="$(
    (
        source "$SCRIPT"
        DRY_RUN=no CREATE_USER=dan SSH_KEY='ssh-ed25519 AAAATEST dan@host' SSH_KEY_FILE=''
        export DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" FAKE_GETENT_HOME="$TMP_RUN/home/dan"
        mkdir -p "$TMP_RUN/home/dan/.ssh"
        printf 'ssh-ed25519 AAAAVECHE dan@vechi\n' >"$TMP_RUN/home/dan/.ssh/authorized_keys"
        run() {
            case "${1:-}" in
                useradd|usermod|passwd|chown|chmod|install) return 0 ;;
            esac
            command "$@"
        }
        configure_created_user >/dev/null 2>&1
        configure_created_user >/dev/null 2>&1
        printf 'LINES:%s' "$(grep -c . "$TMP_RUN/home/dan/.ssh/authorized_keys")"
    ) 2>&1
)" || rc=$?
if [[ "$rc" == "0" && "$C5A1" == *'LINES:2' ]]; then
    t_pass "C5/A1: cheie adăugată fără duplicate (2 rânduri: vechi + nou)"
else
    t_fail "C5/A1: cheie adăugată fără duplicate (rc=$rc, out=«$C5A1»)"
fi

# A2: precondiție eșuează → exit 4
expect_rc "C5/A2: --ssh-keys-only fără chei → exit 4" 4 \
    env -u SSH_CONNECTION -u SSH_CLIENT DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" \
    FAKE_GETENT_SUDOERS=cineva FAKE_GETENT_HOME=/nonexistent \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode vps --ssh-keys-only

# A2: precondiție trecută prin cheia userului creat → rc 0
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_CMD_SSH_KEYGEN="$TMP_RUN/mocks/fake-keygen-ok" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode vps --ssh-keys-only \
    --create-user dan --ssh-key 'ssh-ed25519 AAAATEST dan@host' 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" '00-bootstrap-security.conf' \
    && contains "$out" 'PasswordAuthentication no' \
    && contains "$out" 'KbdInteractiveAuthentication no' \
    && contains "$out" 'PermitRootLogin prohibit-password'; then
    t_pass "C5/A2: keys-only → drop-in 00- cu politica corectă"
else
    t_fail "C5/A2: keys-only → drop-in 00- cu politica corectă (rc=$rc)"
fi

# A2: ssh_keys_present_for_privileged cu mock-uri
rc=0
(
    source "$SCRIPT"
    export DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" FAKE_GETENT_SUDOERS=dan FAKE_GETENT_HOME="$TMP_RUN/home/dan"
    mkdir -p "$TMP_RUN/home/dan/.ssh"
    printf 'ssh-ed25519 AAAATEST x\n' >"$TMP_RUN/home/dan/.ssh/authorized_keys"
    export DS_CMD_SSH_KEYGEN="$TMP_RUN/mocks/fake-keygen-ok"
    ssh_keys_present_for_privileged
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" ]]; then t_pass "C5/A2: cheie validă la user sudo → prezent"; else t_fail "C5/A2: cheie validă la user sudo → prezent"; fi

rc=0
(
    source "$SCRIPT"
    export DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" FAKE_GETENT_SUDOERS=dan FAKE_GETENT_HOME="$TMP_RUN/home/dan"
    export DS_CMD_SSH_KEYGEN="$TMP_RUN/mocks/fake-keygen-bad"
    ssh_keys_present_for_privileged
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "1" ]]; then t_pass "C5/A2: cheie invalidă → absent"; else t_fail "C5/A2: cheie invalidă → absent"; fi

# A3: sshd -T cu valori greșite → rollback + exit 1
rc=0
C5A3="$(
    (
        source "$SCRIPT"
        DRY_RUN=no SSH_KEYS_ONLY=yes ALLOW_USERS='' INSTALL_DOCKER=no INSTALL_TAILSCALE=no INSTALL_AUTO_UPDATES=no INSTALL_FAIL2BAN=no
        export DS_SSH_CONFIG_DIR="$TMP_RUN/sshd.d"
        export DS_CMD_SSHD="$TMP_RUN/mocks/fake-sshd-c5" FAKE_SSHD_T_OUT_FILE="$TMP_RUN/sshd-T-wrong"
        mkdir -p "$TMP_RUN/sshd.d"
        printf 'passwordauthentication yes\nkbdinteractiveauthentication no\npermitrootlogin prohibit-password\n' >"$TMP_RUN/sshd-T-wrong"
        run() {
            case "${1:-}" in
                systemctl|mkdir|install) return 0 ;;
            esac
            command "$@"
        }
        configure_ssh
    ) 2>&1
)" || rc=$?
if [[ "$rc" == "1" ]] && contains "$C5A3" 'sshd -T arată valori diferite' \
    && [[ ! -f "$TMP_RUN/sshd.d/00-bootstrap-security.conf" ]]; then
    t_pass "C5/A3: valori efective greșite → rollback (00- șters) + exit 1"
else
    t_fail "C5/A3: valori efective greșite → rollback + exit 1 (rc=$rc)"
fi

# A3: valori efective corecte → fișierul rămâne, rc 0
rc=0
(
    source "$SCRIPT"
    DRY_RUN=no SSH_KEYS_ONLY=yes ALLOW_USERS='' INSTALL_DOCKER=no INSTALL_TAILSCALE=no INSTALL_AUTO_UPDATES=no INSTALL_FAIL2BAN=no
    export DS_SSH_CONFIG_DIR="$TMP_RUN/sshd.d-ok"
    export DS_CMD_SSHD="$TMP_RUN/mocks/fake-sshd-c5" FAKE_SSHD_T_OUT_FILE="$TMP_RUN/sshd-T-ok"
    mkdir -p "$TMP_RUN/sshd.d-ok"
    printf 'passwordauthentication no\nkbdinteractiveauthentication no\npermitrootlogin prohibit-password\n' >"$TMP_RUN/sshd-T-ok"
    run() {
        case "${1:-}" in
            systemctl|mkdir|install) return 0 ;;
        esac
        command "$@"
    }
    configure_ssh >/dev/null 2>&1
) || rc=$?
if [[ "$rc" == "0" && -f "$TMP_RUN/sshd.d-ok/00-bootstrap-security.conf" \
    && "$(cat "$TMP_RUN/sshd.d-ok/00-bootstrap-security.conf")" == *'PasswordAuthentication no'* ]]; then
    t_pass "C5/A3: valori efective corecte → drop-in rămâne, rc 0"
else
    t_fail "C5/A3: valori efective corecte → drop-in rămâne, rc 0 (rc=$rc)"
fi

# A3: rollback la conținutul anterior când 00- exista deja
rc=0
(
    source "$SCRIPT"
    DRY_RUN=no SSH_KEYS_ONLY=yes ALLOW_USERS='' INSTALL_DOCKER=no INSTALL_TAILSCALE=no INSTALL_AUTO_UPDATES=no INSTALL_FAIL2BAN=no
    export DS_SSH_CONFIG_DIR="$TMP_RUN/sshd.d-old"
    export DS_CMD_SSHD="$TMP_RUN/mocks/fake-sshd-c5" FAKE_SSHD_T_OUT_FILE="$TMP_RUN/sshd-T-wrong"
    mkdir -p "$TMP_RUN/sshd.d-old"
    printf '#vechea-politica\n' >"$TMP_RUN/sshd.d-old/00-bootstrap-security.conf"
    run() {
        case "${1:-}" in
            systemctl|mkdir|install) return 0 ;;
        esac
        command "$@"
    }
    configure_ssh >/dev/null 2>&1
) || rc=$?
if [[ "$rc" == "1" && "$(cat "$TMP_RUN/sshd.d-old/00-bootstrap-security.conf")" == '#vechea-politica' ]]; then
    t_pass "C5/A3: rollback la conținutul anterior al drop-in-ului"
else
    t_fail "C5/A3: rollback la conținutul anterior al drop-in-ului (rc=$rc)"
fi

# A4: userul curent exclus → exit 4; inclus → AllowUsers în plan
expect_rc "C5/A4: --allow-users fără userul curent → exit 4" 4 \
    env SUDO_USER=radu DS_SSH_CHAIN=none DS_ROOT_OK=1 \
    DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode vps --allow-users alt1,alt2

out="$(env SUDO_USER=radu DS_SSH_CHAIN=none PATH="$TMP_RUN/bin-novirt:$PATH" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode vps --allow-users dan,alt2 --create-user dan 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" 'AllowUsers dan alt2'; then
    t_pass "C5/A4: --create-user din listă acoperă accesul → AllowUsers"
else
    t_fail "C5/A4: --create-user din listă acoperă accesul → AllowUsers (rc=$rc)"
fi

expect_rc "C5/A4: utilizator invalid în listă → exit 2" 2 \
    env SUDO_USER=radu DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode vps --allow-users 'Bad!'

# U1/U2/U3: conținutul 52-bootstrap-security
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 \
    --auto-reboot 03:30 --mail ops@example.com --update-third-party 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" 'Unattended-Upgrade::Automatic-Reboot "true"' \
    && contains "$out" 'Unattended-Upgrade::Automatic-Reboot-Time "03:30"' \
    && contains "$out" 'Unattended-Upgrade::Automatic-Reboot "false"' \
    && contains "$out" 'Unattended-Upgrade::Mail "ops@example.com"' \
    && contains "$out" 'Unattended-Upgrade::MailReport "on-change"' \
    && contains "$out" 'origin=Docker,codename=${distro_codename}' \
    && contains "$out" 'origin=Tailscale,codename=${distro_codename}' \
    && contains "$out" 'MTA'; then
    t_pass "C5/U: auto-reboot + mail (+warn MTA) + origins third-party"
else
    t_fail "C5/U: auto-reboot + mail (+warn MTA) + origins third-party (rc=$rc)"
fi

# U2: cu MTA disponibil → fără warn
mkdir -p "$TMP_RUN/with-mta"
printf '#!/bin/sh\nexit 0\n' >"$TMP_RUN/with-mta/sendmail"
chmod +x "$TMP_RUN/with-mta/sendmail"
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/with-mta:$PATH" DS_SSH_CHAIN=none \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 --mail ops@example.com 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && ! contains "$out" 'MTA'; then
    t_pass "C5/U2: cu MTA în PATH → fără warn"
else
    t_fail "C5/U2: cu MTA în PATH → fără warn (rc=$rc)"
fi

# implicit: fără origini third-party în planul existent
if contains "$SMOKE" 'origin=Docker'; then
    t_fail "C5/U3: implicit fără origini Docker/Tailscale"
else
    t_pass "C5/U3: implicit fără origini Docker/Tailscale"
fi

# verificarea unattended rămâne funcțională cu --update-third-party
rc=0
(
    source "$SCRIPT"
    DS_OS_RELEASE="$FIXTURES/os-release.debian12"
    detect_distro >/dev/null 2>&1
    DRY_RUN=no STRICT=no UPDATE_THIRD_PARTY=yes
    export DS_CMD_UNATTENDED="$TMP_RUN/mocks/fake-ua" FAKE_UA_FILE="$TMP_RUN/ua-ok"
    verify_unattended_origins
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" ]]; then
    t_pass "C5/U3: verify_unattended_origins funcționează și cu third-party"
else
    t_fail "C5/U3: verify_unattended_origins funcționează și cu third-party (rc=$rc)"
fi

# validări config pentru cheile noi
cat >"$TMP_RUN/c5.conf" <<'EOF'
CREATE_USER=dan
ALLOW_USERS=dan,alt2
AUTO_REBOOT=01:00
MAIL_ADDR=a@b.ro
UPDATE_THIRD_PARTY=yes
EOF
out="$(
    source "$SCRIPT"
    parse_args --config "$TMP_RUN/c5.conf"
    printf '%s|%s|%s|%s|%s' "$CREATE_USER" "$ALLOW_USERS" "$AUTO_REBOOT" "$MAIL_ADDR" "$UPDATE_THIRD_PARTY"
)"; rc=$?
check_sub "C5: config acceptă cheile noi" "dan|dan,alt2|01:00|a@b.ro|yes" 0 "$out" "$rc"

cat >"$TMP_RUN/c5-bad.conf" <<'EOF'
AUTO_REBOOT=99:99
EOF
rc=0
(
    source "$SCRIPT"
    parse_args --config "$TMP_RUN/c5-bad.conf"
) >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "2" ]]; then
    t_pass "C5: config AUTO_REBOOT invalid → exit 2"
else
    t_fail "C5: config AUTO_REBOOT invalid → exit 2 (rc=$rc)"
fi

# ============================================================
echo "== C6a: R1-R4, idempotenență, mesaj final, curățenie =="

# R1: nume de proces sshd acceptate
out="$(
    source "$SCRIPT"
    is_sshd_comm sshd && a=1
    is_sshd_comm sshd-session && b=1
    is_sshd_comm sshd-auth && c=1
    is_sshd_comm ssh || d=1
    printf '%s%s%s%s' "${a:-}" "${b:-}" "${c:-}" "${d:-}"
)"; rc=$?
check_sub "R1: is_sshd_comm acceptă sshd/sshd-session/sshd-auth (a 4-a cifră = ssh respins corect)" "1111" 0 "$out" "$rc"

# R1: fallback — sesiuni established neacoperite → warn (nu die)
printf 'ESTAB 0 0 10.100.10.13:22 203.0.113.9:5001\nESTAB 0 0 10.100.10.13:22 198.51.100.7:5002\n' >"$TMP_RUN/ss-two"
rc=0
out="$(
    source "$SCRIPT"
    SSH_SESSION_IS_SSH=no SSH_PORT=22
    SSH_CIDRS=(192.168.1.0/24 100.64.0.0/10 fd7a:115c:a1e0::/48)
    export DS_CMD_SS="$TMP_RUN/mocks/fake-ss" FAKE_SS_FILE="$TMP_RUN/ss-two"
    collect_established_peers
    warn_uncovered_established
)" 2>&1 || rc=$?
if [[ "$rc" == "0" ]] && contains "$out" '203.0.113.9 198.51.100.7' \
    && contains "$out" 'neacoperite de CIDR-urile permise'; then
    t_pass "R1: established neacoperite → warn vizibil cu IP-urile"
else
    t_fail "R1: established neacoperite → warn vizibil cu IP-urile (rc=$rc)"
fi

rc=0
out="$(
    source "$SCRIPT"
    SSH_SESSION_IS_SSH=no SSH_PORT=22
    SSH_CIDRS=(203.0.113.0/24 198.51.100.0/24)
    export DS_CMD_SS="$TMP_RUN/mocks/fake-ss" FAKE_SS_FILE="$TMP_RUN/ss-two"
    collect_established_peers
    warn_uncovered_established
)" 2>&1 || rc=$?
if [[ "$rc" == "0" ]] && ! contains "$out" 'neacoperite'; then
    t_pass "R1: surse acoperite → fără warn"
else
    t_fail "R1: surse acoperite → fără warn (rc=$rc)"
fi

out="$(
    source "$SCRIPT"
    SSH_SESSION_IS_SSH=yes SSH_PORT=22
    SSH_CIDRS=(192.168.1.0/24)
    SSH_ESTABLISHED_PEERS='203.0.113.9 '
    warn_uncovered_established
)" 2>&1 || rc=$?
if [[ "$rc" == "0" ]] && ! contains "$out" 'neacoperite'; then
    t_pass "R1: sesiune SSH confirmată → fallback-ul nu se aplică"
else
    t_fail "R1: sesiune SSH confirmată → fallback-ul nu se aplică (rc=$rc)"
fi

# R1: integrare — warn vizibil în dry-run cu surse neacoperite (fără die)
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" DS_SSH_CHAIN=none \
    DS_CMD_SS="$TMP_RUN/mocks/fake-ss" FAKE_SS_FILE="$TMP_RUN/ss-two" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" 'neacoperite de CIDR-urile permise: 203.0.113.9 198.51.100.7'; then
    t_pass "R1: integrare dry-run → warn, rularea continuă (exit 0)"
else
    t_fail "R1: integrare dry-run → warn, rularea continuă (rc=$rc)"
fi

# R2: .sources deb822 — conținutul începe cu 'Types:' și vechiul .list se șterge
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode vps --skip-upgrade 2>&1)"; rc=$?
ord_ts=$(line_of "$out" 'scriu /etc/apt/sources.list.d/tailscale.sources')
first_block="$(printf '%s\n' "$out" | tail -n +$((ord_ts + 1)) | grep -m1 '^    | ')"
if [[ "$rc" == "0" && "$ord_ts" -gt 0 && "$first_block" == '    | Types: deb' ]] \
    && ! contains "$out" 'scriu /etc/apt/sources.list.d/tailscale.list'; then
    t_pass "R2: tailscale.sources deb822 (începe cu 'Types:'), fără .list nou"
else
    t_fail "R2: tailscale.sources deb822 (rc=$rc, ord=$ord_ts, first=«$first_block»)"
fi

# R2: tailscale.list vechi existent → rm -f în plan
printf 'deb [signed-by=x] https://pkgs.tailscale.com/stable/debian bookworm main\n' >"$TMP_RUN/tailscale.list-old"
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_TAILSCALE_OLD_LIST="$TMP_RUN/tailscale.list-old" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode vps --skip-upgrade 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" "rm -f $TMP_RUN/tailscale.list-old"; then
    t_pass "R2: vechiul tailscale.list → rm -f în planul dry-run"
else
    t_fail "R2: vechiul tailscale.list → rm -f în planul dry-run (rc=$rc)"
fi

# R2: niciun write_file pe .list în tot scriptul (docker era deja .sources)
if grep -Eq 'write_file [^|]*\.list( |$)' "$SCRIPT"; then
    t_fail "R2: niciun fișier .list scris de script"
else
    t_pass "R2: niciun fișier .list scris de script"
fi

# R3: derivat cu codename necunoscut (kali) → warn, dar merge, cu CODENAME păstrat
out="$(
    source "$SCRIPT"
    DS_OS_RELEASE="$FIXTURES/os-release.kali"
    detect_distro
    printf '|%s|%s' "$DISTRO" "$CODENAME"
)" 2>&1; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" 'debian|kali-rolling' \
    && contains "$out" "nu e în lista cunoscută"; then
    t_pass "R3: kali (derivat, codename necunoscut) → warn + debian/kali-rolling"
else
    t_fail "R3: kali (derivat, codename necunoscut) → warn + debian/kali-rolling (rc=$rc)"
fi

# R3: distro primar cu versiune/codename necunoscut → die 3
out="$(
    source "$SCRIPT"
    DS_OS_RELEASE="$FIXTURES/os-release.ubuntu2504"
    detect_distro
    printf '|%s|%s' "$DISTRO" "$CODENAME"
)" 2>&1; rc=$?
check_sub "R3: ubuntu 25.04 (primar necunoscut) → exit 3" "" 3 "$out" "$rc"

# R3: derivate cu codename cunoscut → fără warn de codename
out="$(
    source "$SCRIPT"
    DS_OS_RELEASE="$FIXTURES/os-release.raspbian"
    detect_distro
    printf 'OK'
)" 2>&1; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" 'OK' && ! contains "$out" 'nu e în lista cunoscută'; then
    t_pass "R3: raspbian (bookworm cunoscut) → fără warn"
else
    t_fail "R3: raspbian (bookworm cunoscut) → fără warn (rc=$rc)"
fi

# Idempotență: planul dry-run e identic la două rulări (fără timestamp-uri)
C6ARGS=(--dry-run -y --mode lan --lan-cidr 192.168.1.0/24 --wireguard-cidr 10.8.0.0/24 \
    --wireguard-iface wg0 --docker-pool 10.200.0.0/16 --docker-bind-localhost \
    --auto-reboot 03:30 --mail ops@example.com --update-third-party --reset-firewall \
    --skip-upgrade)
P1="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_TAILSCALE_OLD_LIST="$TMP_RUN/tailscale.list-old" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" "${C6ARGS[@]}" 2>&1 | sed -E 's/ufw-[0-9]{8}-[0-9]{6}/ufw-TIMESTAMP/g')"
P2="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_TAILSCALE_OLD_LIST="$TMP_RUN/tailscale.list-old" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" "${C6ARGS[@]}" 2>&1 | sed -E 's/ufw-[0-9]{8}-[0-9]{6}/ufw-TIMESTAMP/g')"
if [[ -n "$P1" && "$P1" == "$P2" ]]; then
    t_pass "Idempotență: două rulări dry-run → plan identic (fără timestamp-uri)"
else
    t_fail "Idempotență: două rulări dry-run → plan identic"
fi

# Idempotență: cu --skip-upgrade planul nu conține full-upgrade
if contains "$SMOKE13" 'full-upgrade'; then
    t_fail "Idempotență: --skip-upgrade → fără full-upgrade în plan"
else
    t_pass "Idempotență: --skip-upgrade → fără full-upgrade în plan"
fi

# Idempotență: funcții idempotente cu fixture-uri (comentariu: idempotenața reală
# „zero mutații la a doua rulare” NU poate fi simulată complet fără root — planul
# dry-run e independent de starea reală; acoperim pe funcții: IPV6, daemon.json,
# authorized_keys, drop-in ssh)
rc=0
(
    source "$SCRIPT"
    DRY_RUN=no SSH_KEYS_ONLY=yes ALLOW_USERS='dan,alt' INSTALL_DOCKER=no INSTALL_TAILSCALE=no INSTALL_AUTO_UPDATES=no INSTALL_FAIL2BAN=no
    export DS_SSH_CONFIG_DIR="$TMP_RUN/sshd.d-idem"
    export DS_CMD_SSHD="$TMP_RUN/mocks/fake-sshd-c5" FAKE_SSHD_T_OUT_FILE="$TMP_RUN/sshd-T-ok"
    mkdir -p "$TMP_RUN/sshd.d-idem"
    printf 'passwordauthentication no\nkbdinteractiveauthentication no\npermitrootlogin prohibit-password\n' >"$TMP_RUN/sshd-T-ok"
    run() {
        case "${1:-}" in
            systemctl|mkdir|install) return 0 ;;
        esac
        command "$@"
    }
    configure_ssh >/dev/null 2>&1
    cp "$TMP_RUN/sshd.d-idem/90-bootstrap-security.conf" "$TMP_RUN/ssh-90-run1"
    configure_ssh >/dev/null 2>&1
    diff -q "$TMP_RUN/ssh-90-run1" "$TMP_RUN/sshd.d-idem/90-bootstrap-security.conf" >/dev/null
) || rc=$?
if [[ "$rc" == "0" ]]; then
    t_pass "Idempotență: configure_ssh de două ori → conținut identic"
else
    t_fail "Idempotență: configure_ssh de două ori → conținut identic (rc=$rc)"
fi

# Mesaj final: rezumat + pași + avertismente
out="$(
    source "$SCRIPT"
    DRY_RUN=yes MODE=lan DISTRO=debian CODENAME=bookworm SSH_PORT=22
    SSH_CIDRS=(192.168.1.0/24 100.64.0.0/10)
    INSTALL_DOCKER=yes INSTALL_TAILSCALE=yes INSTALL_FAIL2BAN=yes SKIP_FIREWALL=no RESET_FIREWALL=no
    final_notes
)" 2>&1; rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" 'DONE — REZUMAT' \
    && contains "$out" 'Mod:            lan' \
    && contains "$out" 'port 22, permis din: 192.168.1.0/24' \
    && contains "$out" 'docker:       instalat' \
    && contains "$out" 'tailscale:    instalat' \
    && contains "$out" 'ufw:          planificat' \
    && contains "$out" 'fail2ban:     planificat' \
    && contains "$out" 'sudo tailscale up' \
    && contains "$out" '/var/run/reboot-required' \
    && contains "$out" '0.0.0.0' \
    && contains "$out" 'DOCKER-USER'; then
    t_pass "Mesaj final: rezumat + servicii + pași + avertismente"
else
    t_fail "Mesaj final: rezumat + servicii + pași + avertismente (rc=$rc)"
fi

# Curățenie: fiecare flag de setare are cheie în CONFIG_KEYS + usage + --print-config
declare -A C6_FLAG2KEY=(
    [MODE]='--mode'
    [LAN_CIDR]='--lan-cidr'
    [WIREGUARD_CIDR]='--wireguard-cidr'
    [WIREGUARD_IFACE]='--wireguard-iface'
    [TAILSCALE_CIDR]=''
    [TAILSCALE_IPV6_CIDR]=''
    [INSTALL_DOCKER]='--no-docker'
    [INSTALL_TAILSCALE]='--no-tailscale'
    [INSTALL_FAIL2BAN]='--no-fail2ban'
    [INSTALL_AUTO_UPDATES]='--no-auto-updates'
    [RESET_FIREWALL]='--reset-firewall'
    [SKIP_UPGRADE]='--skip-upgrade'
    [ALLOW_CURRENT_SSH]='--allow-current-ssh'
    [DOCKER_CONFIG]='--no-docker-config'
    [DOCKER_POOL]='--docker-pool'
    [DOCKER_BIND_LOCALHOST]='--docker-bind-localhost'
    [DOCKER_USER]='--docker-user'
    [CREATE_USER]='--create-user'
    [SSH_KEY_FILE]='--ssh-key-file'
    [SSH_KEYS_ONLY]='--ssh-keys-only'
    [SUDO_NOPASSWD]='--no-sudo-nopasswd'
    [ALLOW_USERS]='--allow-users'
    [AUTO_REBOOT]='--auto-reboot'
    [MAIL_ADDR]='--mail'
    [UPDATE_THIRD_PARTY]='--update-third-party'
)
c6_flags_fail=0
help_c6="$(bash "$SCRIPT" --help)"
pc_c6="$(bash "$SCRIPT" --print-config)"
for c6_key in "${!C6_FLAG2KEY[@]}"; do
    c6_flag="${C6_FLAG2KEY[$c6_key]}"
    if ! printf '%s\n' "${CONFIG_KEYS[@]}" | grep -qx "$c6_key"; then
        c6_flags_fail=1; echo "   ↳ lipsește din CONFIG_KEYS: $c6_key"
    fi
    if ! printf '%s\n' "$pc_c6" | grep -q "^${c6_key}="; then
        c6_flags_fail=1; echo "   ↳ lipsește din --print-config: $c6_key"
    fi
    if [[ -n "$c6_flag" ]] && ! contains "$help_c6" "$c6_flag"; then
        c6_flags_fail=1; echo "   ↳ lipsește din usage: $c6_flag"
    fi
done
if [[ "$c6_flags_fail" == "0" ]]; then
    t_pass "Curățenie: toate cheile/flag-urile sunt în CONFIG_KEYS + --print-config + usage"
else
    t_fail "Curățenie: toate cheile/flag-urile sunt în CONFIG_KEYS + --print-config + usage"
fi

# ============================================================
echo "== C6b: exemple --config + README fără divergență =="
c6b_ok=1
for c6b_ex in examples/lan.conf examples/vps.conf examples/vps-fleet.conf; do
    for c6b_fix in os-release.debian12 os-release.ubuntu24.04; do
        out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
            DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/$c6b_fix" \
            bash "$SCRIPT" --config "$ROOT/$c6b_ex" --print-config 2>&1)" || c6b_ok=0
        out2="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
            DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/$c6b_fix" \
            bash "$SCRIPT" --dry-run -y --config "$ROOT/$c6b_ex" 2>&1)" || c6b_ok=0
        [[ -n "$out" && -n "$out2" ]] || c6b_ok=0
    done
done
if [[ "$c6b_ok" == "1" ]]; then
    t_pass "C6b: exemplele se încarcă cu --config (print-config + dry-run) pe debian12/ubuntu24.04"
else
    t_fail "C6b: exemplele se încarcă cu --config (print-config + dry-run) pe debian12/ubuntu24.04"
fi

# README-ul menționează fiecare flag din usage (fără divergență)
c6b_readme="$(cat "$ROOT/README.md" 2>/dev/null)"
c6b_help="$(bash "$SCRIPT" --help)"
c6b_flags="$(printf '%s\n' "$c6b_help" | awk '/^  -/ { for (i = 1; i <= NF; i++) { f = $i; sub(/,$/, "", f); if (f ~ /^-{1,2}[A-Za-z0-9][A-Za-z0-9-]*$/) print f } }')"
c6b_missing=""
while IFS= read -r c6b_f; do
    [[ -z "$c6b_f" ]] && continue
    contains "$c6b_readme" "$c6b_f" || c6b_missing+="${c6b_f} "
done <<<"$c6b_flags"
if [[ -n "$c6b_readme" && -n "$c6b_flags" && -z "$c6b_missing" ]]; then
    t_pass "C6b: README-ul menționează toate flag-urile din usage"
else
    t_fail "C6b: README-ul menționează toate flag-urile din usage (lipsesc: ${c6b_missing:-?})"
fi

# ============================================================
echo "== C7a: F1-F6 fix-uri =="

# F1: verificare statică — fiecare 'apt-get "${APT_OPTS[@]}" X' are X valid
c7_bad_f1="$(grep 'run apt-get "${APT_OPTS[@]}"' "$SCRIPT" \
    | grep -vE 'apt-get "\$\{APT_OPTS\[@\]\}" (update|full-upgrade|install|remove)( |$)' || true)"
if [[ -z "$c7_bad_f1" ]]; then
    t_pass "F1: static — toate aparițiile apt-get au subcomandă validă"
else
    t_fail "F1: static — apariții apt-get fără subcomandă validă: $c7_bad_f1"
fi

# F1: fiecare linie apt-get/ufw/systemctl din plan are subcomandă validă
# (4 fixture-uri, toate componentele activate)
f1_check_plan() {
    local plan="$1" bad=0 line sub k ok_tok
    while IFS= read -r line; do
        line="${line#\[*\] }"
        case "$line" in
            apt-get\ *)
                set -- $line
                shift
                sub=""
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        -o) shift 2 ;;
                        -*) shift ;;
                        *) sub="$1"; break ;;
                    esac
                done
                case "$sub" in
                    update|full-upgrade|install|remove) ;;
                    *) bad=1; echo "   ↳ apt-get subcomandă invalidă: '$sub' ($line)" ;;
                esac
                ;;
            ufw\ *)
                set -- $line
                shift
                ok_tok=no
                for ((k = 1; k <= 2 && k <= $#; k++)); do
                    case "${!k}" in
                        default|logging|allow|--force|status|reset|limit|deny) ok_tok=yes ;;
                    esac
                done
                if [[ "$ok_tok" != "yes" ]]; then
                    bad=1; echo "   ↳ ufw subcomandă invalidă: ($line)"
                fi
                ;;
            systemctl\ *)
                set -- $line
                shift
                case "${1:-}" in
                    enable|restart|reload|is-active|start|stop|disable|daemon-reload) ;;
                    *) bad=1; echo "   ↳ systemctl subcomandă invalidă: '${1:-}' ($line)" ;;
                esac
                ;;
        esac
    done <<<"$plan"
    if [[ "$bad" == "0" ]]; then
        return 0
    fi
    return 1
}
c7_f1_bad=0
for c7_fix in os-release.debian12 os-release.debian13 os-release.ubuntu22.04 os-release.ubuntu24.04; do
    c7_plan="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
        DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/$c7_fix" \
        bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 --wireguard-cidr 10.8.0.0/24 \
        --docker-pool 10.200.0.0/16 --docker-bind-localhost --auto-reboot 03:30 --mail ops@example.com \
        --update-third-party 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
    f1_check_plan "$c7_plan" || c7_f1_bad=1
done
if [[ "$c7_f1_bad" == "0" ]]; then
    t_pass "F1: dry-run pe 4 fixture-uri — subcomenzi apt-get/ufw/systemctl valide"
else
    t_fail "F1: dry-run pe 4 fixture-uri — subcomenzi apt-get/ufw/systemctl valide"
fi

# F2: --allow-current-ssh acoperă și peer-ii established neacoperiți (→ /32 în UFW)
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/mocks:$PATH" DS_SSH_CHAIN=none \
    DS_CMD_SS="$TMP_RUN/mocks/fake-ss" FAKE_SS_FILE="$TMP_RUN/ss-two" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 --allow-current-ssh 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] \
    && contains "$out" 'ufw allow from 203.0.113.9/32' \
    && contains "$out" 'ufw allow from 198.51.100.7/32'; then
    t_pass "F2: --allow-current-ssh → /32 pentru peer-ii established neacoperiți"
else
    t_fail "F2: --allow-current-ssh → /32 pentru peer-ii established neacoperiți (rc=$rc)"
fi

# F2: -y, rulare reală, peers neacoperiți → exit 4 (unit)
rc=0
out="$(
    source "$SCRIPT"
    DRY_RUN=no NONINTERACTIVE=yes ALLOW_CURRENT_SSH=no SKIP_FIREWALL=no
    UNCOVERED_PEERS='203.0.113.9 198.51.100.7 '
    SSH_CIDRS=(192.168.1.0/24)
    check_current_session_allowed 2>/dev/null
    printf 'OK'
)"; rc=$?
check_sub "F2: peers neacoperiți + -y → exit 4" "" 4 "$out" "$rc"

# F3: unit ssh_login_capable_users
rc=0
out="$(
    source "$SCRIPT"
    CREATE_USER=admin SSH_KEY_FILE=cheie SSH_KEY='' ALLOW_USERS=alice
    export DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" FAKE_GETENT_HOME=/nonexistent
    ssh_login_capable_users
)" || rc=$?
check_sub "F3: admin capabil dar exclus de --allow-users → mulțime vidă (rc 1)" "" 1 "$out" "$rc"

rc=0
out="$(
    source "$SCRIPT"
    CREATE_USER=admin SSH_KEY_FILE=cheie SSH_KEY='' ALLOW_USERS=alice,admin
    export DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" FAKE_GETENT_HOME=/nonexistent
    ssh_login_capable_users
)" || rc=$?
check_sub "F3: admin capabil și permis → admin" "admin" 0 "$out" "$rc"

rc=0
out="$(
    source "$SCRIPT"
    CREATE_USER='' ALLOW_USERS=''
    export DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" FAKE_GETENT_HOME="$TMP_RUN/home/dan"
    export DS_CMD_SSH_KEYGEN="$TMP_RUN/mocks/fake-keygen-ok"
    mkdir -p "$TMP_RUN/home/dan/.ssh"
    printf 'ssh-ed25519 AAAATEST x\n' >"$TMP_RUN/home/dan/.ssh/authorized_keys"
    ssh_login_capable_users
)" || rc=$?
if [[ "$rc" == "0" ]] && contains "$out" 'root' && contains "$out" 'dan'; then
    t_pass "F3: root+sudo (cu cheie validă) → capabili"
else
    t_fail "F3: root+sudo (cu cheie validă) → capabili (rc=$rc, out=«$out»)"
fi

# F3: cazul raportat — keys-only + --allow-users care exclude pe toți → exit 4
out="$(env -u SSH_CONNECTION -u SSH_CLIENT SUDO_USER=alice PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_CMD_SSH_KEYGEN="$TMP_RUN/mocks/fake-keygen-ok" \
    DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" FAKE_GETENT_HOME=/nonexistent \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode vps --create-user admin \
    --ssh-key 'ssh-ed25519 AAAATEST x' --ssh-keys-only --allow-users alice 2>&1)"; rc=$?
if [[ "$rc" == "4" ]] && contains "$out" 'Precondiția --ssh-keys-only nu este îndeplinită'; then
    t_pass "F3: keys-only + --allow-users care exclude tot → exit 4"
else
    t_fail "F3: keys-only + --allow-users care exclude tot → exit 4 (rc=$rc)"
fi

# F3: variantă validă — alice,admin → rc 0
out="$(env -u SSH_CONNECTION -u SSH_CLIENT SUDO_USER=alice PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_CMD_SSH_KEYGEN="$TMP_RUN/mocks/fake-keygen-ok" \
    DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" FAKE_GETENT_HOME=/nonexistent \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode vps --create-user admin \
    --ssh-key 'ssh-ed25519 AAAATEST x' --ssh-keys-only --allow-users alice,admin 2>&1)"; rc=$?
if [[ "$rc" == "0" ]]; then
    t_pass "F3: keys-only + --allow-users alice,admin → rc 0"
else
    t_fail "F3: keys-only + --allow-users alice,admin → rc 0 (rc=$rc)"
fi

# F3: sesiune SSH ca user exclus de capacitate → exit 4
out="$(env SSH_CONNECTION='203.0.113.9 50000 10.0.0.1 22' SUDO_USER=alice PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_CMD_SSH_KEYGEN="$TMP_RUN/mocks/fake-keygen-ok" \
    DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode vps --create-user admin \
    --ssh-key 'ssh-ed25519 AAAATEST x' --ssh-keys-only --allow-users alice,admin \
    --lan-cidr 192.168.1.0/24 2>&1)"; rc=$?
if [[ "$rc" == "4" ]] && contains "$out" "contul curent 'alice'"; then
    t_pass "F3: sesiune SSH ca user fără cheie → exit 4 cu mesaj"
else
    t_fail "F3: sesiune SSH ca user fără cheie → exit 4 cu mesaj (rc=$rc)"
fi

# F4: user nou → sudoers NOPASSWD (conținut + mod 0440) + parolă blocată
rc=0
C7F4="$(
    (
        source "$SCRIPT"
        DRY_RUN=no CREATE_USER=c7user SSH_KEY='ssh-ed25519 AAAATEST x' SSH_KEY_FILE=''
        export DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" \
            FAKE_GETENT_FAIL_FIRST=1 FAKE_GETENT_STATE="$TMP_RUN/getent.state" \
            FAKE_GETENT_HOME="$TMP_RUN/home/c7user"
        export DS_CMD_VISUDO="$TMP_RUN/mocks/fake-visudo" FAKE_VISUDO_RC=0
        export DS_SUDOERS_DIR="$TMP_RUN/sudoers.d"
        run() {
            case "${1:-}" in
                useradd|usermod|passwd|chown) printf 'MOCK %s\n' "$*"; return 0 ;;
            esac
            if [[ "${1:-}" == install && " $* " == *' -o '* ]]; then
                printf 'MOCK %s\n' "$*"; return 0
            fi
            command "$@"
        }
        configure_created_user 2>/dev/null
    ) 2>&1
)" || rc=$?
if [[ "$rc" == "0" \
    && "$(cat "$TMP_RUN/sudoers.d/90-bootstrap-c7user" 2>/dev/null)" == 'c7user ALL=(ALL) NOPASSWD:ALL' \
    && "$(stat -c %a "$TMP_RUN/sudoers.d/90-bootstrap-c7user" 2>/dev/null)" == "440" \
    && "$C7F4" == *'MOCK passwd -l c7user'* ]]; then
    t_pass "F4: user nou → sudoers NOPASSWD (0440) + passwd -l"
else
    t_fail "F4: user nou → sudoers NOPASSWD (0440) + passwd -l (rc=$rc)"
fi

# F4: user existent cu parolă activă → fără sudoers, fără blocare
rm -f "$TMP_RUN/sudoers.d/90-bootstrap-c7user"
rc=0
C7F4B="$(
    (
        source "$SCRIPT"
        DRY_RUN=no CREATE_USER=c7user SSH_KEY='' SSH_KEY_FILE=''
        export DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" FAKE_GETENT_HOME="$TMP_RUN/home/c7user"
        export DS_CMD_PASSWD="$TMP_RUN/mocks/fake-passwd-P"
        user_has_valid_key() { return 0; }   # cheie deja existentă
        run() {
            case "${1:-}" in
                usermod|chown) printf 'MOCK %s\n' "$*"; return 0 ;;
            esac
            command "$@"
        }
        configure_created_user 2>/dev/null
    ) 2>&1
)" || rc=$?
if [[ "$rc" == "0" && ! -f "$TMP_RUN/sudoers.d/90-bootstrap-c7user" \
    && "$C7F4B" == *'parolă activă: nu blochez parola și nu acord NOPASSWD'* ]]; then
    t_pass "F4: user existent cu parolă activă → fără sudoers, fără blocare"
else
    t_fail "F4: user existent cu parolă activă → fără sudoers, fără blocare (rc=$rc)"
fi

# F4: --no-sudo-nopasswd → nici sudoers, nici blocare, cu warn
out="$(env -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP_RUN/bin-novirt:$PATH" DS_SSH_CHAIN=none \
    DS_CMD_SSH_KEYGEN="$TMP_RUN/mocks/fake-keygen-ok" \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" --dry-run -y --mode lan --lan-cidr 192.168.1.0/24 \
    --create-user c7user --ssh-key 'ssh-ed25519 AAAATEST x' --no-sudo-nopasswd 2>&1)"; rc=$?
if [[ "$rc" == "0" ]] && contains "$out" 'nu scriu sudoers' \
    && ! contains "$out" 'Scriu sudoers NOPASSWD'; then
    t_pass "F4: --no-sudo-nopasswd → fără sudoers, fără blocare, cu warn"
else
    t_fail "F4: --no-sudo-nopasswd → fără sudoers, fără blocare, cu warn (rc=$rc)"
fi

# F4: visudo eșuat → exit 1, fără instalare
rc=0
(
    source "$SCRIPT"
    DRY_RUN=no CREATE_USER=c7user SSH_KEY='ssh-ed25519 AAAATEST x' SSH_KEY_FILE=''
    export DS_CMD_GETENT="$TMP_RUN/mocks/fake-getent-c5" \
        FAKE_GETENT_FAIL_FIRST=1 FAKE_GETENT_STATE="$TMP_RUN/getent.state2" \
        FAKE_GETENT_HOME="$TMP_RUN/home/c7user"
    export DS_CMD_VISUDO="$TMP_RUN/mocks/fake-visudo" FAKE_VISUDO_RC=1
    export DS_SUDOERS_DIR="$TMP_RUN/sudoers.d-fail"
    run() {
        case "${1:-}" in
            useradd|usermod|passwd|chown) return 0 ;;
        esac
        if [[ "${1:-}" == install && " $* " == *' -o '* ]]; then return 0; fi
        command "$@"
    }
    configure_created_user >/dev/null 2>&1
) || rc=$?
if [[ "$rc" == "1" && ! -f "$TMP_RUN/sudoers.d-fail/90-bootstrap-c7user" ]]; then
    t_pass "F4: visudo eșuat → exit 1, sudoers neinstalat"
else
    t_fail "F4: visudo eșuat → exit 1, sudoers neinstalat (rc=$rc)"
fi

# F5: DS_* la rulare reală → exit 2, cu mesaj clar
out="$(env -u SSH_CONNECTION -u SSH_CLIENT -u DS_TEST DS_ROOT_OK=1 \
    DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" -y --mode lan --lan-cidr 192.168.1.0/24 2>&1)"; rc=$?
if [[ "$rc" == "2" ]] && contains "$out" 'DS_*'; then
    t_pass "F5: DS_* la rulare reală → exit 2"
else
    t_fail "F5: DS_* la rulare reală → exit 2 (rc=$rc)"
fi

# F5: DS_TEST=1 permite mediul de test (ajunge la require_root → exit 3)
expect_rc "F5: DS_TEST=1 → guard permis (ajunge la require_root, exit 3)" 3 \
    env -u SSH_CONNECTION -u SSH_CLIENT DS_TEST=1 DS_ROOT_OK=1 \
    DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" -y --mode lan --lan-cidr 192.168.1.0/24

# F5: DS_TAILSCALE_OLD_LIST în afara căii permise → exit 2
expect_rc "F5: DS_TAILSCALE_OLD_LIST în afara /etc/apt/sources.list.d/ → exit 2" 2 \
    env -u SSH_CONNECTION -u SSH_CLIENT DS_TEST=1 DS_TAILSCALE_OLD_LIST=/tmp/ceva \
    DS_ROOT_OK=1 DS_OS_RELEASE="$FIXTURES/os-release.debian12" \
    bash "$SCRIPT" -y --mode lan --lan-cidr 192.168.1.0/24

# F6: suita rulată cu mediu poluat → trebuie să treacă integral
# (C7_F6_NESTED evită recursiunea: copilul nu mai spawnează o sub-suită)
if [[ "${C7_F6_NESTED:-}" == "1" ]]; then
    t_pass "F6: suită imbricată cu mediu poluat (recursiune evitată)"
else
    if C7_F6_NESTED=1 env DS_ROOT_OK=1 DS_OS_RELEASE=MEDIU_POLUAT bash tests/run.sh >/dev/null 2>&1; then
        t_pass "F6: suita trece integral cu DS_ROOT_OK=1/DS_OS_RELEASE exportate în mediu"
    else
        t_fail "F6: suita trece integral cu DS_ROOT_OK=1/DS_OS_RELEASE exportate în mediu"
    fi
fi

# ============================================================
printf '\nRezultat: %d ok, %d eșuate\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    exit 0
fi
exit 1
