#!/usr/bin/env bash
# 为指定架构生成 QEMU virt 最小内核配置并构建
set -uo pipefail

# 获取公共配置和日志函数。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../../lib.sh"

# ---------------------------------------------------------------------------
# 路径和并发可通过环境变量或命令行覆盖。
# ---------------------------------------------------------------------------
SRC_DIR="${SRC_DIR:-}"
TOOLCHAINS_DIR="${TOOLCHAINS_DIR:-}"
WORK_DIR="${WORK_DIR:-$PWD}"
BUILD_DIR="${BUILD_DIR:-}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
CONFIG_ONLY=false
DEFCONFIG_OUTPUT_FILE="${DEFCONFIG_OUTPUT_FILE:-}"
ARCH=""

usage() {
    cat <<EOF
用法: $(basename "$0") [选项] <riscv64|aarch64|x86_64|loongarch64>

生成 QEMU virt 最小内核配置 (defconfig + 裁剪) 并构建

  --src-dir DIR        内核源码树 (必填，或设置 SRC_DIR 环境变量)
  --toolchains-dir DIR 多架构工具链父目录, 含 cross-<triple>/bin (或设置 TOOLCHAINS_DIR)
  --cross-compile P    显式交叉编译前缀 (或设置 CROSS_COMPILE)，优先于工具链父目录
                      --toolchains-dir 和 --cross-compile 至少指定一项
  --work-dir DIR       构建目录父路径 (默认: \$WORK_DIR 或 $WORK_DIR)
  --build-dir DIR      构建输出目录 (默认: <work-dir>/build-kernel-<arch>)
  -j, --jobs N         并行编译线程数 (默认: $JOBS)
  --config-only        只生成 .config, 不编译
  --savedefconfig F    构建后执行 make savedefconfig 并把结果复制到 F
  -h, --help           显示帮助

示例:
  $(basename "$0") --src-dir ./downloads/linux-7.2.2 --toolchains-dir . riscv64
  $(basename "$0") --src-dir ./downloads/linux-7.2.2 --cross-compile aarch64-linux-gnu- --config-only aarch64
  SRC_DIR=~/src/linux CROSS_COMPILE=loongarch64-linux-gnu- $(basename "$0") loongarch64
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src-dir)          require_option_value "$@"; SRC_DIR="$2"; shift 2;;
        --toolchains-dir) require_option_value "$@"; TOOLCHAINS_DIR="$2"; shift 2;;
        --cross-compile)  require_option_value "$@"; CROSS_COMPILE="$2"; shift 2;;
        --work-dir)       require_option_value "$@"; WORK_DIR="$2"; shift 2;;
        --build-dir)      require_option_value "$@"; BUILD_DIR="$2"; shift 2;;
        -j|--jobs)           require_option_value "$@"; require_positive_integer "$1" "$2"; JOBS="$2"; shift 2;;
        --config-only)    CONFIG_ONLY=true; shift;;
        --savedefconfig)  require_option_value "$@"; DEFCONFIG_OUTPUT_FILE="$2"; shift 2;;
        -h|--help)        usage;;
        -*)               echo "未知选项: $1" >&2; exit 1;;
        *)                [[ -z "$ARCH" ]] || error "每次仅支持一个架构"; ARCH="$1"; shift;;
    esac
done

require_positive_integer "构建并发数" "$JOBS"
[[ -n "$ARCH" ]] || error "缺少架构参数"
[[ -n "$SRC_DIR" ]] || error "必须指定 --src-dir 或设置 SRC_DIR"
[[ -d "$SRC_DIR" ]] || error "内核源码不存在: $SRC_DIR"
SRC_DIR="$(cd "$SRC_DIR" && pwd -P)"

case "$ARCH" in
    riscv64)     KERNEL_ARCH=riscv;     TARGET=riscv64-linux-gnu ;;
    aarch64)     KERNEL_ARCH=arm64;     TARGET=aarch64-linux-gnu ;;
    x86_64)      KERNEL_ARCH=x86;       TARGET=x86_64-linux-gnu ;;
    loongarch64) KERNEL_ARCH=loongarch; TARGET=loongarch64-linux-gnu ;;
    *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

