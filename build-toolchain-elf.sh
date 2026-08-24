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

# 默认版本设置（支持环境变量覆盖）
BINUTILS_VER="${BINUTILS_VER:-2.46.1}"
GCC_VER="${GCC_VER:-16.1.0}"
NEWLIB_VER="${NEWLIB_VER:-4.6.0.20260123}"

# 初始化参数
ARCH=""
DOWNLOAD_DIR=""; SRC_DIR=""; BUILD_DIR=""; LOG_DIR=""; INSTALL_DIR=""; WORK_DIR=""
# MIRROR 默认值由 lib.sh 提供，可通过 --mirror 覆盖
CLEAN_BUILD=false
ARCHIVE_RESULT=false
FRESH_BUILD=false
STATIC_BUILD=false

# 显示用法
usage() {
    cat <<EOF
用法: $(basename "$0") --arch ARCH [选项]
  --arch         目标架构 (aarch64|loongarch64|riscv32|riscv64|i686|x86_64|mips|mipsel|mips64|mips64el|arm)
  --work-dir     工作目录前缀 (默认: 当前目录)
  --download-dir 源码下载目录 (默认: WORK_DIR/downloads)
  --src-dir      源码解压目录 (默认: 与 download-dir 相同)
  --build-dir    构建工作目录 (默认: WORK_DIR/build-TARGET)
  --log-dir      日志目录 (默认: WORK_DIR/logs-TARGET)
  --install-dir  工具链安装前缀 (默认: WORK_DIR/cross-TARGET)
  -j,--threads   构建线程数 (默认: $THREADS)
  --mirror       下载镜像源 (默认: $MIRROR)

版本控制选项(支持 'git[:REF][:update]' 格式):
  --binutils-ver binutils 版本 (默认: $BINUTILS_VER)
  --gcc-ver      gcc 版本 (默认: $GCC_VER)
  --newlib-ver   newlib 版本 (默认: $NEWLIB_VER)
                 git 格式: git | git:TAG | git:update | git:TAG:update

构建后处理选项:
  --static       静态链接工具链自身的可执行文件 (交叉 gcc/as/ld 等)，产物不依赖 host
                 的 libc/libstdc++，可随意拷贝到同架构机器执行。需要 host 提供 libc.a
                 (如 glibc-static / libc6-dev)。目标侧库 (newlib/libgcc) 不受影响。
                 注意: liblto_plugin 只生成静态库 (不生成 .so)，因此 ld 的 LTO 插件
                 不可用，-flto 走 lto-wrapper 路径 (已验证 -flto 链接正常)。
                 构建/日志/安装目录会自动追加 -static 后缀，与动态构建互不干扰。
  --fresh        构建前删除已有的 build/log/install 目录
  --clean        构建完成后删除构建目录和日志目录
  --archive      构建完成后将工具链打包成 tar.xz 并删除原目录

  -h,--help      显示帮助
示例:
  $(basename "$0") --arch aarch64
  $(basename "$0") --arch riscv64 --gcc-ver 14.2.0
  $(basename "$0") --arch riscv64 --static --fresh
  $(basename "$0") --arch arm --binutils-ver git --gcc-ver git:update --newlib-ver git
EOF
    exit 0
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)        ARCH="$2"; shift 2;;
        --work-dir)    WORK_DIR="$2"; shift 2;;
        --download-dir)DOWNLOAD_DIR="$2"; shift 2;;
        --src-dir)     SRC_DIR="$2"; shift 2;;
        --build-dir)   BUILD_DIR="$2"; shift 2;;
        --log-dir)     LOG_DIR="$2"; shift 2;;
        --install-dir) INSTALL_DIR="$2"; shift 2;;
        --threads|-j)  THREADS="$2"; shift 2;;
        --mirror)      MIRROR="$2"; shift 2;;
        --binutils-ver)BINUTILS_VER="$2"; shift 2;;
        --gcc-ver)     GCC_VER="$2"; shift 2;;
        --newlib-ver)  NEWLIB_VER="$2"; shift 2;;
        --fresh)       FRESH_BUILD=true; shift;;
        --static)      STATIC_BUILD=true; shift;;
        --clean)       CLEAN_BUILD=true; shift;;
        --archive)     ARCHIVE_RESULT=true; shift;;
        -h|--help)     usage;;
        *)             error "未知选项: $1"; usage;;
    esac
