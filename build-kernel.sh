#!/usr/bin/env bash
# cross-compile Linux kernel with KVM guest support
set -euo pipefail

if command -v readlink >/dev/null 2>&1; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
fi
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

source "$SCRIPT_DIR/lib.sh"

setup_error_trap

# ---------------------------------------------------------------------------
# 默认配置
# ---------------------------------------------------------------------------
LINUX_VER="${LINUX_VER:-7.1.1}"
MIRROR="mirrors.tuna.tsinghua.edu.cn"

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
ARCH=""
CROSS_COMPILE=""
WORK_DIR=$(pwd)
LINUX_SRC=""
OUTPUT=""
CLEAN_BUILD=false

usage() {
    cat <<EOF
用法: $(basename "$0") --arch ARCH --cross-compile PREFIX [选项]

交叉编译 Linux 内核 (defconfig + kvm_guest.config)

  --arch            目标架构 (例如: riscv64, aarch64, x86_64)
  --cross-compile   交叉编译前缀，可为完整路径或仅前缀
                    (例如: riscv64-linux-gnu- 或 /path/to/bin/riscv64-linux-gnu-)
  --work-dir        工作目录前缀 (默认: 当前目录)
  --linux-ver       Linux 内核版本 (默认: ${LINUX_VER}, 支持 git[:REF][:update])
  --linux-src       直接指定已解压的内核源码路径 (跳过下载/解压)
  --output          输出目录 (默认: <work-dir>/kernel-<arch>)
  --mirror          下载镜像源 (默认: ${MIRROR})
  -j,--threads      并行编译线程数 (默认: ${THREADS})
  --clean           构建完成后删除构建目录和日志目录
  -h,--help         显示帮助

示例:
  $(basename "$0") --arch riscv64 --cross-compile ./cross-riscv64-linux-gnu/bin/riscv64-linux-gnu-
  $(basename "$0") --arch riscv64 --cross-compile riscv64-linux-gnu- --linux-src ./downloads/linux-7.1.1
  $(basename "$0") --arch riscv64 --linux-ver git:v6.12 --cross-compile riscv64-linux-gnu-
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)           ARCH="$2"; shift 2;;
        --cross-compile)  CROSS_COMPILE="$2"; shift 2;;
        --work-dir)       WORK_DIR="$2"; shift 2;;
        --linux-ver)      LINUX_VER="$2"; shift 2;;
        --linux-src)      LINUX_SRC="$2"; shift 2;;
        --output)         OUTPUT="$2"; shift 2;;
        --mirror)         MIRROR="$2"; shift 2;;
        -j|--threads)     THREADS="$2"; shift 2;;
        --clean)          CLEAN_BUILD=true; shift;;
        -h|--help)        usage;;
        *)                error "未知选项: $1"; usage;;
    esac
done

if [[ -z "$ARCH" || -z "$CROSS_COMPILE" ]]; then
    error "--arch 和 --cross-compile 参数为必需。"
fi

# ---------------------------------------------------------------------------
# 架构映射 (用户 ARCH -> 内核 ARCH)
# ---------------------------------------------------------------------------
case "$ARCH" in
    riscv64|riscv32) KERNEL_ARCH="riscv" ;;
    aarch64)         KERNEL_ARCH="arm64" ;;
    arm)             KERNEL_ARCH="arm"   ;;
    x86_64|i686)     KERNEL_ARCH="x86"   ;;
    loongarch64|loongarch32) KERNEL_ARCH="loongarch" ;;
    mips*)           KERNEL_ARCH="mips"  ;;
    *)               KERNEL_ARCH="$ARCH" ;;
esac

