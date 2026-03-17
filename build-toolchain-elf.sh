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

# 默认版本设置
BINUTILS_VER="2.45"
GCC_VER="15.2.0"
NEWLIB_VER="4.6.0.20260123"

# 初始化参数
ARCH=""
DOWNLOAD_DIR=""; SRC_DIR=""; BUILD_DIR=""; LOG_DIR=""; PREFIX_DIR=""; WORK_DIR=""
THREADS="$(nproc || sysctl -n hw.logicalcpu_max 2>/dev/null || error "detect cpu num")"  # 默认并行构建线程数
CLEAN_BUILD=false
ARCHIVE_RESULT=false

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
  --cross-prefix 工具链安装前缀 (默认: WORK_DIR/cross-TARGET)
  --threads      构建线程数 (默认: $(nproc))

版本控制选项:
  --binutils-ver binutils 版本 (默认: $BINUTILS_VER)
  --gcc-ver      gcc 版本 (默认: $GCC_VER, 支持 'git' 使用最新开发版)
  --newlib-ver   newlib 版本 (默认: $NEWLIB_VER)

构建后处理选项:
  --clean        构建完成后删除构建目录和日志目录
  --archive      构建完成后将工具链打包成 tar.xz 并删除原目录

  -h,--help      显示帮助
示例:
  $(basename "$0") --arch aarch64
  $(basename "$0") --arch riscv64 --gcc-ver 14.2.0
EOF
    exit 1
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
        --cross-prefix)PREFIX_DIR="$2"; shift 2;;
        --threads)     THREADS="$2"; shift 2;;
        --binutils-ver)BINUTILS_VER="$2"; shift 2;;
        --gcc-ver)     GCC_VER="$2"; shift 2;;
        --newlib-ver)  NEWLIB_VER="$2"; shift 2;;
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

# 设置默认目录
if [[ -n "$WORK_DIR" ]]; then
    mkdir -p "$WORK_DIR"
fi
BASE_DIR="${WORK_DIR:-$PWD}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$BASE_DIR/downloads}"
SRC_DIR="${SRC_DIR:-$DOWNLOAD_DIR}"
BUILD_DIR="${BUILD_DIR:-$BASE_DIR/build-$TARGET}"
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs-$TARGET}"
PREFIX_DIR="${PREFIX_DIR:-$BASE_DIR/cross-$TARGET}"

DOWNLOAD_DIR=$(realpath "$DOWNLOAD_DIR")
SRC_DIR=$(realpath "$SRC_DIR")
BUILD_DIR=$(realpath "$BUILD_DIR")
LOG_DIR=$(realpath "$LOG_DIR")
PREFIX_DIR=$(realpath "$PREFIX_DIR")
mkdir -p "$DOWNLOAD_DIR" "$SRC_DIR" "$BUILD_DIR" "$LOG_DIR" "$PREFIX_DIR"

# 设置 GCC 源码目录
if [[ "$GCC_VER" == "git" ]]; then
    GCC_SRC_DIR="gcc"
else
    GCC_SRC_DIR="gcc-${GCC_VER}"
fi

# 设置各组件源码目录
SRC_DIR_BINUTILS="$SRC_DIR/binutils-${BINUTILS_VER}"
SRC_DIR_GCC="$SRC_DIR/$GCC_SRC_DIR"
SRC_DIR_NEWLIB="$SRC_DIR/newlib-${NEWLIB_VER}"

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
CROSS_PREFIX="$PREFIX_DIR"
TARGET_PREFIX="$PREFIX_DIR/$TARGET"
mkdir -p "$TARGET_PREFIX"
info "工具链安装前缀: $CROSS_PREFIX"
info "目标 sysroot: $TARGET_PREFIX"
info "下载目录: $DOWNLOAD_DIR"
info "源码目录: $SRC_DIR"
info "构建目录: $BUILD_DIR"
info "日志目录: $LOG_DIR"
info "构建线程数: $THREADS"

step "获取源代码"
dl_files=(
    "https://mirrors.tuna.tsinghua.edu.cn/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"
)

if [[ "$GCC_VER" != "git" ]]; then
    dl_files+=("https://mirrors.tuna.tsinghua.edu.cn/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz")
fi

