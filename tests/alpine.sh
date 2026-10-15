#!/bin/sh
# Independent Alpine backend checks: POSIX sh, mocked commands, no live apply.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/alpine-setup.sh
TMP=$(mktemp -d)
# Keep temporary evidence; no host configuration, packages or services are changed.
for name in $(env | sed -n 's/^\(DS_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$name"; done
export DS_TEST=1 DS_OS_RELEASE="$TMP/os-release" DS_REPOSITORIES="$TMP/repositories"
export CALLS="$TMP/mutations" SERVICES_RUNNING=no SERVICES_ENABLED=no
: >"$CALLS"
mkdir "$TMP/bin"
cat >"$TMP/bin/apk" <<'EOF'
#!/bin/sh
case "$1" in
    info) exit 1 ;;
    update|add|upgrade) printf 'apk %s\n' "$*" >>"$CALLS" ;;
    *) exit 97 ;;
esac
EOF
cat >"$TMP/bin/rc-service" <<'EOF'
#!/bin/sh
case "$2" in
    status) [ "$SERVICES_RUNNING" = yes ] ;;
    start) printf 'rc-service %s\n' "$*" >>"$CALLS" ;;
    *) exit 97 ;;
esac
EOF
cat >"$TMP/bin/rc-update" <<'EOF'
#!/bin/sh
case "$1" in
    show) [ "$SERVICES_ENABLED" != yes ] || printf 'docker | default\ntailscale | default\n' ;;
    add) printf 'rc-update %s\n' "$*" >>"$CALLS" ;;
    *) exit 97 ;;
esac
EOF
chmod +x "$TMP/bin/apk" "$TMP/bin/rc-service" "$TMP/bin/rc-update"
PATH=$TMP/bin:$PATH
export PATH
passed=0

