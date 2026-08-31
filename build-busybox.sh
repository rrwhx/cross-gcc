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
# 组件版本默认值来自 versions.env (由 lib.sh 加载)，可用环境变量或命令行覆盖
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
启动行为: 内核 cmdline "--" 后的内容会作为参数传给 /init 并经 shell -c 执行后关机,
无参数时进入交互 shell, 优先 bash (例: qemu -append "console=ttyS0 -- /root/coremark")

  --arch            目标架构 (例如: riscv64, aarch64, x86_64)
  --cross-compile   交叉编译前缀，可为完整路径或仅前缀
                    (例如: riscv64-linux-gnu- 或 /path/to/bin/riscv64-linux-gnu-)
  --work-dir        工作目录前缀 (默认: 当前目录)
  --busybox-ver     BusyBox 版本 (默认: ${BUSYBOX_VER}, 支持 git[:REF][:update])
  --output          输出 initramfs 路径 (默认: <work-dir>/initrd-<arch>.cpio)
  --coremark        编译 CoreMark 性能测试程序 (git master, 静态链接),
                    打包为 /root/coremark 并输出 coremark-<arch> 产物
  --add-file S[:D]  复制额外文件/目录到 initramfs (目录递归拷贝),
                    D 为 initramfs 内目标路径 (默认: /root/<名称>, 可多次指定)
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
    install -D -m 755 "$BUILD_DIR/coremark" "$INITRAMFS_DIR/root/coremark"
    info "已加入 CoreMark: /root/coremark"
fi

