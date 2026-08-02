#!/usr/bin/env bash
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
BUSYBOX_VER="${BUSYBOX_VER:-1.38.0}"
BUSYBOX_URL="https://busybox.net/downloads/busybox-{VER}.tar.bz2"
# CoreMark 固定使用 git master 最新代码
COREMARK_GIT="https://github.com/eembc/coremark.git"

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
ARCH=""
CROSS_COMPILE=""
WORK_DIR=$(pwd)
OUTPUT=""
CLEAN_BUILD=false
WITH_COREMARK=false
ADD_FILES=()

usage() {
    cat <<EOF
用法: $(basename "$0") --arch ARCH --cross-compile PREFIX [选项]

交叉编译 BusyBox 并生成 initramfs (cpio 格式)

  --arch            目标架构 (例如: riscv64, aarch64, x86_64)
  --cross-compile   交叉编译前缀，可为完整路径或仅前缀
                    (例如: riscv64-linux-gnu- 或 /path/to/bin/riscv64-linux-gnu-)
  --work-dir        工作目录前缀 (默认: 当前目录)
  --busybox-ver     BusyBox 版本 (默认: ${BUSYBOX_VER}, 支持 git[:REF][:update])
  --output          输出 initramfs 路径 (默认: <work-dir>/initrd-<arch>.cpio)
  --coremark        编译 CoreMark 性能测试程序 (git master, 静态链接),
                    打包为 /usr/bin/coremark 并输出 coremark-<arch> 产物
  --add-file S[:D]  复制额外文件到 initramfs, D 为 initramfs 内路径
                    (默认: /usr/bin/<文件名>, 可多次指定)
  -j,--threads      并行编译线程数 (默认: ${THREADS})
  --clean           构建完成后删除构建目录和日志目录
  -h,--help         显示帮助

示例:
  $(basename "$0") --arch riscv64 --cross-compile ./cross-riscv64-linux-gnu/bin/riscv64-linux-gnu-
  $(basename "$0") --arch aarch64 --cross-compile aarch64-linux-gnu-
  $(basename "$0") --arch riscv64 --busybox-ver git:1_37_0 --cross-compile riscv64-linux-gnu-
  $(basename "$0") --arch riscv64 --coremark --cross-compile riscv64-linux-gnu-
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)           ARCH="$2"; shift 2;;
        --cross-compile)  CROSS_COMPILE="$2"; shift 2;;
        --work-dir)       WORK_DIR="$2"; shift 2;;
        --busybox-ver)    BUSYBOX_VER="$2"; shift 2;;
        --output)         OUTPUT="$2"; shift 2;;
        --coremark)       WITH_COREMARK=true; shift;;
        --add-file)       ADD_FILES+=("$2"); shift 2;;
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
# 工具链设置
# ---------------------------------------------------------------------------
# 如果 CROSS_COMPILE 包含路径，自动将其 bin 目录加入 PATH
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
SRC_DIR="${WORK_DIR}/src-busybox-${ARCH}"
BUILD_DIR="${WORK_DIR}/build-busybox-${ARCH}"
LOG_DIR="${WORK_DIR}/logs-busybox-${ARCH}"
OUTPUT="${OUTPUT:-${WORK_DIR}/initrd-${ARCH}.cpio}"

mkdir -p "$DOWNLOAD_DIR" "$SRC_DIR" "$BUILD_DIR" "$LOG_DIR"

# ---------------------------------------------------------------------------
# 获取源码
# ---------------------------------------------------------------------------
step "=== 获取 BusyBox 源码 ==="
if [[ "$BUSYBOX_VER" == git* ]]; then
    BUSYBOX_SRC="$SRC_DIR/busybox"
    parse_git_ver "$BUSYBOX_VER"
    git_clone "https://git.busybox.net/busybox/" "$BUSYBOX_SRC" 1 "$_GIT_UPDATE" "$_GIT_REF"
