#!/usr/bin/env bash
set -euo pipefail

if command -v readlink >/dev/null 2>&1; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
fi
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

source "$SCRIPT_DIR/../lib.sh"

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
QEMU_DIR="${QEMU_DIR:-$HOME/qemu_upstream/build}"
IMAGES_DIR="${IMAGES_DIR:-$(pwd)}"
TIMEOUT="${TIMEOUT:-30}"
VERBOSE=false

# ---------------------------------------------------------------------------
# 架构配置：每个函数构造 cmd 数组
# ---------------------------------------------------------------------------
ALL_ARCHS=(aarch64 loongarch64 riscv64 x86_64)

cmd_qemu_aarch64() {
    cmd=("$QEMU_DIR/qemu-system-aarch64"
        -nographic -m 1G -no-reboot
        -M virt -cpu neoverse-n2
        -kernel "$IMAGES_DIR/aarch64-Image"
        -initrd "$IMAGES_DIR/initrd-aarch64.cpio"
        -append "console=ttyAMA0 rdinit=/sbin/poweroff -- -f")
}

cmd_qemu_loongarch64() {
    cmd=("$QEMU_DIR/qemu-system-loongarch64"
        -nographic -m 1G -no-reboot
        -M virt -cpu la464
        -kernel "$IMAGES_DIR/loongarch64-vmlinux"
        -initrd "$IMAGES_DIR/initrd-loongarch64.cpio"
        -append "console=ttyS0 rdinit=/sbin/poweroff -- -f")
}

cmd_qemu_riscv64() {
    cmd=("$QEMU_DIR/qemu-system-riscv64"
        -nographic -m 1G -no-reboot
        -M virt -cpu rva23s64
        -kernel "$IMAGES_DIR/riscv64-Image"
        -initrd "$IMAGES_DIR/initrd-riscv64.cpio"
        -append "earlycon=sbi console=ttyS0 rdinit=/sbin/poweroff -- -f")
}

cmd_qemu_x86_64() {
    cmd=("$QEMU_DIR/qemu-system-x86_64"
        -nographic -m 1G -no-reboot
        -M q35 -cpu Haswell
        -kernel "$IMAGES_DIR/x86_64-bzImage"
        -initrd "$IMAGES_DIR/initrd-x86_64.cpio"
        -append "earlyprintk=ttyS0,115200 console=ttyS0 rdinit=/sbin/poweroff -- -f")
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
ARCHS=()

usage() {
    cat <<EOF
用法: $(basename "$0") [选项] [架构...]

使用 QEMU 启动交叉编译的内核 + initramfs 进行冒烟测试

  架构参数        要测试的架构（默认: 全部可用）
                  支持: ${ALL_ARCHS[*]}

  --qemu-dir      QEMU 二进制目录 (默认: \$QEMU_DIR 或 ~/qemu_upstream/build)
  --images-dir    内核/initramfs 所在目录 (默认: 当前目录)
  --timeout       单次启动超时秒数 (默认: $TIMEOUT)
  --verbose       显示 QEMU 输出（用于调试）
  -h,--help       显示帮助

示例:
  $(basename "$0")                          # 测试所有架构
  $(basename "$0") riscv64 aarch64          # 仅测试指定架构
  $(basename "$0") --images-dir ./release   # 指定产物目录
  $(basename "$0") --verbose riscv64        # 调试模式查看输出
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qemu-dir)    QEMU_DIR="$2"; shift 2;;
        --images-dir)  IMAGES_DIR="$2"; shift 2;;
        --timeout)     TIMEOUT="$2"; shift 2;;
        --verbose)     VERBOSE=true; shift;;
        -h|--help)     usage;;
        *)             ARCHS+=("$1"); shift;;
    esac
done

[[ ${#ARCHS[@]} -eq 0 ]] && ARCHS=("${ALL_ARCHS[@]}")

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
preflight_check() {
    local arch="$1"
    local qemu_bin="${cmd[0]}"
    local kernel="" initrd=""

    for ((i=1; i<${#cmd[@]}; i++)); do
        case "${cmd[$i]}" in
            -kernel) kernel="${cmd[$((i+1))]}" ;;
            -initrd) initrd="${cmd[$((i+1))]}" ;;
        esac
    done

    if [[ ! -x "$qemu_bin" ]]; then
        warn "QEMU 不存在: $qemu_bin，跳过 $arch"
        return 1
    fi
    if [[ -n "$kernel" && ! -f "$kernel" ]]; then
        warn "内核不存在: $kernel，跳过 $arch"
        return 1
    fi
    if [[ -n "$initrd" && ! -f "$initrd" ]]; then
        warn "initramfs 不存在: $initrd，跳过 $arch"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0

for arch in "${ARCHS[@]}"; do
    cmd_fn="cmd_qemu_${arch}"
    if ! declare -f "$cmd_fn" >/dev/null 2>&1; then
        warn "未知架构: $arch，跳过"
        ((++SKIP))
        continue
    fi

    cmd=()
    $cmd_fn

    if ! preflight_check "$arch"; then
        ((++SKIP))
        continue
    fi

    step "=== 测试 $arch ==="
    info "${cmd[*]}"

    start_time=$(date +%s)

    if [[ "$VERBOSE" == true ]]; then
        timeout "$TIMEOUT" "${cmd[@]}" < /dev/null; ret=$?
    else
        timeout "$TIMEOUT" "${cmd[@]}" < /dev/null > /dev/null 2>&1; ret=$?
    fi

    elapsed=$(( $(date +%s) - start_time ))

    if [[ $ret -eq 0 ]]; then
        ok "$arch: 启动并正常关机 (${elapsed}s)"
        ((++PASS))
    elif [[ $ret -eq 124 ]]; then
        warn "$arch: 超时 (${TIMEOUT}s)"
        ((++FAIL))
    else
        warn "$arch: 退出码 $ret (${elapsed}s)"
        ((++FAIL))
    fi
done

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo ""
info "=== 测试汇总 ==="
info "通过: $PASS  失败: $FAIL  跳过: $SKIP"
[[ $FAIL -eq 0 ]] && ok "全部通过" || error "存在失败的测试"
