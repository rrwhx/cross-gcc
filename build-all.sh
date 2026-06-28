#!/usr/bin/env bash
set -euo pipefail

# 获取脚本的绝对路径（在脚本开始时就确定）
if command -v readlink >/dev/null 2>&1; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
fi
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

source "$SCRIPT_DIR/lib.sh"

# 默认支持的架构和 libc 列表
declare -a default_arch_list=("aarch64" "loongarch64" "riscv32" "riscv64" "i686" "x86_64" "mipsel" "mips64el" "mips" "mips64")
declare -a default_libc_list=("glibc" "musl")

# 初始化可配置的变量
declare -a arch_list=()
declare -a libc_list=()
declare -a extra_args=()

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch|--architecture|-a)
            # 按逗号分割用户输入的架构列表
            IFS=',' read -ra arch_list <<< "$2"
            shift 2  # 跳过选项和值
            ;;
        --libc|--libc-type|-l)
            # 按逗号分割用户输入的 libc 列表
            IFS=',' read -ra libc_list <<< "$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [选项] [其他选项传递给 build-toolchain-generic.sh]"
            echo "选项:"
            echo "  -a, --arch <架构列表>      指定架构（逗号分隔），默认: ${default_arch_list[*]}"
            echo "  -l, --libc <libc列表>      指定libc类型（逗号分隔），默认: ${default_libc_list[*]}"
            echo "  -h, --help                 显示帮助信息"
            echo ""
            echo "其他选项将直接传递给 build-toolchain-generic.sh，例如："
            echo "  --binutils-ver, --gcc-ver, --glibc-ver, --musl-ver, --linux-ver"
            echo "  --clean, --archive, --threads, --download-dir, 等等"
            echo ""
            echo "示例:"
            echo "  $0 --arch aarch64,riscv64 --libc glibc --gcc-ver 14.2.0 --clean"
            exit 0
            ;;
        *)
            # 将未识别的参数添加到额外参数列表中
            extra_args+=("$1")
            shift
            ;;
    esac
done

# 如果用户未指定参数，使用默认值
[[ ${#arch_list[@]} -eq 0 ]] && arch_list=("${default_arch_list[@]}")
[[ ${#libc_list[@]} -eq 0 ]] && libc_list=("${default_libc_list[@]}")

# 打印配置信息
info "==============================================="
info "目标架构: ${arch_list[*]}"
info "目标 libc: ${libc_list[*]}"
info "==============================================="

# 遍历每个架构和 libc 组合
for arch in "${arch_list[@]}"; do
    for libc in "${libc_list[@]}"; do
        step "======================================================================"
        info "开始构建工具链：ARCH=$arch, LIBC=$libc"
        step "======================================================================"

        if "$SCRIPT_DIR/build-toolchain-generic.sh" --arch "$arch" --libc "$libc" "${extra_args[@]}"; then
            ok "构建成功：ARCH=$arch, LIBC=$libc"
        else
            warn "构建失败：ARCH=$arch, LIBC=$libc"
        fi
    done
done

ok "==============================================="
info "全部构建任务已完成！"
ok "==============================================="
