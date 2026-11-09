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
LLVM_VERSION=""
declare -a arch_list=()
declare -a extra_args=()

usage() {
    cat <<EOF
用法: $(basename "$0") --llvm-ver VER --arch ARCHS [选项] [其他选项传递给 build-toolchain-llvm.sh]

批量构建单版本 × 多架构 LLVM/Clang 工具链

  --llvm-ver VER          LLVM 版本（单个版本，必填，支持 git[:REF]）
  -a,--arch ARCHS          目标架构列表（逗号分隔，默认: ${default_arch_list[*]}）
  --toolchain-dir PATTERN  GCC 工具链目录模板（必填，{ARCH} 会被替换为当前架构）
  -h,--help               显示帮助

其他选项将直接传递给 build-toolchain-llvm.sh，例如：
  --mirror, --fresh, --clean, --archive, --link-jobs, --static, -j/--jobs, --work-dir

示例:
  $(basename "$0") --llvm-ver 22.1.8 -a riscv64,aarch64 --toolchain-dir ./cross-{ARCH}-linux-gnu
  $(basename "$0") --llvm-ver git -a riscv64 --toolchain-dir ./cross-{ARCH}-linux-gnu --work-dir ./llvm-dev --fresh
  $(basename "$0") --llvm-ver 22.1.8 -a riscv64 --toolchain-dir ./cross-{ARCH}-linux-gnu --static --archive
  $(basename "$0") --llvm-ver 22.1.8 -a riscv64 --toolchain-dir ./gcc_161/cross-{ARCH}-linux-gnu
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --llvm-ver)
            require_option_value "$@"
            LLVM_VERSION="$2"; shift 2;;
        -a|--arch)
            require_option_value "$@"
            [[ -n "$2" && "$2" != ,* && "$2" != *, && "$2" != *,,* ]] || error "选项 $1 的列表不能为空或包含空项"
            IFS=',' read -ra arch_list <<< "$2"; shift 2;;
        --toolchain-dir)
            require_option_value "$@"
            GCC_DIR_PATTERN="$2"; shift 2;;
        -h|--help) usage;;
        *)
            extra_args+=("$1"); shift;;
    esac
done

require_positive_integer "构建线程数" "$THREADS"

if [[ -z "$LLVM_VERSION" ]]; then
    error "--llvm-ver 参数为必需。"
fi

[[ "$LLVM_VERSION" != *,* ]] || error "每次仅支持一个 LLVM 版本；请分别调用并指定不同的 --work-dir。"

if [[ -z "$GCC_DIR_PATTERN" ]]; then
    error "--toolchain-dir 参数为必需。"
fi

[[ ${#arch_list[@]} -eq 0 ]] && arch_list=("${default_arch_list[@]}")

# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------
declare -a failed_list=()
declare -a failed_cmds=()

info "==============================================="
info "LLVM 版本: $LLVM_VERSION"
info "目标架构: ${arch_list[*]}"
info "GCC 目录模板: $GCC_DIR_PATTERN"
info "==============================================="

for arch in "${arch_list[@]}"; do
    gcc_dir="${GCC_DIR_PATTERN//\{ARCH\}/$arch}"

    step "======================================================================"
    info "开始构建 LLVM：VER=$LLVM_VERSION, ARCH=$arch"
    step "======================================================================"

    # 先打印完整命令: 批量构建时需要能直接拿单条命令出来重跑
    cmd=("$SCRIPT_DIR/build-toolchain-llvm.sh"
         --arch "$arch"
         --llvm-ver "$LLVM_VERSION"
         --toolchain-dir "$gcc_dir"
         --target-sysroot "$gcc_dir/${arch}-linux-gnu"
         "${extra_args[@]}")
    info "执行: $(format_cmd "${cmd[@]}")"

    if "${cmd[@]}"; then
        ok "构建成功：LLVM $LLVM_VERSION / $arch"
    else
        warn "构建失败：LLVM $LLVM_VERSION / $arch"
        failed_list+=("LLVM $LLVM_VERSION / $arch")
        failed_cmds+=("$(format_cmd "${cmd[@]}")")
    fi
done

if [[ ${#failed_list[@]} -gt 0 ]]; then
    warn "==============================================="
    warn "以下构建任务失败 (${#failed_list[@]}):"
    for i in "${!failed_list[@]}"; do
        warn "  - ${failed_list[$i]}"
        warn "    复现: ${failed_cmds[$i]}"
    done
    warn "==============================================="
    exit 1
fi

ok "==============================================="
info "全部 LLVM 构建任务已完成！"
ok "==============================================="
