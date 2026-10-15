#!/bin/sh
# Portable entry point: Alpine does not ship Bash by default.
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
os_file=/etc/os-release

# Match backend test-path policy. Never source a user-supplied os-release file.
if [ -n "${DS_OS_RELEASE:-}" ]; then
    allow_test_path=no
    [ "${DS_TEST:-}" != 1 ] || allow_test_path=yes
    for arg in "$@"; do
        [ "$arg" != --dry-run ] || allow_test_path=yes
    done
    if [ "$allow_test_path" != yes ]; then
        printf '%s\n' '[ERROR] DS_OS_RELEASE is a test override; use --dry-run or DS_TEST=1.' >&2
        exit 2
    fi
    os_file=$DS_OS_RELEASE
fi
if [ ! -r "$os_file" ]; then
    printf '%s\n' '[ERROR] Cannot read the operating system release file.' >&2
    exit 3
fi
os_id=$(awk -F= '$1 == "ID" { value=$2; gsub(/["\047]/, "", value); print value; exit }' "$os_file")
case "$os_id" in
    alpine)
        exec sh "$script_dir/alpine-setup.sh" "$@"
        ;;
    *)
        if ! command -v bash >/dev/null 2>&1; then
            printf '%s\n' '[ERROR] The Debian/Ubuntu backend requires Bash. Alpine users should run this launcher on Alpine.' >&2
            exit 3
        fi
        exec bash "$script_dir/debian-setup.sh" "$@"
        ;;
esac
