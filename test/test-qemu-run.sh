#!/usr/bin/env bash
set -euo pipefail

# do not delete
# ~/qemu_upstream/build/qemu-system-aarch64     -nographic -m 1G -no-reboot -M virt -cpu neoverse-n2 -kernel ./aarch64-Image       -initrd ./initrd-aarch64.cpio      -append "console=ttyAMA0 rdinit=/sbin/poweroff -- -f"
# ~/qemu_upstream/build/qemu-system-loongarch64 -nographic -m 1G -no-reboot -M virt -cpu la464       -kernel ./loongarch64-vmlinux -initrd ./initrd-loongarch64.cpio  -append "console=ttyS0 rdinit=/sbin/poweroff -- -f"
# ~/qemu_upstream/build/qemu-system-riscv64     -nographic -m 1G -no-reboot -M virt -cpu rva23s64    -kernel ./riscv64-Image       -initrd ./initrd-riscv64.cpio      -append "earlycon=sbi console=ttyS0 rdinit=/sbin/poweroff -- -f"
# ~/qemu_upstream/build/qemu-system-x86_64      -nographic -m 1G -no-reboot -M q35  -cpu Haswell     -kernel ./x86_64-bzImage      -initrd ./initrd-x86_64.cpio       -append "earlyprintk=ttyS0,115200 console=ttyS0 rdinit=/sbin/poweroff -- -f"

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

declare -A QEMU_CONFIGS=(
    [aarch64]="qemu-system-aarch64|-M virt -cpu neoverse-n2|aarch64-Image|initrd-aarch64.cpio|console=ttyAMA0"
    [loongarch64]="qemu-system-loongarch64|-M virt -cpu la464|loongarch64-vmlinux|initrd-loongarch64.cpio|console=ttyS0"
    [riscv64]="qemu-system-riscv64|-M virt -cpu rva23s64|riscv64-Image|initrd-riscv64.cpio|earlycon=sbi console=ttyS0"
    [x86_64]="qemu-system-x86_64|-M q35 -cpu Haswell|x86_64-bzImage|initrd-x86_64.cpio|earlyprintk=ttyS0,115200 console=ttyS0"
)

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
ARCHS=()

usage() {
    cat <<EOF
用法: $(basename "$0") [选项] [架构...]

使用 QEMU 启动交叉编译的内核 + initramfs 进行冒烟测试

  架构参数        要测试的架构（默认: 全部可用）
                  支持: aarch64, loongarch64, riscv64, x86_64

  --qemu-dir      QEMU 二进制目录 (默认: \$QEMU_DIR 或 ~/qemu_upstream/build)
  --images-dir    内核/initramfs 所在目录 (默认: 当前目录)
  --timeout       单次启动超时秒数 (默认: $TIMEOUT)
  -h,--help       显示帮助

示例:
  $(basename "$0")                          # 测试所有架构
  $(basename "$0") riscv64 aarch64          # 仅测试指定架构
  $(basename "$0") --images-dir ./release   # 指定产物目录
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qemu-dir)    QEMU_DIR="$2"; shift 2;;
        --images-dir)  IMAGES_DIR="$2"; shift 2;;
        --timeout)     TIMEOUT="$2"; shift 2;;
        -h|--help)     usage;;
        *)             ARCHS+=("$1"); shift;;
    esac
done

[[ ${#ARCHS[@]} -eq 0 ]] && ARCHS=(aarch64 loongarch64 riscv64 x86_64)

# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0

for arch in "${ARCHS[@]}"; do
    if [[ -z "${QEMU_CONFIGS[$arch]:-}" ]]; then
        warn "未知架构: $arch，跳过"
        ((SKIP++))
        continue
    fi

    IFS='|' read -r qemu_bin machine kernel initrd append <<< "${QEMU_CONFIGS[$arch]}"

    qemu_path="$QEMU_DIR/$qemu_bin"
    kernel_path="$IMAGES_DIR/$kernel"
    initrd_path="$IMAGES_DIR/$initrd"

    if [[ ! -x "$qemu_path" ]]; then
        warn "QEMU 不存在: $qemu_path，跳过 $arch"
        ((SKIP++))
        continue
    fi
    if [[ ! -f "$kernel_path" ]]; then
        warn "内核不存在: $kernel_path，跳过 $arch"
        ((SKIP++))
        continue
    fi
    if [[ ! -f "$initrd_path" ]]; then
        warn "initramfs 不存在: $initrd_path，跳过 $arch"
        ((SKIP++))
        continue
    fi

    step "=== 测试 $arch ==="
    cmd="$qemu_path -nographic -m 1G -no-reboot $machine -kernel $kernel_path -initrd $initrd_path -append \"$append rdinit=/sbin/poweroff -- -f\""
    info "$cmd"

    if timeout "$TIMEOUT" "$qemu_path" \
        -nographic -m 1G -no-reboot \
        $machine \
        -kernel "$kernel_path" \
        -initrd "$initrd_path" \
        -append "$append rdinit=/sbin/poweroff -- -f" \
        < /dev/null > /dev/null 2>&1; then
        ok "$arch: 启动并正常关机"
        ((PASS++))
    else
        ret=$?
        if [[ $ret -eq 124 ]]; then
            warn "$arch: 超时 (${TIMEOUT}s)"
        else
            warn "$arch: 退出码 $ret"
        fi
        ((FAIL++))
    fi
done

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo ""
info "=== 测试汇总 ==="
info "通过: $PASS  失败: $FAIL  跳过: $SKIP"
[[ $FAIL -eq 0 ]] && ok "全部通过" || error "存在失败的测试"