# ---------------------------------------------------------------------------
# 工具链设置
# ---------------------------------------------------------------------------
if [[ "$CROSS_COMPILE" == */* ]]; then
    CROSS_COMPILE=$(realpath "$CROSS_COMPILE")
    TOOLCHAIN_BIN="$(dirname "$CROSS_COMPILE")"
    export PATH="$TOOLCHAIN_BIN:$PATH"
    info "已将 $TOOLCHAIN_BIN 加入 PATH"
fi

if ! command -v "${CROSS_COMPILE}gcc" &>/dev/null; then
    error "无法找到交叉编译器 ${CROSS_COMPILE}gcc，请检查 --cross-compile 参数"
fi

# ---------------------------------------------------------------------------
# 目录设置
# ---------------------------------------------------------------------------
WORK_DIR=$(realpath "$WORK_DIR")
DOWNLOAD_DIR="${WORK_DIR}/downloads"
BUILD_DIR="${WORK_DIR}/build-kernel-${ARCH}"
LOG_DIR="${WORK_DIR}/logs-kernel-${ARCH}"
OUTPUT="${OUTPUT:-${WORK_DIR}/kernel-${ARCH}}"

mkdir -p "$DOWNLOAD_DIR" "$BUILD_DIR" "$LOG_DIR" "$OUTPUT"

info "ARCH=$ARCH (KERNEL_ARCH=$KERNEL_ARCH)"
info "CROSS_COMPILE=$CROSS_COMPILE"
info "Linux 版本: $LINUX_VER"
info "构建目录: $BUILD_DIR"
info "日志目录: $LOG_DIR"
info "输出目录: $OUTPUT"

# ---------------------------------------------------------------------------
# 阶段 1: 获取内核源码
# ---------------------------------------------------------------------------
if [[ -n "$LINUX_SRC" ]]; then
    LINUX_SRC=$(realpath "$LINUX_SRC")
    if [[ ! -d "$LINUX_SRC" ]]; then
        error "指定的内核源码目录不存在: $LINUX_SRC"
    fi
    info "使用已有内核源码: $LINUX_SRC"
elif [[ "$LINUX_VER" == git* ]]; then
    step "=== 克隆 Linux 内核源码 ==="
    LINUX_SRC="$DOWNLOAD_DIR/linux"
    parse_git_ver "$LINUX_VER"
    git_clone "https://${MIRROR}/git/linux.git" "$LINUX_SRC" 1 "$_GIT_UPDATE" "$_GIT_REF"
else
    step "=== 下载 Linux 内核源码 ==="
    LINUX_MAJOR_VER="${LINUX_VER%%.*}"
    LINUX_URL="https://${MIRROR}/kernel/v${LINUX_MAJOR_VER}.x/linux-${LINUX_VER}.tar.xz"
    ARCHIVE_FILE="$DOWNLOAD_DIR/linux-${LINUX_VER}.tar.xz"
    download "$LINUX_URL" "$ARCHIVE_FILE"

    step "=== 解压源码 ==="
    LINUX_SRC="$DOWNLOAD_DIR/linux-${LINUX_VER}"
    if [[ ! -d "$LINUX_SRC" ]]; then
        info "解压: linux-${LINUX_VER}.tar.xz"
        tar -xf "$ARCHIVE_FILE" -C "$DOWNLOAD_DIR"
    else
        info "源码目录已存在，跳过解压"
    fi
fi

# ---------------------------------------------------------------------------
# 阶段 2: 配置内核
# ---------------------------------------------------------------------------
step "=== 配置内核 ==="
assert_safe_to_delete "$BUILD_DIR"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

info "工作目录: $LINUX_SRC"
info "清理源码树 (mrproper)"
build_step "kernel_mrproper" "$LOG_DIR" \
    make -C "$LINUX_SRC" ARCH="$KERNEL_ARCH" mrproper

info "生成 defconfig (ARCH=$KERNEL_ARCH CROSS_COMPILE=$CROSS_COMPILE)"
build_step "kernel_defconfig" "$LOG_DIR" \
    make -C "$LINUX_SRC" O="$BUILD_DIR" \
    ARCH="$KERNEL_ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig

info "合并 kvm_guest.config 片段"
build_step "kernel_kvm_guest_config" "$LOG_DIR" \
    make -C "$LINUX_SRC" O="$BUILD_DIR" \
    ARCH="$KERNEL_ARCH" CROSS_COMPILE="$CROSS_COMPILE" kvm_guest.config

# ---------------------------------------------------------------------------
# 阶段 3: 编译内核
# ---------------------------------------------------------------------------
step "=== 编译内核 ==="
info "工作目录: $BUILD_DIR"
info "make -j${THREADS} ARCH=$KERNEL_ARCH CROSS_COMPILE=$CROSS_COMPILE"
build_step "kernel_build" "$LOG_DIR" \
    make -C "$BUILD_DIR" -j"${THREADS}" \
    ARCH="$KERNEL_ARCH" CROSS_COMPILE="$CROSS_COMPILE"

# ---------------------------------------------------------------------------
# 阶段 4: 安装模块与复制产物
# ---------------------------------------------------------------------------
step "=== 安装模块 ==="
info "安装模块到: $OUTPUT"
build_step "kernel_modules_install" "$LOG_DIR" \
    make -C "$BUILD_DIR" modules_install \
    ARCH="$KERNEL_ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    INSTALL_MOD_PATH="$OUTPUT"

step "=== 复制内核镜像 ==="
# 复制 vmlinux
if [[ -f "$BUILD_DIR/vmlinux" ]]; then
    cp "$BUILD_DIR/vmlinux" "$OUTPUT/"
    info "已复制: vmlinux"
fi

# 复制架构特定的 Image
BOOT_DIR="$BUILD_DIR/arch/$KERNEL_ARCH/boot"
for img in Image Image.gz bzImage zImage; do
    if [[ -f "$BOOT_DIR/$img" ]]; then
        cp "$BOOT_DIR/$img" "$OUTPUT/"
        info "已复制: $img"
    fi
done

# ---------------------------------------------------------------------------
# 输出产物信息
# ---------------------------------------------------------------------------
OUTPUT=$(realpath "$OUTPUT")
ok "Linux ${LINUX_VER} 交叉编译完成！"
info "产物目录: $OUTPUT"

if [[ -f "$OUTPUT/vmlinux" ]]; then
    info "$(file "$OUTPUT/vmlinux")"
fi

echo -e "内核产物:"
for f in vmlinux Image Image.gz bzImage zImage; do
    if [[ -f "$OUTPUT/$f" ]]; then
        echo -e "  ${GREEN}$(ls -lh "$OUTPUT/$f")${NC}"
    fi
done

# 构建后处理
clean_build_dir "$BUILD_DIR" "$LOG_DIR" "$CLEAN_BUILD"
