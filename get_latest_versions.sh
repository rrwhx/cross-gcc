#!/usr/bin/env bash
# 获取各组件的最新版本号
# 支持: Linux 内核、GCC、binutils、glibc、musl

set -euo pipefail

# 镜像源
GNU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/gnu"
KERNEL_API="https://www.kernel.org/releases.json"
MUSL_TAGS="https://git.musl-libc.org/cgit/musl/refs/tags"

# 超时设置（秒）
CURL_TIMEOUT=15

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

获取 Linux 内核、GCC、binutils、glibc、musl 的最新版本号。

选项:
  --json          以 JSON 格式输出
  --shell         以 shell 变量赋值格式输出（可直接 source）
  -h, --help      显示帮助
EOF
    exit 0
}

OUTPUT_FORMAT="table"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)   OUTPUT_FORMAT="json"; shift;;
        --shell)  OUTPUT_FORMAT="shell"; shift;;
        -h|--help) usage;;
        *) echo "未知参数: $1" >&2; usage·;;
    esac
done

# 从 URL 获取页面内容，带超时和错误处理
fetch_page() {
    local url="$1"
    local content
    if command -v curl > /dev/null; then
        content=$(curl -fsSL --max-time "$CURL_TIMEOUT" "$url" 2>/dev/null) || return 1
    elif command -v wget > /dev/null; then
        content=$(wget -qO- --timeout="$CURL_TIMEOUT" "$url" 2>/dev/null) || return 1
    else
        error "未安装 curl 或 wget"
    fi
    echo "$content"
}

# 获取 Linux 内核最新稳定版
get_linux_version() {
    local page
    page=$(fetch_page "$KERNEL_API") || { echo "获取失败"; return 1; }

    # 使用 python3 解析 JSON，找第一个非 rc 的 stable/longterm 版本
    if command -v python3 > /dev/null; then
        echo "$page" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for release in data['releases']:
    version = release['version']
    moniker = release['moniker']
    if 'rc' not in version and moniker in ('stable', 'longterm'):
        print(version)
        break
" 2>/dev/null || echo "解析失败"
    else
        # 无 python3 时用 grep 回退
        echo "$page" | grep -oP '"version"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

# 从 GNU 镜像获取最新版本
# GCC 页面是目录链接（gcc-X.Y.Z/），其他组件是 tar 包链接
get_gnu_latest() {
    local component="$1"
    local page
    page=$(fetch_page "${GNU_MIRROR}/${component}/") || { echo "获取失败"; return 1; }

    if [[ "$component" == "gcc" ]]; then
        echo "$page" | grep -oP 'gcc-\K[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1
    else
        echo "$page" | grep -oP "${component}-\K[0-9]+\.[0-9]+[0-9.]*(?=\.tar)" | sort -V | tail -1
    fi
}

# 获取 musl 最新版本
get_musl_version() {
    local page
    page=$(fetch_page "$MUSL_TAGS") || { echo "获取失败"; return 1; }
    echo "$page" | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1
}

LINUX_VER=$(get_linux_version)
GCC_VER=$(get_gnu_latest "gcc")
BINUTILS_VER=$(get_gnu_latest "binutils")
GLIBC_VER=$(get_gnu_latest "glibc")
MUSL_VER=$(get_musl_version)

# 输出结果
case "$OUTPUT_FORMAT" in
    table)
        echo ""
        echo "┌──────────────┬──────────────┐"
        echo "│ 组件         │ 最新版本     │"
        echo "├──────────────┼──────────────┤"
        printf "│ %-12s │ %-12s │\n" "Linux 内核" "$LINUX_VER"
        printf "│ %-12s │ %-12s │\n" "GCC" "$GCC_VER"
        printf "│ %-12s │ %-12s │\n" "binutils" "$BINUTILS_VER"
        printf "│ %-12s │ %-12s │\n" "glibc" "$GLIBC_VER"
        printf "│ %-12s │ %-12s │\n" "musl" "$MUSL_VER"
        echo "└──────────────┴──────────────┘"
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
        echo "LINUX_VER=\"$LINUX_VER\""
        echo "GCC_VER=\"$GCC_VER\""
        echo "BINUTILS_VER=\"$BINUTILS_VER\""
        echo "GLIBC_VER=\"$GLIBC_VER\""
        echo "MUSL_VER=\"$MUSL_VER\""
        ;;
esac