for url in "${dl_files[@]}"; do
    filename=$(basename "${url}")
    download "$url" "$DOWNLOAD_DIR/$filename"
done

if [[ "$GCC_VER" == "git" ]]; then
    if [[ ! -d "$SRC_DIR_GCC" ]]; then
        step "克隆 GCC 仓库"
        if ! command -v git &> /dev/null; then
            error "git 未安装，无法克隆 GCC 仓库"
        fi
        git clone --depth 1 https://mirrors.tuna.tsinghua.edu.cn/git/gcc.git "$SRC_DIR_GCC" || error "克隆 GCC 失败"
    else
        info "GCC 源码目录已存在，跳过克隆"
    fi
fi

# 处理 newlib 的特殊路径
NEWLIB_ARCHIVE=${NEWLIB_ARCHIVE:-"newlib-${NEWLIB_VER}.tar.gz"}
if [[ -f "$NEWLIB_ARCHIVE" ]]; then
    if [[ ! -f "$DOWNLOAD_DIR/newlib-${NEWLIB_VER}.tar.gz" ]]; then
        info "从 ${NEWLIB_ARCHIVE} 复制文件到 ${DOWNLOAD_DIR}"
        cp "${NEWLIB_ARCHIVE}" "$DOWNLOAD_DIR/newlib-${NEWLIB_VER}.tar.gz"
    else
        info "已存在: $DOWNLOAD_DIR/newlib-${NEWLIB_VER}.tar.gz，跳过复制"
    fi
else
    download "https://sourceware.org/pub/newlib/newlib-${NEWLIB_VER}.tar.gz" "$DOWNLOAD_DIR/newlib-${NEWLIB_VER}.tar.gz"
fi

# 解压源码
step "解压源代码"
for url in "${dl_files[@]}"; do
    filename=$(basename "${url}")
    info "解压: ${filename}"
    srcdir="$SRC_DIR/${filename%.tar*}"
    if [[ -d "$srcdir" ]]; then
        info "$srcdir 已解压"
    else
        tar -xf ${DOWNLOAD_DIR}/${filename} -C "$SRC_DIR" || error "解压失败"
    fi
done

# 解压 newlib
info "解压: newlib-${NEWLIB_VER}.tar.gz"
if [[ -d "$SRC_DIR_NEWLIB" ]]; then
    info "$SRC_DIR_NEWLIB 已解压"
else
    tar -xf "$DOWNLOAD_DIR/newlib-${NEWLIB_VER}.tar.gz" -C "$SRC_DIR" || error "解压 newlib 失败"
fi

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
    --disable-readline

build_step "build" "${LOG_DIR_BINUTILS}" \
    make -j${THREADS}

build_step "install" "${LOG_DIR_BINUTILS}" \
    make install-strip

# 准备 GCC 源码并下载依赖库
step "==== 准备 GCC 源码 ==="
cd "$SRC_DIR_GCC" || error "无法进入构建目录"
if [[ ! -f "prereq_done" ]]; then
    build_step "gcc_download_prerequisites" "${LOG_DIR_GCC_INITIAL}" "${SCRIPT_DIR}/prepare_gcc.sh"
    info "GCC 依赖下载完成 (日志: $LOG_DIR_GCC_INITIAL)"
    touch prereq_done
fi

# 初始GCC构建
step "=== 初始GCC构建 ==="
mkdir -p "$BUILD_DIR_GCC_INITIAL"
cd "$BUILD_DIR_GCC_INITIAL" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR_GCC_INITIAL}" \
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
    --disable-tm-clone-registry

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
    --disable-gprofng

build_step "build" "${LOG_DIR_GCC_FINAL}" \
    make -j${THREADS}

build_step "install" "${LOG_DIR_GCC_FINAL}" \
    make install-strip-host install-target

# 完成输出
ok "=== 构建完成 ==="
echo -e "交叉编译器路径: ${GREEN}${CROSS_PREFIX}/bin${NC}"
echo -e "系统根目录: ${GREEN}${CROSS_PREFIX}/${TARGET}${NC}"
echo -e "日志目录: ${GREEN}${LOG_DIR}${NC}"

# 构建后处理
clean_build_dir "$BUILD_DIR" "$LOG_DIR" "$CLEAN_BUILD"
archive_toolchain "$CROSS_PREFIX" "$ARCHIVE_RESULT"