#!/usr/bin/env bash
set -euo pipefail

if command -v readlink >/dev/null 2>&1; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
fi
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# 默认配置
# ---------------------------------------------------------------------------
declare -a default_arch_list=(aarch64 loongarch64 riscv64 x86_64)
GCC_DIR_PATTERN=""

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
declare -a version_list=()
declare -a arch_list=()
declare -a extra_args=()

usage() {
    cat <<EOF
用法: $(basename "$0") --version VER --arch ARCHS [选项] [其他选项传递给 build-toolchain-llvm.sh]

批量构建多版本 × 多架构 LLVM/Clang 工具链

  -v,--version <VER>     LLVM 版本（逗号分隔，必填，支持 'git'）
  -a,--arch <ARCHS>      目标架构列表（逗号分隔，默认: ${default_arch_list[*]}）
  --gcc-dir <PATTERN>    GCC 工具链目录模板（必填，{ARCH} 会被替换为当前架构）
  -h,--help              显示帮助

其他选项将直接传递给 build-toolchain-llvm.sh，例如：
  --mirror, --fresh, --clean, --archive, --link-jobs, -j, --work-dir

示例:
  $(basename "$0") -v 22.1.8 -a riscv64,aarch64
  $(basename "$0") -v 22.1.8,21.1.8 -a aarch64,loongarch64,riscv64,x86_64
  $(basename "$0") -v git:update -a riscv64 --fresh
  $(basename "$0") -v 22.1.8 -a riscv64 --gcc-dir ./gcc_161/cross-{ARCH}-linux-gnu
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)
            IFS=',' read -ra version_list <<< "$2"; shift 2;;
        -a|--arch)
            IFS=',' read -ra arch_list <<< "$2"; shift 2;;
        --gcc-dir)
            GCC_DIR_PATTERN="$2"; shift 2;;
        -h|--help) usage;;
        *)
            extra_args+=("$1"); shift;;
    esac
done

if [[ ${#version_list[@]} -eq 0 ]]; then
    error "--version 参数为必需。"
fi

if [[ -z "$GCC_DIR_PATTERN" ]]; then
    error "--gcc-dir 参数为必需。"
fi

[[ ${#arch_list[@]} -eq 0 ]] && arch_list=("${default_arch_list[@]}")

# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------
declare -a failed_list=()

info "==============================================="
info "LLVM 版本: ${version_list[*]}"
info "目标架构: ${arch_list[*]}"
info "GCC 目录模板: $GCC_DIR_PATTERN"
info "==============================================="

for ver in "${version_list[@]}"; do
    for arch in "${arch_list[@]}"; do
        gcc_dir="${GCC_DIR_PATTERN//\{ARCH\}/$arch}"

        step "======================================================================"
        info "开始构建 LLVM：VER=$ver, ARCH=$arch"
        step "======================================================================"

        if "$SCRIPT_DIR/build-toolchain-llvm.sh" \
            --arch "$arch" \
            --llvm-ver "$ver" \
            --target-gcc-toolchain "$gcc_dir" \
            --target-sysroot "$gcc_dir/${arch}-linux-gnu" \
            "${extra_args[@]}"; then
            ok "构建成功：LLVM $ver / $arch"
        else
            warn "构建失败：LLVM $ver / $arch"
            failed_list+=("LLVM $ver / $arch")
        fi
    done
done

if [[ ${#failed_list[@]} -gt 0 ]]; then
    warn "==============================================="
    warn "以下构建任务失败 (${#failed_list[@]}):"
    for item in "${failed_list[@]}"; do
        warn "  - $item"
    done
    warn "==============================================="
    exit 1
fi

ok "==============================================="
info "全部 LLVM 构建任务已完成！"
ok "==============================================="