done

# 检查必须参数
if [[ -z "$ARCH" ]]; then
    error "--arch 参数为必需。"
    usage
fi

ARCH=$(echo "$ARCH" | tr '[:upper:]' '[:lower:]')

# 验证参数合法性
case "$ARCH" in
    arm|aarch64|loongarch64|riscv32|riscv64|i686|x86_64|mips|mipsel|mips64|mips64el) ;;
    *) error "不支持的架构: $ARCH"; exit 1;;
esac

info "目标架构: $ARCH"

# 显示版本信息
info "=== 组件版本信息 ==="
info "Binutils 版本: $BINUTILS_VER"
info "GCC 版本: $GCC_VER"
info "Newlib 版本: $NEWLIB_VER"

# 根据架构和 libc 设置 TARGET 三元组
case "$ARCH" in
    arm)         TARGET_BASE="arm";         ;;
    aarch64)     TARGET_BASE="aarch64";     ;;
    loongarch64) TARGET_BASE="loongarch64"; ;;
    riscv64)     TARGET_BASE="riscv64";     ;;
    riscv32)     TARGET_BASE="riscv32";     ;;
    i686)        TARGET_BASE="i686";        ;;
    x86_64)      TARGET_BASE="x86_64";      ;;
    mips)        TARGET_BASE="mips";        ;;
    mipsel)      TARGET_BASE="mipsel";      ;;
    mips64)      TARGET_BASE="mips64";      ;;
    mips64el)    TARGET_BASE="mips64el";    ;;
esac

TARGET="${TARGET_BASE}-unknown-elf"

if [[ "$ARCH" == "arm" ]]; then
    TARGET="arm-none-eabi"
fi

info "目标三元组 (TARGET) 已设置为: $TARGET"
info "静态链接: $([[ "$STATIC_BUILD" == true ]] && echo 开启 || echo 关闭)"

# 静态链接处理
# binutils 的可执行文件由 libtool 链接: libtool 会把 -static 降级理解为"优先选用静态库",
# 只有 -all-static 才真正生成全静态可执行文件; 而 configure 会把空的 LDFLAGS 写进
# Makefile, 环境变量不生效, 必须用 make 命令行覆盖 (优先级最高且传递给子 make)。
# 但 -all-static 不能出现在 configure 阶段 (gcc 不认识该选项, 子目录 configure 会报
# "C compiler cannot create executables"), 所以先 make configure-host 跑完全部子目录
# configure, 再带 LDFLAGS=-all-static 编译链接。
# gcc 的 host 工具 (xgcc/cc1/cc1plus) 不经 libtool, configure 阶段 LDFLAGS=-static 即可;
# GCC 顶层把 host 的 LDFLAGS 与 target 的 LDFLAGS_FOR_TARGET 分开传递, 因此 newlib 与
# 目标侧 libgcc 不受影响。
binutils_static_args=()
binutils_make_args=()
gcc_static_args=()
gcc_configure_env=()
STATIC_SUFFIX=""
if [[ "$STATIC_BUILD" == true ]]; then
    STATIC_SUFFIX="-static"
    # 保留 --enable-plugins: libtool 安装 .a 时会调用 `ranlib --plugin`,
    # 关闭 plugins 会让新装的静态 ranlib 不认识该选项而导致安装失败。
    binutils_static_args+=(--disable-shared)
    binutils_make_args=("LDFLAGS=-all-static")

    gcc_static_args+=(--disable-plugin)
    gcc_configure_env=(env "LDFLAGS=-static")

    host_libc_a="$(gcc -print-file-name=libc.a 2>/dev/null || true)"
    if [[ ! -f "$host_libc_a" ]]; then
        warn "未找到 libc.a，静态链接可能失败。请安装 glibc-static (RPM) 或 libc6-dev (DEB)。"
    fi