os_fixture() { printf 'ID=alpine\nVERSION_ID=%s\nPRETTY_NAME="Alpine Linux"\n' "$1" >"$DS_OS_RELEASE"; }
stable_repos() { printf 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main\nhttps://dl-cdn.alpinelinux.org/alpine/v3.24/community\n' >"$DS_REPOSITORIES"; }
expect_rc() {
    desc=$1 want=$2
    shift 2
    rc=0
    "$@" >"$TMP/output" 2>&1 || rc=$?
    if [ "$rc" -ne "$want" ]; then
        printf 'FAIL: %s (exit %s, expected %s)\n' "$desc" "$rc" "$want" >&2
        cat "$TMP/output" >&2
        exit 1
    fi
    passed=$((passed + 1))
}
contains() { grep -Fq -- "$1" "$TMP/output" || { printf 'FAIL: missing %s\n' "$1" >&2; exit 1; }; }
no_mutation() { [ ! -s "$CALLS" ] || { printf 'FAIL: unexpected mocked mutation\n' >&2; cat "$CALLS" >&2; exit 1; }; }
unit() { sh -c '. "$1"; shift; eval "$1"' unit "$SCRIPT" "$1"; }

os_fixture 3.24.2
stable_repos
expect_rc version 0 sh "$SCRIPT" --version
contains 'alpine-setup.sh 2.8.1'
expect_rc help 0 sh "$SCRIPT" --help
contains 'OpenRC'
expect_rc source-guard 0 unit 'printf sourced'
contains sourced
expect_rc inspect 0 sh "$SCRIPT" --inspect
contains 'READ-ONLY INVENTORY'
no_mutation
expect_rc inspect-no-write-path 0 unit 'run() { exit 91; }; open_log() { exit 92; }; require_root() { exit 93; }; main --inspect'
expect_rc no-op-no-root-or-log 0 unit 'run() { exit 91; }; open_log() { exit 92; }; require_root() { exit 93; }; main -y --mode lan'
no_mutation
if grep -Fq 'DRY-RUN' "$TMP/output"; then printf 'FAIL: actual no-op mislabeled as dry-run\n' >&2; exit 1; fi
expect_rc print-config 0 sh "$SCRIPT" --print-config
contains 'MANAGE_SSH=no'
contains 'SKIP_FIREWALL=yes'
contains 'INSTALL_AUTO_UPDATES=no'
expect_rc explicit-mode-required 2 sh "$SCRIPT" --dry-run -y
expect_rc invalid-mode 2 sh "$SCRIPT" --dry-run -y --mode bad
expect_rc wizard-noninteractive-conflict 2 sh "$SCRIPT" --wizard -y --mode lan
expect_rc missing-config 2 sh "$SCRIPT" --config
expect_rc missing-mode 2 sh "$SCRIPT" --mode
for flag in --reset-firewall --manage-ssh --ssh-keys-only --create-user --allow-current-ssh --auto-reboot --docker-user --docker-pool --strict --bogus; do
    expect_rc "unsupported-$flag" 2 sh "$SCRIPT" --docker "$flag"
    no_mutation
done

for ver in 3.24 3.24.2 3.24.10; do
    os_fixture "$ver"
    expect_rc "supported-$ver" 0 sh "$SCRIPT" --inspect
done
for ver in 3.23.6 3.25.0 3.24.0_alpha1 edge 3.24.bad; do
    os_fixture "$ver"
    expect_rc "unsupported-$ver" 3 sh "$SCRIPT" --inspect
done
printf 'ID=debian\nVERSION_ID=13\n' >"$DS_OS_RELEASE"
expect_rc other-os 3 sh "$SCRIPT" --inspect
os_fixture 3.24.2

printf 'INSTALL_DOCKER=yes\nINSTALL_TAILSCALE=yes\nSKIP_UPGRADE=no\n' >"$TMP/on.conf"
expect_rc config-before-cli 0 sh "$SCRIPT" --config "$TMP/on.conf" --no-docker --no-tailscale --skip-upgrade --print-config
contains 'INSTALL_DOCKER=no'
contains 'INSTALL_TAILSCALE=no'
contains 'SKIP_UPGRADE=yes'
expect_rc config-after-cli 0 sh "$SCRIPT" --no-docker --config "$TMP/on.conf" --print-config
contains 'INSTALL_DOCKER=no'
export CONFIG_ON="$TMP/on.conf"
# shellcheck disable=SC2016 # The child shell expands CONFIG_ON, not this harness.
expect_rc config-preserved-choice 0 unit 'scan_configs --config "$CONFIG_ON"; WIZARD=yes; read_answer() { exit 91; }; run_wizard; print_config'
for setting in MANAGE_SSH=yes SKIP_FIREWALL=no INSTALL_FAIL2BAN=yes INSTALL_AUTO_UPDATES=yes EVIL_KEY=yes INSTALL_DOCKER=maybe; do
    printf '%s\n' "$setting" >"$TMP/bad.conf"
    expect_rc "rejected-config-$setting" 2 sh "$SCRIPT" --config "$TMP/bad.conf" --print-config
    no_mutation
done
# shellcheck disable=SC2016 # Deliberately literal payload: config must never execute it.
printf 'INSTALL_DOCKER=$(touch %s)\n' "$TMP/injected" >"$TMP/inject.conf"
expect_rc config-no-eval 2 sh "$SCRIPT" --config "$TMP/inject.conf" --print-config
[ ! -e "$TMP/injected" ]
expect_rc production-override-rejected 2 env DS_TEST=0 sh "$SCRIPT" --inspect
expect_rc unknown-test-override-rejected 2 env DS_UNKNOWN=1 sh "$SCRIPT" --inspect

stable_repos
expect_rc docker-tailscale-plan 0 sh "$SCRIPT" --dry-run -y --mode lan --docker --tailscale
contains 'apk add openrc docker docker-cli-compose docker-openrc tailscale tailscale-openrc'
contains 'rc-update add docker default'
contains 'rc-service docker start'
contains 'rc-update add tailscale default'
contains 'rc-service tailscale start'
no_mutation
expect_rc unbooted-preflight-before-log 3 unit 'require_root() { return 0; }; require_booted_openrc() { exit 3; }; open_log() { exit 91; }; main -y --mode lan --docker'
no_mutation
expect_rc upgrade-plan 0 sh "$SCRIPT" --dry-run -y --mode lan --upgrade
contains 'apk upgrade'
no_mutation
printf 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main\n' >"$DS_REPOSITORIES"
expect_rc missing-community 3 sh "$SCRIPT" --dry-run -y --mode lan --docker
expect_rc upgrade-repo-validation 3 sh "$SCRIPT" --dry-run -y --mode lan --upgrade
for extra in 'https://dl-cdn.alpinelinux.org/alpine/edge/main' 'https://dl-cdn.alpinelinux.org/alpine/v3.23/main' 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main-typo'; do
    stable_repos
    printf '%s\n' "$extra" >>"$DS_REPOSITORIES"
    expect_rc mixed-repos 3 sh "$SCRIPT" --dry-run -y --mode lan --docker
done
printf 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main\n@community https://dl-cdn.alpinelinux.org/alpine/v3.24/community\n' >"$DS_REPOSITORIES"
expect_rc tagged-community-not-default 3 sh "$SCRIPT" --dry-run -y --mode lan --docker
stable_repos
printf '# https://dl-cdn.alpinelinux.org/alpine/edge/main\n' >>"$DS_REPOSITORIES"
expect_rc commented-edge-safe 0 sh "$SCRIPT" --dry-run -y --mode lan --docker
no_mutation
expect_rc wizard-eof 2 sh "$SCRIPT" --wizard --dry-run </dev/null
printf '\n\n\n' >"$TMP/answers"
expect_rc wizard-defaults 0 sh "$SCRIPT" --wizard --dry-run <"$TMP/answers"
contains 'Nothing to do'
no_mutation

# Isolated unit-level service lifecycle: overridden path probe, mocked OpenRC.
expect_rc service-start 0 unit 'svc_exists() { return 0; }; ensure_service docker'
grep -Fq 'rc-update add docker default' "$CALLS"
grep -Fq 'rc-service docker start' "$CALLS"
: >"$CALLS"
expect_rc tailscale-unit-name 0 unit 'svc_exists() { return 0; }; ensure_service tailscale'
grep -Fq 'rc-service tailscale start' "$CALLS"
: >"$CALLS"
export SERVICES_RUNNING=yes SERVICES_ENABLED=yes
expect_rc existing-service-not-restarted 0 unit 'svc_exists() { return 0; }; ensure_service docker'
no_mutation
expect_rc verify-failed-package 1 unit 'APK_PKGS="docker"; INSTALL_DOCKER=yes; verify_installation'
expect_rc verify-installed-running 0 unit 'APK_PKGS="docker tailscale"; INSTALL_DOCKER=yes; INSTALL_TAILSCALE=yes; apk() { return 0; }; svc_running() { return 0; }; verify_installation'

printf 'Alpine: %s checks passed (fixtures retained at %s)\n' "$passed" "$TMP"