else
    BUSYBOX_URL="${BUSYBOX_URL//\{VER\}/$BUSYBOX_VER}"
    if [[ "$BUSYBOX_URL" =~ \.(tar\.[a-z0-9]+)$ ]]; then
        ARCHIVE_EXT="${BASH_REMATCH[1]}"
    else
        ARCHIVE_EXT="tar.gz"
    fi
    ARCHIVE_FILE="$DOWNLOAD_DIR/busybox-${BUSYBOX_VER}.${ARCHIVE_EXT}"
    download "$BUSYBOX_URL" "$ARCHIVE_FILE"

    BUSYBOX_SRC="$SRC_DIR/busybox-${BUSYBOX_VER}"
    if [[ ! -d "$BUSYBOX_SRC" ]]; then
        info "解压: busybox-${BUSYBOX_VER}.${ARCHIVE_EXT}"
        tar -xf "$ARCHIVE_FILE" -C "$SRC_DIR"
    else
        info "源码目录已存在，跳过解压"
    fi
fi

# CoreMark 源码 (固定 git master 最新)
COREMARK_SRC=""
if [[ "$WITH_COREMARK" == true ]]; then
    step "=== 获取 CoreMark 源码 (git master) ==="
    COREMARK_SRC="$SRC_DIR/coremark"
    git_clone "$COREMARK_GIT" "$COREMARK_SRC" 1
fi

info "ARCH=$ARCH"
info "CROSS_COMPILE=$CROSS_COMPILE"
info "BusyBox 版本: $BUSYBOX_VER"
info "源码目录: $BUSYBOX_SRC"
info "构建目录: $BUILD_DIR"
info "日志目录: $LOG_DIR"
info "输出文件: $OUTPUT"

# ---------------------------------------------------------------------------
# 配置与编译
# ---------------------------------------------------------------------------

step "=== 配置 BusyBox ==="
assert_safe_to_delete "$BUILD_DIR"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

info "工作目录: $BUSYBOX_SRC"
info "生成默认配置 (ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE)"
build_step "busybox_defconfig" "$LOG_DIR" \
    make -C "$BUSYBOX_SRC" O="$BUILD_DIR" \
    ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig

# 启用静态链接，禁用不兼容模块
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' "$BUILD_DIR/.config"
sed -i 's/CONFIG_TC=y/# CONFIG_TC is not set/' "$BUILD_DIR/.config"
sed -i 's/CONFIG_SHA1_HWACCEL=y/# CONFIG_SHA1_HWACCEL is not set/' "$BUILD_DIR/.config"
sed -i 's/CONFIG_SHA256_HWACCEL=y/# CONFIG_SHA256_HWACCEL is not set/' "$BUILD_DIR/.config"
info "已启用 CONFIG_STATIC，已禁用 CONFIG_TC/SHA_HWACCEL"

step "=== 编译 BusyBox ==="
info "工作目录: $BUILD_DIR"
info "make -j${THREADS} ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE"
build_step "busybox_build" "$LOG_DIR" \
    make -C "$BUILD_DIR" -j"${THREADS}" \
    ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE"

info "安装 BusyBox 到 _install/"
build_step "busybox_install" "$LOG_DIR" \
    make -C "$BUILD_DIR" install \
    ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE"

# 输出 busybox 二进制信息
BUSYBOX_BIN=$(realpath "$BUILD_DIR/busybox")
ok "BusyBox 二进制: $BUSYBOX_BIN"
info "$(file "$BUSYBOX_BIN")"

# ---------------------------------------------------------------------------
# 编译 CoreMark (静态链接, 使用同一交叉 gcc)
# ---------------------------------------------------------------------------
if [[ "$WITH_COREMARK" == true ]]; then
    step "=== 编译 CoreMark (自带 Makefile, 静态链接) ==="
    # 显式 PORT_DIR=posix: 默认按宿主 uname 检测, 交叉编译语义不符
    # 显式 compile 目标: 默认 run 目标会执行二进制, 交叉编译下不可运行
    # ITERATIONS 默认 0 (运行时自动校准); PERFORMANCE_RUN=1: 标准性能测试种子
    COREMARK_OUT="$BUILD_DIR/coremark-bin"
    build_step "coremark_build" "$LOG_DIR" \
        make -C "$COREMARK_SRC" PORT_DIR=posix compile \
        CC="${CROSS_COMPILE}gcc" OPATH="$COREMARK_OUT/" \
        XCFLAGS="-static -DPERFORMANCE_RUN=1"
    mv "$COREMARK_OUT/coremark.exe" "$BUILD_DIR/coremark"
    ok "CoreMark 二进制: $BUILD_DIR/coremark"
    info "$(file "$BUILD_DIR/coremark")"
fi