fi

# 设置默认目录
if [[ -n "$WORK_DIR" ]]; then
    mkdir -p "$WORK_DIR"
fi
BASE_DIR="${WORK_DIR:-$PWD}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$BASE_DIR/downloads}"
SRC_DIR="${SRC_DIR:-$DOWNLOAD_DIR}"
BUILD_DIR="${BUILD_DIR:-$BASE_DIR/build-$TARGET$STATIC_SUFFIX}"
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs-$TARGET$STATIC_SUFFIX}"
INSTALL_DIR="${INSTALL_DIR:-$BASE_DIR/cross-$TARGET$STATIC_SUFFIX}"
canonicalize_dirs DOWNLOAD_DIR SRC_DIR BUILD_DIR LOG_DIR INSTALL_DIR

fresh_clean_dirs "$FRESH_BUILD" "$BUILD_DIR" "$LOG_DIR" "$INSTALL_DIR"

# 设置各组件源码目录
if [[ "$BINUTILS_VER" == git* ]]; then
    SRC_DIR_BINUTILS="$SRC_DIR/binutils"
else
    SRC_DIR_BINUTILS="$SRC_DIR/binutils-${BINUTILS_VER}"
fi

if [[ "$GCC_VER" == git* ]]; then
    SRC_DIR_GCC="$SRC_DIR/gcc"
else
    SRC_DIR_GCC="$SRC_DIR/gcc-${GCC_VER}"
fi

if [[ "$NEWLIB_VER" == git* ]]; then
    SRC_DIR_NEWLIB="$SRC_DIR/newlib"
else
    SRC_DIR_NEWLIB="$SRC_DIR/newlib-${NEWLIB_VER}"
fi

# 设置各组件构建目录
BUILD_DIR_BINUTILS="$BUILD_DIR/build-binutils"
BUILD_DIR_GCC_INITIAL="$BUILD_DIR/build-gcc-initial"
BUILD_DIR_GCC_FINAL="$BUILD_DIR/build-gcc-final"
BUILD_DIR_NEWLIB="$BUILD_DIR/build-newlib"

LOG_DIR_BINUTILS="$LOG_DIR/binutils"
LOG_DIR_GCC_INITIAL="$LOG_DIR/gcc-initial"
LOG_DIR_GCC_FINAL="$LOG_DIR/gcc-final"
LOG_DIR_NEWLIB="$LOG_DIR/newlib"

# 设置安装前缀和目标 sysroot
CROSS_PREFIX="$INSTALL_DIR"
TARGET_SYSROOT="$INSTALL_DIR/$TARGET"
mkdir -p "$TARGET_SYSROOT"
info "工具链安装前缀: $CROSS_PREFIX"
info "目标 sysroot: $TARGET_SYSROOT"
info "下载目录: $DOWNLOAD_DIR"
info "源码目录: $SRC_DIR"
info "构建目录: $BUILD_DIR"
info "日志目录: $LOG_DIR"
info "构建线程数: $THREADS"

step "获取源代码"
dl_files=()

fetch_source "$BINUTILS_VER" "$SRC_DIR_BINUTILS" "https://${MIRROR}/git/binutils-gdb.git" "https://${MIRROR}/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"
fetch_source "$GCC_VER" "$SRC_DIR_GCC" "https://${MIRROR}/git/gcc.git" "https://${MIRROR}/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
fetch_source "$NEWLIB_VER" "$SRC_DIR_NEWLIB" "https://sourceware.org/git/newlib-cygwin.git" "https://sourceware.org/pub/newlib/newlib-${NEWLIB_VER}.tar.gz"