if [[ -z "$CROSS_COMPILE" ]]; then
    [[ -n "$TOOLCHAINS_DIR" ]] || error "必须指定 --toolchains-dir 或 --cross-compile"
    [[ -d "$TOOLCHAINS_DIR" ]] || error "工具链父目录不存在: $TOOLCHAINS_DIR"
    TOOLCHAINS_DIR="$(cd "$TOOLCHAINS_DIR" && pwd -P)"
    CROSS_COMPILE="$TOOLCHAINS_DIR/cross-$TARGET/bin/$TARGET-"
elif [[ "$CROSS_COMPILE" == */* ]]; then
    cross_bin_dir="$(dirname "$CROSS_COMPILE")"
    [[ -d "$cross_bin_dir" ]] || error "交叉编译器目录不存在: $cross_bin_dir"
    CROSS_COMPILE="$(cd "$cross_bin_dir" && pwd -P)/$(basename "$CROSS_COMPILE")"
fi
BUILD_DIR="${BUILD_DIR:-$WORK_DIR/build-kernel-$ARCH}"

command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || \
    error "找不到交叉编译器: ${CROSS_COMPILE}gcc"

canonicalize_dirs WORK_DIR BUILD_DIR
make_cmd=("${MAKE:-make}" -C "$SRC_DIR" "O=$BUILD_DIR" "ARCH=$KERNEL_ARCH" "CROSS_COMPILE=$CROSS_COMPILE")

echo "ARCH=$ARCH (KERNEL_ARCH=$KERNEL_ARCH)"
echo "SRC_DIR=$SRC_DIR"
echo "CROSS_COMPILE=$CROSS_COMPILE"
echo "BUILD_DIR=$BUILD_DIR"

"${make_cmd[@]}" defconfig >/dev/null || exit 1

config_cmd=("$SRC_DIR/scripts/config" --file "$BUILD_DIR/.config")

# ---- 通用裁剪(与 riscv_qemu_virt_min_defconfig 同思路) ----
"${config_cmd[@]}" -e EXPERT \
   -d NET -d ETHERNET -d NETDEVICES -d WLAN -d WIRELESS \
   -d USB_SUPPORT -d SOUND -d DRM -d FB -d FB_CORE -d VT -d HID_SUPPORT -d INPUT -d SERIO \
   -d I2C -d SPI -d GPIOLIB -d MMC -d SCSI -d ATA -d MD -d NEW_LEDS -d RTC_CLASS \
   -d WATCHDOG -d REGULATOR -d THERMAL -d CPU_FREQ -d CPU_IDLE -d HWMON -d IIO -d MTD \
   -d VIRTIO_MENU -d DMADEVICES -d MAILBOX -d PWM -d IOMMU_SUPPORT -d VFIO \
   -d VIRTUALIZATION -d STAGING -d DAX -d EXTCON -d MEMORY -d PHY_CLASS -d NVMEM \
   -d BLOCK -d SWAP \
   -d EXT4_FS -d BTRFS_FS -d XFS_FS -d F2FS_FS -d AUTOFS_FS -d ISO9660_FS -d VFAT_FS \
   -d MSDOS_FS -d NETWORK_FILESYSTEMS -d MISC_FILESYSTEMS -d QUOTA -d FUSE_FS -d OVERLAY_FS \
   -d CGROUPS -d SYSVIPC -d POSIX_MQUEUE -d AUDIT -d SECURITY -d KEYS -d BPF_SYSCALL \
   -d SCHED_AUTOGROUP -d SCHED_CORE -d PSI -d IKHEADERS -d BSD_PROCESS_ACCT \
   -d TASKSTATS -d RELAY -d WERROR -d BINFMT_MISC -d IRQ_TIME_ACCOUNTING \
   -e NAMESPACES -e USER_NS -e CHECKPOINT_RESTORE \
   -d FTRACE -d PROFILING -d PERF_EVENTS -d KPROBES -d MODULES -d IKCONFIG \
   -d KSM -d MEMORY_HOTPLUG -d CMA -d NUMA \
   -d SUSPEND -d HIBERNATION \
   -d SECCOMP -d STACKPROTECTOR -d VMAP_STACK -d STRICT_KERNEL_RWX -d RANDOMIZE_BASE \
   -d IO_URING -d RSEQ -d COREDUMP -d DNOTIFY \
   -d LEGACY_PTYS -d CONNECTOR -d KEXEC -d KEXEC_FILE -d CRASH_DUMP \
   -d RD_BZIP2 -d RD_LZMA -d RD_XZ -d RD_LZO -d RD_LZ4 -d RD_ZSTD -e RD_GZIP \
   -d CRYPTO_HW -d NLS -d XZ_DEC -d CRYPTO_SELFTESTS \
   -d INIT_STACK_ALL_ZERO -e INIT_STACK_NONE \
   -d PREEMPT -d PREEMPT_VOLUNTARY -d PREEMPT_DYNAMIC \
   -e SMP -e BLK_DEV_INITRD -e DEVTMPFS -e DEVTMPFS_MOUNT \
   -e TMPFS -e TMPFS_POSIX_ACL -e PROC_FS -e SYSFS \
   -e BINFMT_ELF -e BINFMT_SCRIPT -e UNIX98_PTYS \
   -e TRANSPARENT_HUGEPAGE -d TRANSPARENT_HUGEPAGE_ALWAYS -e TRANSPARENT_HUGEPAGE_MADVISE \
   -e HUGETLBFS -e KALLSYMS -e PRINTK_TIME -d KALLSYMS_ALL \
   -d DEBUG_KERNEL -d DEBUG_FS -d SLUB_DEBUG -d STACKTRACE -d DEBUG_MEMORY_INIT \
   -d MEMTEST -d RUNTIME_TESTING_MENU -d SCHED_DEBUG -d DEBUG_PREEMPT \
   -d DEVMEM -d HW_RANDOM -d DMA_CMA \
   -d PCCARD -d RAPIDIO -d MACINTOSH_DRIVERS -d AGP -d NVRAM -d HPET -d PPS \
   -d PROC_KCORE -d MAGIC_SYSRQ -d SCHEDSTATS -d USERFAULTFD -d UEVENT_HELPER \
   -d FW_LOADER_COMPRESS -d FW_LOADER_USER_HELPER -d SERIAL_NONSTANDARD \
   -d SERIAL_8250_EXTENDED -d MEMORY_FAILURE -d ENERGY_MODEL \
   -d WQ_POWER_EFFICIENT_DEFAULT -d XEN -d PM_DEBUG -d DEBUG_DEVRES -d DEBUG_WX \
   -d DEBUG_STACK_USAGE -d CRYPTO_CCM -d CRYPTO_LZO -d PREEMPT_LAZY -d PREEMPT_RT \
   -d EEPROM_93CX6 -d MEDIA_SUPPORT -d VIDEO_CADENCE_CSI2RX -d RPMSG -d RPMSG_CTRL \
   -d RPMSG_VIRTIO -d VIRTIO_CONSOLE -d SYNC_FILE -d CONFIGFS_FS -d PM_DEVFREQ \
   -d BACKLIGHT_CLASS_DEVICE -d POWER_RESET_GPIO_RESTART -d POWER_SEQUENCING \
   -d POWER_SUPPLY -d PINCTRL -d RESET_CONTROLLER -d MFD_AXP20X -d MFD_AXP20X_I2C \
   -d SECURITYFS -d CRYPTO_AUTHENC -d CRYPTO_RSA -d CRYPTO_AES -d CRYPTO_CBC \
   -d CRYPTO_GCM -d CRYPTO_SEQIV -d CRYPTO_ECHAINIV -d CRYPTO_HMAC -d CRYPTO_SHA256 \
   -d CRYPTO_CTR -d CRYPTO >/dev/null

# ---- 架构特化 ----
case "$ARCH" in
riscv64)
    # 控制台: 8250 ttyS0 + SBI earlycon; 关机: syscon-poweroff; 仅 QEMU virt 平台
    "${config_cmd[@]}" -e NONPORTABLE -d EFI -d PCI \
       -e SERIAL_8250 -e SERIAL_8250_CONSOLE -e SERIAL_OF_PLATFORM \
       --set-val SERIAL_8250_NR_UARTS 1 --set-val SERIAL_8250_RUNTIME_UARTS 1 \
       -d SERIAL_8250_16550A_VARIANTS -d SERIAL_8250_DW -d SERIAL_SIFIVE \
       -e POWER_RESET -e POWER_RESET_SYSCON_POWEROFF -e MFD_SYSCON \
       -d RISCV_COMBO_SPINLOCKS -d RISCV_QUEUED_SPINLOCKS -e RISCV_TICKET_SPINLOCKS \
       -e PARAVIRT -d PM -d HOTPLUG_CPU \
       -d SPARSEMEM_MANUAL -e FLATMEM_MANUAL \
       -d ERRATA_ANDES -d ERRATA_SIFIVE -d ERRATA_THEAD -d RISCV_ISA_XTHEADVECTOR \
       -d ARCH_ANDES -d ARCH_ANLOGIC -d ARCH_CANAAN -d ARCH_MICROCHIP -d ARCH_SIFIVE \
       -d ARCH_SOPHGO -d ARCH_SPACEMIT -d ARCH_STARFIVE -d ARCH_SUNXI \
       -d ARCH_TENSTORRENT -d ARCH_THEAD -d SOC_STARFIVE >/dev/null
    ;;
aarch64)
    # 控制台: PL011 (ttyAMA0), 依赖 ARM_AMBA; 关机: PSCI(内建)
    "${config_cmd[@]}" -e ARM_AMBA -e SERIAL_AMBA_PL011 -e SERIAL_AMBA_PL011_CONSOLE \
       -d SERIAL_8250 -d PCI -d ACPI -d EFI \
       -d ARM_SMMU -d ARM_SMMU_V3 -d ARM_PMU -d ARM_SDE_INTERFACE \
       -d ARM64_SME -d ARM64_PTR_AUTH -d ARM64_BTI -d ARM64_MTE \
       -d SHADOW_CALL_STACK -d UNMAP_KERNEL_AT_EL0 -d MITIGATE_SPECTRE_BRANCH_HISTORY \
       -d SOCIONEXT_SYNQUACER_PREITS \
       -d COMPAT -d PM -d HOTPLUG_CPU -d VEXPRESS_CONFIG >/dev/null
    # 动态枚举并关闭全部厂商平台 (来自 Kconfig.platforms, 保留 virt 所需的通用部分)
    for opt in $(grep -oE '^config ARCH_[A-Z0-9_]+' "$SRC_DIR/arch/arm64/Kconfig.platforms" | awk '{print $2}'); do
        "${config_cmd[@]}" -d "$opt" >/dev/null
    done
    # 批量关闭 CPU erratum 软件规避 (QEMU TCG 无需)
    for opt in $(grep -oE '^CONFIG_[A-Z0-9_]*ERRATUM[A-Z0-9_]*=y' "$BUILD_DIR/.config" | sed 's/^CONFIG_//;s/=y//'); do
        "${config_cmd[@]}" -d "$opt" >/dev/null
    done
    ;;
x86_64)
    # 控制台: 8250 ttyS0; 关机: ACPI S5 (保留 ACPI+PCI)
    # bzImage 必须压缩, 选解压指令数最少的 LZ4 (gzip 解压约多花 1.2亿条指令)
    "${config_cmd[@]}" -d KERNEL_GZIP -e KERNEL_LZ4 \
       -e SERIAL_8250 -e SERIAL_8250_CONSOLE \
       --set-val SERIAL_8250_NR_UARTS 1 --set-val SERIAL_8250_RUNTIME_UARTS 1 \
       -d SERIAL_8250_16550A_VARIANTS \
       -e ACPI -e PCI -d EFI -d EFI_STUB \
       -d HYPERVISOR_GUEST -d PARAVIRT -d KVM_GUEST -d XEN \
       -d MICROCODE -d X86_MCE -d X86_EXTENDED_PLATFORM -d X86_16BIT \
       -d IA32_EMULATION -d X86_X32_ABI \
       -d ACPI_BATTERY -d ACPI_AC -d ACPI_FAN -d ACPI_THERMAL -d ACPI_VIDEO \
       -d ACPI_DOCK -d ACPI_PROCESSOR -d ACPI_TABLE_UPGRADE -d ACPI_DEBUGGER \
       -d X86_MPPARSE -d X86_AMD_PSTATE -d X86_INTEL_PSTATE \
       -d X86_VSYSCALL_EMULATION -d X86_IOPL_IOPERM \
       -d IOSF_MBI -d X86_REROUTE_FOR_BROKEN_BOOT_IRQS -d X86_MSR -d X86_CPUID \
       -d X86_CHECK_BIOS_CORRUPTION -d PROVIDE_OHCI1394_DMA_INIT -d EARLY_PRINTK_DBGP \
       -d DEBUG_ENTRY -d PCI_PRI -d PCI_PASID -d ACPI_WMI \
       -d SCHED_MC -d SCHED_MC_PRIO \
       -d PCIEPORTBUS -d PCIEASPM -d PCI_MMCONFIG_FORCE -d HOTPLUG_PCI >/dev/null
    ;;
loongarch64)
    # 控制台: 8250 ttyS0; 直接 -kernel vmlinux 引导; 保留 ACPI+PCI(关机依赖)
    # 注: swiotlb 为架构无条件分配, 测量时用 cmdline "swiotlb=16" 压到 256KB
    "${config_cmd[@]}" -e SERIAL_8250 -e SERIAL_8250_CONSOLE -e SERIAL_OF_PLATFORM \
       --set-val SERIAL_8250_NR_UARTS 1 --set-val SERIAL_8250_RUNTIME_UARTS 1 \
       -d SERIAL_8250_16550A_VARIANTS \
       -e ACPI -e PCI -d EFI_STUB \
       -d ACPI_BATTERY -d ACPI_AC -d ACPI_FAN -d ACPI_THERMAL -d ACPI_VIDEO \
       -d ACPI_DOCK -d ACPI_TABLE_UPGRADE \
       -d ACPI_IPMI -d ACPI_PCI_SLOT -d ACPI_BGRT -d ACPI_SPCR_TABLE \
       -d EFI_BOOTLOADER_CONTROL -d EFI_CAPSULE_LOADER -d EFI_TEST \
       -d PCI_IOV -d HOTPLUG_CPU \
       -d PCIEPORTBUS -d PCIEASPM -d HOTPLUG_PCI >/dev/null
    ;;
esac

"${make_cmd[@]}" olddefconfig >/dev/null || exit 1

# ---- 二次收敛: 处理被 select/choice 翻回来的项 ----
# 注: 本版本内核 PREEMPT_NONE 仅限 ARCH_NO_PREEMPT 架构;
#     统一使用 choice 默认的 PREEMPT_LAZY, 与 riscv 实际状态一致
"${config_cmd[@]}" -d CGROUPS -d CPU_FREQ -d NLS -d PM_DEBUG \
   -d PREEMPT -d PREEMPT_DYNAMIC -d PREEMPT_VOLUNTARY -e PREEMPT_LAZY >/dev/null

"${make_cmd[@]}" olddefconfig >/dev/null || exit 1
echo "--- 关键项校验:"
grep -E '^CONFIG_(PREEMPT|PREEMPT_NONE|PREEMPT_LAZY|CGROUPS|CPU_FREQ|SMP|SCHED_AUTOGROUP)=y' "$BUILD_DIR/.config"

if $CONFIG_ONLY; then
    echo "=== $ARCH config done (--config-only, 跳过编译) ==="
    exit 0
fi

echo "=== $ARCH config done, building... ==="
"${make_cmd[@]}" -j"$JOBS" > "$BUILD_DIR/build.log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
    echo "BUILD FAIL ($ARCH), last lines:"
    tail -20 "$BUILD_DIR/build.log"
    exit $rc
fi
echo "BUILD OK ($ARCH)"
ls -la "$BUILD_DIR/arch/$KERNEL_ARCH/boot/" "$BUILD_DIR/vmlinux" 2>/dev/null | grep -E 'Image|vmlinux' | head -5

if [[ -n "$DEFCONFIG_OUTPUT_FILE" ]]; then
    "${make_cmd[@]}" savedefconfig >/dev/null 2>&1 && \
        cp "$BUILD_DIR/defconfig" "$DEFCONFIG_OUTPUT_FILE" && \
        echo "savedefconfig -> $DEFCONFIG_OUTPUT_FILE ($(wc -l < "$DEFCONFIG_OUTPUT_FILE") 行)"
fi