# 复制额外文件/目录 (--add-file SRC[:DEST], 目录递归拷贝)
if [[ ${#ADD_FILES[@]} -gt 0 ]]; then
    info "复制额外文件/目录到 initramfs"
    for spec in "${ADD_FILES[@]}"; do
        if [[ "$spec" == *:* ]]; then
            AF_SRC="${spec%%:*}"
            AF_DEST="${spec#*:}"
        else
            AF_SRC="$spec"
            AF_DEST="/root/$(basename "$spec")"
        fi
        [[ -e "$AF_SRC" ]] || error "--add-file 源不存在: $AF_SRC"
        mkdir -p "$INITRAMFS_DIR/$(dirname "${AF_DEST#/}")"
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

# --- virtio-9p share auto-mount -------------------------------------------
# Mounts every virtio-9p share the host exported, at <base>/<mount_tag>.
# Runs before the workload so shares are ready; failures only warn, because a
# missing share must not stop the workload from running.
#
# Host side (one -device per tag):
#   -fsdev local,id=fs0,path=/host/dir,security_model=none \
#   -device virtio-9p-device,fsdev=fs0,mount_tag=share
#   -> guest gets /mnt/share
#
# Tunables (the kernel exports unrecognized cmdline KEY=VALUE as env, so these
# can be set straight from -append):
#   MOUNT9P=0          skip entirely
#   MOUNT9P_BASE=DIR   mount root, default /mnt
#   MOUNT9P_OPTS=STR   mount -o options; 9p2000.L gives full POSIX semantics,
#                      and the default msize is small enough to make large
#                      file I/O noticeably slow
#   MOUNT9P_RO=1       mount read-only
#   MOUNT9P_SYSFS_ROOT overrides the virtio device dir (testing only)

# Extract msize=N from a comma-separated mount option list (empty if absent).
_9p_msize() {
    for _kv in $(printf '%s' "$1" | tr ',' ' '); do
        case "$_kv" in
            msize=*) printf '%s' "${_kv#msize=}"; return ;;
        esac
    done
}

mount_9p_shares() {
    if [ "${MOUNT9P:-1}" != 1 ]; then
        echo "9p: disabled by MOUNT9P=${MOUNT9P}"
        return 0
    fi

    _base=${MOUNT9P_BASE:-/mnt}
    _opts=${MOUNT9P_OPTS:-trans=virtio,version=9p2000.L,msize=262144}
    [ "${MOUNT9P_RO:-0}" = 1 ] && _opts="$_opts,ro"
    _root=${MOUNT9P_SYSFS_ROOT:-/sys/bus/virtio/devices}
    _n=0

    for _dev in "$_root"/virtio*; do
        [ -f "$_dev/mount_tag" ] || continue
        # mount_tag is a fixed-size NUL-padded sysfs buffer; the NULs must be
        # stripped or mount gets a tag with invisible bytes and cannot find it.
        _tag=$(tr -d '\0' < "$_dev/mount_tag" 2>/dev/null)
        [ -n "$_tag" ] || continue
        # The tag becomes a path component: reject separators and whitespace.
        case "$_tag" in
            */*|*" "*|*"	"*)
                echo "9p: rejecting tag [$_tag] (path separator or whitespace)"
                continue ;;
        esac

        _mp=$_base/$_tag
        # Skip if already mounted: re-mounting the same tag stacks mounts
        # silently instead of failing, which is harder to debug.
        if grep -q " $_mp 9p " /proc/mounts 2>/dev/null; then
            echo "9p: [$_tag] already mounted on $_mp"
            _n=$((_n+1))
            continue
        fi
        if ! mkdir -p "$_mp" 2>/dev/null; then
            echo "9p: cannot create mount point $_mp" >&2
            continue
        fi

        if mount -t 9p -o "$_opts" "$_tag" "$_mp" 2>/tmp/.9p.err; then
            # msize is negotiated with the server, and the kernel silently
            # clamps it to whatever the transport accepts. Report what actually
            # took effect, not what we asked for -- a silently reduced msize is
            # a common cause of "9p feels slow" and is otherwise invisible.
            _eff=""
            while read -r _s _d _t _o _rest; do
                [ "$_d" = "$_mp" ] && [ "$_t" = 9p ] && _eff=$_o
            done < /proc/mounts
            _want_ms=$(_9p_msize "$_opts")
            _got_ms=$(_9p_msize "$_eff")
            # The kernel only lists msize in /proc/mounts when it was requested,
            # so omit it rather than printing a confusing "unknown".
            if [ -n "$_got_ms" ]; then
                echo "9p: mounted [$_tag] -> $_mp (msize=$_got_ms)"
            else
                echo "9p: mounted [$_tag] -> $_mp"
            fi
            if [ -n "$_want_ms" ] && [ -n "$_got_ms" ] && [ "$_want_ms" != "$_got_ms" ]; then
                echo "9p: NOTE [$_tag] msize clamped by kernel: requested $_want_ms, effective $_got_ms" >&2
            fi
            _n=$((_n+1))
        else
            echo "9p: FAILED [$_tag] -> $_mp: $(tr '\n' ' ' < /tmp/.9p.err)" >&2
            # A kernel without 9p is the most common cause and mount's own
            # message does not say so.
            grep -qw 9p /proc/filesystems 2>/dev/null \
                || echo "9p: kernel has no 9p fs (need CONFIG_9P_FS + CONFIG_NET_9P_VIRTIO)" >&2
        fi
        rm -f /tmp/.9p.err
    done

    [ "$_n" = 0 ] || echo "9p: $_n share(s) ready under $_base"
}
mount_9p_shares

# Prefer bash when available
if [ -x /bin/bash ]; then
    SHELL=/bin/bash
else
    SHELL=/bin/sh
fi
export SHELL

# Kernel passes cmdline content after "--" to /init as arguments.
# With arguments: run them via $SHELL -c, then power off.
# Without arguments: default to an interactive login shell.
# Example: qemu -append "console=ttyS0 -- /root/coremark"
if [ $# -gt 0 ]; then
    echo "init: $SHELL -c \"$*\""
    set -- -c "$*"
else
    set -- --login
fi

setsid busybox cttyhack "$SHELL" "$@"
echo "init: exit code: $?"

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