# newlib 支持通过 NEWLIB_ARCHIVE 环境变量使用本地归档 (仅 release 版本)
if [[ "$NEWLIB_VER" != git* ]]; then
    NEWLIB_ARCHIVE=${NEWLIB_ARCHIVE:-"newlib-${NEWLIB_VER}.tar.gz"}
    if [[ -f "$NEWLIB_ARCHIVE" && ! -f "$DOWNLOAD_DIR/newlib-${NEWLIB_VER}.tar.gz" ]]; then
        info "从 ${NEWLIB_ARCHIVE} 复制文件到 ${DOWNLOAD_DIR}"
        cp "${NEWLIB_ARCHIVE}" "$DOWNLOAD_DIR/newlib-${NEWLIB_VER}.tar.gz"
    fi
fi

download_dl_files "$DOWNLOAD_DIR"

# 解压源码
step "解压源代码"
extract_dl_files "$DOWNLOAD_DIR" "$SRC_DIR"

# 导出环境变量以便工具链之间找到
export PATH="${CROSS_PREFIX}/bin:${PATH}"

# 构建Binutils
step "=== 构建 Binutils ==="
mkdir -p "$BUILD_DIR_BINUTILS"
cd "$BUILD_DIR_BINUTILS" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR_BINUTILS}" \
    "$SRC_DIR_BINUTILS/configure" \
    --target="$TARGET" \
    --prefix="$CROSS_PREFIX" \
    --disable-multilib \
    --enable-plugins \
    --disable-werror \
    --disable-gprofng \
    --disable-gdb \
    --disable-sim \
    --disable-libdecnumber \
    --disable-readline \
    "${binutils_static_args[@]}"

# 静态构建时先跑完子目录 configure (不带 -all-static, 否则 gcc 无法识别该选项)
if [[ "$STATIC_BUILD" == true ]]; then
    build_step "configure-host" "${LOG_DIR_BINUTILS}" make -j${THREADS} configure-host
fi

build_step "build" "${LOG_DIR_BINUTILS}" \
    make -j${THREADS} "${binutils_make_args[@]}"

build_step "install" "${LOG_DIR_BINUTILS}" \
    make install-strip "${binutils_make_args[@]}"

# 准备 GCC 源码并下载依赖库
step "==== 准备 GCC 源码 ==="
cd "$SRC_DIR_GCC" || error "无法进入构建目录"
if [[ ! -f "prereq_done" ]]; then
    build_step "gcc_download_prerequisites" "${LOG_DIR_GCC_INITIAL}" "${SCRIPT_DIR}/prepare-gcc.sh"
    info "GCC 依赖下载完成 (日志: $LOG_DIR_GCC_INITIAL)"
    touch prereq_done
fi

# 初始GCC构建
step "=== 初始GCC构建 ==="
mkdir -p "$BUILD_DIR_GCC_INITIAL"
cd "$BUILD_DIR_GCC_INITIAL" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR_GCC_INITIAL}" \
    "${gcc_configure_env[@]}" \
    "$SRC_DIR_GCC/configure" \
    --target="$TARGET" \
    --prefix="$CROSS_PREFIX" \
    --disable-bootstrap \
    --disable-multilib \
    --disable-shared \
    --disable-threads \
    --disable-tls \
    --enable-languages=c,c++ \
    --with-newlib \
    --with-sysroot="${CROSS_PREFIX}/${TARGET}" \
    --disable-libmudflap \
    --disable-libssp \
    --disable-libquadmath \
    --disable-libgomp \
    --disable-nls \
    --disable-tm-clone-registry \
    "${gcc_static_args[@]}"

build_step "build" "${LOG_DIR_GCC_INITIAL}" \
    make -j${THREADS} all-gcc

