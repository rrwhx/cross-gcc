#!/usr/bin/env bash
# Fetch the latest release versions of toolchain components.
# Supports: Linux kernel, GCC, binutils, glibc, musl
# Compatible with both Linux and macOS.

set -euo pipefail

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not installed" >&2
    exit 1
fi

# Mirror / upstream URLs
GNU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/gnu"
KERNEL_API="https://www.kernel.org/releases.json"
MUSL_TAGS="https://git.musl-libc.org/cgit/musl/refs/tags"

# Timeout for HTTP requests (seconds)
CURL_TIMEOUT=15

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Fetch the latest release versions of Linux kernel, GCC, binutils, glibc, and musl.

Options:
  --json          Output in JSON format
  --shell         Output as shell variable assignments (can be used with eval)
  -h, --help      Show this help message
EOF
    exit 0
}

OUTPUT_FORMAT="table"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)   OUTPUT_FORMAT="json"; shift;;
        --shell)  OUTPUT_FORMAT="shell"; shift;;
        -h|--help) usage;;
        *) echo "Unknown option: $1" >&2; usage;;
    esac
done

# Fetch page content from a URL with timeout
fetch_page() {
    local url="$1"
    local content
    if command -v curl > /dev/null; then
        content=$(curl -fsSL --max-time "$CURL_TIMEOUT" "$url" 2>/dev/null) || return 1
    elif command -v wget > /dev/null; then
        content=$(wget -qO- --timeout="$CURL_TIMEOUT" "$url" 2>/dev/null) || return 1
    else
        echo "Error: neither curl nor wget is installed" >&2
        return 1
    fi
    echo "$content"
}

# Cross-platform version extraction (macOS grep lacks -P)
# Uses python3 regex, available on both macOS and Linux
extract_versions() {
    local pattern="$1"
    python3 -c "
import re, sys
for line in sys.stdin:
    for match in re.findall(r'$pattern', line):
        print(match)
" 2>/dev/null
}

# Get the latest stable Linux kernel version (skip RC releases)
get_linux_version() {
    local page
    page=$(fetch_page "$KERNEL_API") || { echo "FETCH_FAILED"; return 1; }

    echo "$page" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for release in data['releases']:
    version = release['version']
    moniker = release['moniker']
    if 'rc' not in version and moniker in ('stable', 'longterm'):
        print(version)
        break
" 2>/dev/null || echo "PARSE_FAILED"
}

# Get the latest version from a GNU mirror
# GCC uses directory links (gcc-X.Y.Z/), others use tarball links
get_gnu_latest() {
    local component="$1"
    local page
    page=$(fetch_page "${GNU_MIRROR}/${component}/") || { echo "FETCH_FAILED"; return 1; }

    if [[ "$component" == "gcc" ]]; then
        echo "$page" | extract_versions 'gcc-([0-9]+\.[0-9]+\.[0-9]+)' | sort -V | tail -1
    else
        echo "$page" | extract_versions "${component}-([0-9]+\.[0-9]+[0-9.]*)\.tar" | sort -V | tail -1
    fi
}

# Get the latest musl version from git tags
get_musl_version() {
    local page
    page=$(fetch_page "$MUSL_TAGS") || { echo "FETCH_FAILED"; return 1; }
    echo "$page" | extract_versions 'v([0-9]+\.[0-9]+\.[0-9]+)' | sort -V | tail -1
}

# Fetch all versions (exit on failure)
fetch_failed=false

LINUX_VER=$(get_linux_version) || fetch_failed=true
GCC_VER=$(get_gnu_latest "gcc") || fetch_failed=true
BINUTILS_VER=$(get_gnu_latest "binutils") || fetch_failed=true
GLIBC_VER=$(get_gnu_latest "glibc") || fetch_failed=true
MUSL_VER=$(get_musl_version) || fetch_failed=true

for var in LINUX_VER GCC_VER BINUTILS_VER GLIBC_VER MUSL_VER; do
    val="${!var}"
    if [[ -z "$val" || "$val" == *"FAILED"* ]]; then
        echo "Error: failed to fetch $var (got: '$val')" >&2
        fetch_failed=true
    fi
done

if [[ "$fetch_failed" == true ]]; then
    echo "Error: one or more version fetches failed" >&2
    exit 1
fi

# Output results
case "$OUTPUT_FORMAT" in
    table)
        echo ""
        echo "┌────────────────┬────────────────┐"
        echo "│ Component      │ Latest Version │"
        echo "├────────────────┼────────────────┤"
        printf "│ %-14s │ %-14s │\n" "Linux kernel" "$LINUX_VER"
        printf "│ %-14s │ %-14s │\n" "GCC" "$GCC_VER"
        printf "│ %-14s │ %-14s │\n" "binutils" "$BINUTILS_VER"
        printf "│ %-14s │ %-14s │\n" "glibc" "$GLIBC_VER"
        printf "│ %-14s │ %-14s │\n" "musl" "$MUSL_VER"
        echo "└────────────────┴────────────────┘"
        ;;
    json)
        cat <<EOF
{
  "linux": "$LINUX_VER",
  "gcc": "$GCC_VER",
  "binutils": "$BINUTILS_VER",
  "glibc": "$GLIBC_VER",
  "musl": "$MUSL_VER"
}
EOF
        ;;
    shell)
        echo "export LINUX_VER=\"$LINUX_VER\""
        echo "export GCC_VER=\"$GCC_VER\""
        echo "export BINUTILS_VER=\"$BINUTILS_VER\""
        echo "export GLIBC_VER=\"$GLIBC_VER\""
        echo "export MUSL_VER=\"$MUSL_VER\""
        ;;
esac