# ---------------------------------------------------------------------------
# 阶段 4: 生成 initramfs
# ---------------------------------------------------------------------------
step "=== 生成 initramfs ==="
INITRAMFS_DIR="$BUILD_DIR/_initramfs"
BUSYBOX_INSTALL="$BUILD_DIR/_install"

info "复制 BusyBox 安装目录到 initramfs"
rm -rf "$INITRAMFS_DIR"
cp -a "$BUSYBOX_INSTALL" "$INITRAMFS_DIR"

info "创建 rootfs 目录结构"
mkdir -p "$INITRAMFS_DIR"/{dev,etc,lib,lib64,mnt/root,proc,root,sys,tmp,usr/share/udhcpc}

# 复制 udhcpc 默认脚本 (如果存在)
if [[ -f "$BUSYBOX_SRC/examples/udhcp/simple.script" ]]; then
    cp "$BUSYBOX_SRC/examples/udhcp/simple.script" "$INITRAMFS_DIR/usr/share/udhcpc/default.script"
fi

# 打包 CoreMark
if [[ "$WITH_COREMARK" == true ]]; then
    install -D -m 755 "$BUILD_DIR/coremark" "$INITRAMFS_DIR/usr/bin/coremark"
    info "已加入 CoreMark: /usr/bin/coremark"
fi

# 复制额外文件 (--add-file SRC[:DEST])
if [[ ${#ADD_FILES[@]} -gt 0 ]]; then
    info "复制额外文件到 initramfs"
    for spec in "${ADD_FILES[@]}"; do
        if [[ "$spec" == *:* ]]; then
            AF_SRC="${spec%%:*}"
            AF_DEST="${spec#*:}"
        else
            AF_SRC="$spec"
            AF_DEST="/usr/bin/$(basename "$spec")"
        fi
        [[ -f "$AF_SRC" ]] || error "--add-file 源文件不存在: $AF_SRC"
        mkdir -p "$INITRAMFS_DIR/$(dirname "$AF_DEST")"
        cp -a "$AF_SRC" "$INITRAMFS_DIR/${AF_DEST#/}"
        info "  $AF_SRC -> $AF_DEST"
    done
fi

info "生成 /init 脚本"
cat > "$INITRAMFS_DIR/init" << 'INIT_EOF'
#!/bin/sh

[ -e /dev/console ] || mknod -m 622 /dev/console c 5 1
[ -e /dev/tty0 ] || mknod -m 622 /dev/tty0 c 4 0

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[ -d /dev ]  || mkdir -m 0755 /dev
[ -d /root ] || mkdir -m 0700 /root
[ -d /sys ]  || mkdir /sys
[ -d /proc ] || mkdir /proc
[ -d /tmp ]  || mkdir /tmp
[ -d /mnt ]  || mkdir /mnt

mount -t devtmpfs none /dev
[ -d /dev/pts ] || mkdir /dev/pts
mount -t devpts devpts /dev/pts
mount -t proc   none /proc
mount -t sysfs  none /sys

echo "Welcome to BusyBox initramfs"

if [ -f "/bin/bash" ]; then
    setsid busybox cttyhack /bin/bash --login
else
    setsid busybox cttyhack /bin/sh --login
fi

busybox poweroff -f
INIT_EOF
chmod 755 "$INITRAMFS_DIR/init"

info "打包 cpio: $OUTPUT"
(cd "$INITRAMFS_DIR" && find . | cpio -o -H newc) > "$OUTPUT" 2>/dev/null

OUTPUT=$(realpath "$OUTPUT")
ok "BusyBox ${BUSYBOX_VER} 交叉编译完成！"
echo -e "initramfs: ${GREEN}${OUTPUT}${NC} ($(du -h "$OUTPUT" | cut -f1))"

# CoreMark 发布产物: 与 initrd-<arch>.cpio 并列, 不受 --clean 影响
if [[ "$WITH_COREMARK" == true ]]; then
    cp "$BUILD_DIR/coremark" "${WORK_DIR}/coremark-${ARCH}"
    echo -e "coremark : ${GREEN}${WORK_DIR}/coremark-${ARCH}${NC} ($(du -h "${WORK_DIR}/coremark-${ARCH}" | cut -f1))"
fi

# 构建后处理
clean_build_dir "$BUILD_DIR" "$LOG_DIR" "$CLEAN_BUILD"
