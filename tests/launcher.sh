#!/bin/sh
# Dispatcher checks; no package or service operations.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
passed=0

expected=$(sh alpine-setup.sh --version)
actual=$(DS_TEST=1 DS_OS_RELEASE="$ROOT/tests/fixtures/launcher-alpine" sh setup.sh --version)
[ "$actual" = "$expected" ]
passed=$((passed + 1))

# The normal host dispatches to its backend without interpreting os-release as code.
if command -v bash >/dev/null 2>&1; then
    expected=$(bash debian-setup.sh --version)
    actual=$(DS_TEST=1 DS_OS_RELEASE="$ROOT/tests/fixtures/os-release.debian12" sh setup.sh --version)
    [ "$actual" = "$expected" ]
    passed=$((passed + 1))
fi

rc=0
DS_TEST=0 DS_OS_RELEASE="$ROOT/tests/fixtures/launcher-alpine" sh setup.sh --version >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ]
passed=$((passed + 1))

rc=0
DS_TEST=1 DS_OS_RELEASE=/nonexistent/onboarding-os-release sh setup.sh --version >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ]
passed=$((passed + 1))

printf 'Launcher: %s checks passed\n' "$passed"