build_step "install" "${LOG_DIR_GCC_INITIAL}" \
    make install-gcc

# 构建 Newlib
step "=== 构建 Newlib ==="
mkdir -p "$BUILD_DIR_NEWLIB"
cd "$BUILD_DIR_NEWLIB" || error "无法进入构建目录"

build_step  "configure" "${LOG_DIR_NEWLIB}" \
    env CC_FOR_TARGET="${CROSS_PREFIX}/bin/${TARGET}-gcc" \
    CXX_FOR_TARGET="${CROSS_PREFIX}/bin/${TARGET}-g++" \
    "$SRC_DIR_NEWLIB/configure" \
    --target="$TARGET" \
    --prefix="$CROSS_PREFIX" \
    --enable-newlib-io-long-double \
    --enable-newlib-io-long-long \
    --enable-newlib-io-c99-formats \
    --enable-newlib-register-fini \
    CFLAGS_FOR_TARGET="-O2 -D_POSIX_MODE -ffunction-sections -fdata-sections" \
    CXXFLAGS_FOR_TARGET="-O2 -D_POSIX_MODE -ffunction-sections -fdata-sections"

build_step "build" "${LOG_DIR_NEWLIB}" \
    make -j${THREADS}

build_step "install" "${LOG_DIR_NEWLIB}" \
    make install

# 完整GCC构建
step "=== 完整GCC构建 ==="
mkdir -p "$BUILD_DIR_GCC_FINAL"
cd "$BUILD_DIR_GCC_FINAL" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR_GCC_FINAL}" \
    "${gcc_configure_env[@]}" \
    "$SRC_DIR_GCC/configure" \
    --target="$TARGET" \
    --disable-bootstrap \
    --prefix="$CROSS_PREFIX" \
    --disable-multilib \
    --disable-shared \
    --disable-threads \
    --enable-languages=c,c++ \
    --enable-tls \
    --with-newlib \
    --with-sysroot="${CROSS_PREFIX}/${TARGET}" \
    --with-native-system-header-dir=/include \
    --disable-libmudflap \
    --disable-libssp \
    --disable-libquadmath \
    --disable-libgomp \
    --disable-nls \
    --disable-tm-clone-registry \
    --disable-gprofng \
    "${gcc_static_args[@]}"

build_step "build" "${LOG_DIR_GCC_FINAL}" \
    make -j${THREADS}

build_step "install" "${LOG_DIR_GCC_FINAL}" \
    make install-strip-host install-target

# 完成输出
ok "=== 构建完成 ==="
echo -e "交叉编译器路径: ${GREEN}${CROSS_PREFIX}/bin${NC}"
echo -e "系统根目录: ${GREEN}${CROSS_PREFIX}/${TARGET}${NC}"
echo -e "日志目录: ${GREEN}${LOG_DIR}${NC}"

# 静态链接校验：确认关键可执行文件不再依赖动态库
if [[ "$STATIC_BUILD" == true ]]; then
    libexec_dir="$(dirname "$("${CROSS_PREFIX}/bin/${TARGET}-gcc" -print-prog-name=cc1 2>/dev/null || true)")"
    verify_static_binaries \
        "${CROSS_PREFIX}/bin/${TARGET}-as" "${CROSS_PREFIX}/bin/${TARGET}-ld" \
        "${CROSS_PREFIX}/bin/${TARGET}-ar" "${CROSS_PREFIX}/bin/${TARGET}-objdump" \
        "${CROSS_PREFIX}/bin/${TARGET}-gcc" "${CROSS_PREFIX}/bin/${TARGET}-g++" \
        "${libexec_dir}/cc1" "${libexec_dir}/cc1plus" || true
fi

# 构建后处理
clean_build_dir "$BUILD_DIR" "$LOG_DIR" "$CLEAN_BUILD"
archive_toolchain "$CROSS_PREFIX" "$ARCHIVE_RESULT"