#!/usr/bin/env bash
# Cross GCC toolchain build script
# 支持通过 --arch 和 --libc 构建交叉编译工具链（binutils, gcc, Linux 头文件, glibc/musl）。

set -euo pipefail

# 获取脚本的绝对路径（在脚本开始时就确定）
if command -v readlink >/dev/null 2>&1; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    # macOS 兼容性处理
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
fi
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # 重置颜色

# 输出函数
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
step()  { echo -e "${GREEN}[STEP]${NC} $*"; }
ok()    { echo -e "${BLUE}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# 捕获错误并提示
trap 'error "错误发生在脚本第 ${LINENO} 行，详细信息请查看日志。"; exit 1' ERR

# 默认版本设置
BINUTILS_VER="2.45"
GCC_VER="15.2.0"
GLIBC_VER="2.42"
MUSL_VER="1.2.5"
LINUX_VER="6.17.6"

# 初始化参数
ARCH=""; LIBC=""
DOWNLOAD_DIR=""; SRC_DIR=""; BUILD_DIR=""; LOG_DIR=""; PREFIX_DIR=""
THREADS="$(nproc || sysctl -n hw.logicalcpu_max 2>/dev/null || error "detect cpu num")"  # 默认并行构建线程数
CLEAN_BUILD=false
ARCHIVE_RESULT=false

# 显示用法
usage() {
    cat <<EOF
用法: $(basename "$0") --arch ARCH --libc LIBC [选项]
  --arch         目标架构 (aarch64|loongarch64|riscv32|riscv64|i686|x86_64|mips|mipsel|mips64|mips64el)
  --libc         libc 类型 (glibc|musl)
  --download-dir 源码下载目录 (默认: ./downloads)
  --src-dir      源码解压目录 (默认: 与 download-dir 相同)
  --build-dir    构建工作目录 (默认: ./build-TARGET)
  --log-dir      日志目录 (默认: ./logs-TARGET)
  --cross-prefix 工具链安装前缀 (默认: ./cross-TARGET)
  --threads      构建线程数 (默认: $(nproc))

版本控制选项:
  --binutils-ver binutils 版本 (默认: $BINUTILS_VER)
  --gcc-ver      gcc 版本 (默认: $GCC_VER, 支持 'git' 使用最新开发版)
  --glibc-ver    glibc 版本 (默认: $GLIBC_VER)
  --musl-ver     musl 版本 (默认: $MUSL_VER)
  --linux-ver    linux 内核版本 (默认: $LINUX_VER)

构建后处理选项:
  --clean        构建完成后删除构建目录和日志目录
  --archive      构建完成后将工具链打包成 tar.xz 并删除原目录

  -h,--help      显示帮助
示例:
  $(basename "$0") --arch aarch64 --libc glibc
  $(basename "$0") --arch riscv64 --libc musl --gcc-ver 14.2.0 --linux-ver 6.12
EOF
    exit 1
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)        ARCH="$2"; shift 2;;
        --libc)        LIBC="$2"; shift 2;;
        --download-dir)DOWNLOAD_DIR="$2"; shift 2;;
        --src-dir)     SRC_DIR="$2"; shift 2;;
        --build-dir)   BUILD_DIR="$2"; shift 2;;
        --log-dir)     LOG_DIR="$2"; shift 2;;
        --cross-prefix)PREFIX_DIR="$2"; shift 2;;
        --threads)     THREADS="$2"; shift 2;;
        --binutils-ver)BINUTILS_VER="$2"; shift 2;;
        --gcc-ver)     GCC_VER="$2"; shift 2;;
        --glibc-ver)   GLIBC_VER="$2"; shift 2;;
        --musl-ver)    MUSL_VER="$2"; shift 2;;
        --linux-ver)   LINUX_VER="$2"; shift 2;;
        --clean)       CLEAN_BUILD=true; shift;;
        --archive)     ARCHIVE_RESULT=true; shift;;
        -h|--help)     usage;;
        *)             error "未知选项: $1"; usage;;
    esac
done

# 检查必须参数
if [[ -z "$ARCH" || -z "$LIBC" ]]; then
    error "--arch 和 --libc 参数为必需。"
    usage
fi

ARCH=$(echo "$ARCH" | tr '[:upper:]' '[:lower:]')
LIBC=$(echo "$LIBC" | tr '[:upper:]' '[:lower:]')

# 验证参数合法性
case "$ARCH" in
    arm|aarch64|loongarch64|riscv32|riscv64|i686|x86_64|mips|mipsel|mips64|mips64el) ;;
    *) error "不支持的架构: $ARCH"; exit 1;;
esac
case "$LIBC" in
    glibc|musl) ;;
    *) error "不支持的 libc 类型: $LIBC"; exit 1;;
esac

info "目标架构: $ARCH"
info "libc 类型: $LIBC"

# 显示版本信息
info "=== 组件版本信息 ==="
info "Binutils 版本: $BINUTILS_VER"
info "GCC 版本: $GCC_VER"
info "Glibc 版本: $GLIBC_VER"
info "Musl 版本: $MUSL_VER"
info "Linux 内核版本: $LINUX_VER"

# 根据架构和 libc 设置 TARGET 三元组
case "$ARCH" in
    arm)         TARGET_BASE="arm-linux";         CROSS_KERNEL_NAME="arm";      ;;
    aarch64)     TARGET_BASE="aarch64-linux";     CROSS_KERNEL_NAME="arm64";    ;;
    loongarch64) TARGET_BASE="loongarch64-linux"; CROSS_KERNEL_NAME="loongarch" ;;
    riscv64)     TARGET_BASE="riscv64-linux";     CROSS_KERNEL_NAME="riscv";    ;;
    riscv32)     TARGET_BASE="riscv32-linux";     CROSS_KERNEL_NAME="riscv";    ;;
    i686)        TARGET_BASE="i686-linux";        CROSS_KERNEL_NAME="x86";      ;;
    x86_64)      TARGET_BASE="x86_64-linux";      CROSS_KERNEL_NAME="x86";      ;;
    mips)        TARGET_BASE="mips-linux";        CROSS_KERNEL_NAME="mips";     ;;
    mipsel)      TARGET_BASE="mipsel-linux";      CROSS_KERNEL_NAME="mips";     ;;
    mips64)      TARGET_BASE="mips64-linux";      CROSS_KERNEL_NAME="mips";     ;;
    mips64el)    TARGET_BASE="mips64el-linux";    CROSS_KERNEL_NAME="mips";     ;;
esac
if [[ "$LIBC" == "glibc" ]]; then
    TARGET="${TARGET_BASE}-gnu"
else
    TARGET="${TARGET_BASE}-musl"
fi

if [[ "$ARCH" == mips64* ]]; then
    TARGET="${TARGET}abi64"
fi

if [[ "$ARCH" == "arm" ]]; then
    TARGET="${TARGET}eabihf"
fi

info "目标三元组 (TARGET) 已设置为: $TARGET"

gcc_extra_args=()
case "$TARGET" in
    riscv64-linux-musl|mips64el-linux-muslabi64|mips64-linux-muslabi64|mipsel-linux-musl|mips-linux-musl|i686-linux-musl|arm-linux-musleabihf) gcc_extra_args+=(--disable-libsanitizer) ;;
esac

glibc_extra_args=()
case "$TARGET" in
    aarch64-linux-gnu) glibc_extra_args+=(libc_cv_slibdir=/usr/lib64) ;;
    x86_64-linux-gnu)  glibc_extra_args+=(libc_cv_slibdir=/usr/lib) ;;
esac

musl_extra_args=()
case "$ARCH" in
    mips64el) musl_extra_args+=(--libdir=/usr/lib64) ;;
    mips64) musl_extra_args+=(--libdir=/usr/lib64) ;;
esac

# 设置默认目录
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$PWD/downloads}"
SRC_DIR="${SRC_DIR:-$DOWNLOAD_DIR}"
BUILD_DIR="${BUILD_DIR:-$PWD/build-$TARGET}"
LOG_DIR="${LOG_DIR:-$PWD/logs-$TARGET}"
PREFIX_DIR="${PREFIX_DIR:-$PWD/cross-$TARGET}"

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
SRC_DIR_GLIBC="$SRC_DIR/glibc-${GLIBC_VER}"
SRC_DIR_MUSL="$SRC_DIR/musl-${MUSL_VER}"
SRC_DIR_LINUX="$SRC_DIR/linux-${LINUX_VER}"

# 设置各组件构建目录
BUILD_DIR_BINUTILS="$BUILD_DIR/build-binutils"
BUILD_DIR_GCC_INITIAL="$BUILD_DIR/build-gcc-initial"
BUILD_DIR_GCC_FINAL="$BUILD_DIR/build-gcc-final"
BUILD_DIR_GLIBC="$BUILD_DIR/build-glibc"
BUILD_DIR_MUSL="$BUILD_DIR/build-musl"

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

# 下载函数：若文件不存在则使用 wget 或 curl 下载
download() {
    url="$1"; dest="$2"
    if [[ -f "$dest" ]]; then
        info "已存在: $dest，跳过下载"
    else
        info "下载 $url ..."
        if command -v wget > /dev/null; then
            wget -O "$dest" "$url"
        elif command -v curl > /dev/null; then
            curl -L -o "$dest" "$url"
        else
            error "未安装 wget 或 curl，无法下载文件"
            exit 1
        fi
    fi
}

step "下载源代码"
dl_files=(
    "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"
    "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
    "https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VER}.tar.xz"
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VER}.tar.xz"
    "https://musl.libc.org/releases/musl-${MUSL_VER}.tar.gz"
)
dl_files=(
    "https://mirrors.tuna.tsinghua.edu.cn/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"
    "https://mirrors.tuna.tsinghua.edu.cn/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
    "https://mirrors.tuna.tsinghua.edu.cn/gnu/glibc/glibc-${GLIBC_VER}.tar.xz"
    "https://mirrors.tuna.tsinghua.edu.cn/kernel/v6.x/linux-${LINUX_VER}.tar.xz"
    "https://musl.libc.org/releases/musl-${MUSL_VER}.tar.gz"
)

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
    unset 'dl_files[1]'  # 删除索引1（gcc）
fi

for url in "${dl_files[@]}"; do
    info "下载: ${url}"
    wget -nc -q --show-progress -P "$DOWNLOAD_DIR" "$url" || error "下载失败"
done

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

# 构建函数
build_step() {
    local name=$1
    local log_dir=$2
    mkdir -p $log_dir
    shift 2

    step "执行: $*"
    if "$@" 2>&1 | cat > "${log_dir}/${name}.log"; then
        ok "${name} 成功"
    else
        error "${name} 失败，详见 ${log_dir}/${name}.log"
    fi
}

# 构建Binutils
step "=== 构建 Binutils ==="
mkdir -p "$BUILD_DIR_BINUTILS"
cd "$BUILD_DIR_BINUTILS" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR}/binutils" \
    "$SRC_DIR_BINUTILS/configure" \
    --target="$TARGET" \
    --prefix="$CROSS_PREFIX" \
    --disable-multilib \
    --enable-gold=yes \
    --enable-plugins \
    --disable-gprofng

build_step "build" "${LOG_DIR}/binutils" \
    make -j${THREADS}

build_step "install" "${LOG_DIR}/binutils" \
    make install-strip

# 准备 GCC 源码并下载依赖库
step "==== 准备 GCC 源码 ==="
cd "$SRC_DIR_GCC" || error "无法进入构建目录"
# 下载 GMP/MPFR/MPC 等依赖（放入 gcc/ 目录）
if [[ ! -f "prereq_done" ]]; then
    build_step "gcc_download_prerequisites" "${LOG_DIR}/gcc" "${SCRIPT_DIR}/prepare_gcc.sh"
    info "GCC 依赖下载完成 (日志: $LOG_DIR/gcc)"
    touch prereq_done
fi

# 初始GCC构建（仅支持C语言）
step "=== 初始GCC构建 ==="
mkdir -p "$BUILD_DIR_GCC_INITIAL"
cd "$BUILD_DIR_GCC_INITIAL" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR}/gcc" \
    "$SRC_DIR_GCC/configure" \
    --target="$TARGET" \
    --prefix="$CROSS_PREFIX" \
    --disable-multilib \
    --disable-bootstrap \
    --enable-languages=c \
    --without-headers \
    --with-newlib \
    --disable-nls \
    --disable-shared --disable-threads --disable-libatomic --disable-libgomp --disable-libquadmath --disable-libssp --disable-libvtv --disable-libstdcxx

build_step "build" "${LOG_DIR}/gcc" \
    make -j${THREADS}

build_step "install" "${LOG_DIR}/gcc" \
    make install-strip

# 准备Linux头文件
step "=== 准备Linux头文件 ==="
cd "$SRC_DIR_LINUX" || error "无法进入Linux源码目录"
build_step "headers" "${LOG_DIR}/glibc" \
    make ARCH="${CROSS_KERNEL_NAME}" INSTALL_HDR_PATH="${CROSS_PREFIX}/${TARGET}/usr" headers_install

# 构建 C 库（glibc 或 musl）
if [[ "$LIBC" == "glibc" ]]; then
    # 构建glibc
    step "=== 构建 glibc ==="
    mkdir -p "$BUILD_DIR_GLIBC"
    cd "$BUILD_DIR_GLIBC" || error "无法进入构建目录"

    build_step  "configure" "${LOG_DIR}/glibc" \
        env CC="${CROSS_PREFIX}/bin/${TARGET}-gcc" \
        CXX="${CROSS_PREFIX}/bin/${TARGET}-g++" \
        "$SRC_DIR_GLIBC/configure" \
        --build="$(gcc -dumpmachine)" \
        --host="$TARGET" \
        --target="$TARGET" \
        --prefix="/usr" \
        --exec-prefix="/usr" \
        --with-headers="${CROSS_PREFIX}/${TARGET}/usr/include" \
        --with-binutils="${CROSS_PREFIX}/$TARGET/bin" \
        --disable-multilib \
        --without-selinux \
        libc_cv_forced_unwind=yes "${glibc_extra_args[@]}"

    build_step "build" "${LOG_DIR}/glibc" \
        make -j${THREADS}

    build_step "install" "${LOG_DIR}/glibc" \
        make install DESTDIR="${CROSS_PREFIX}/${TARGET}"
else
    step "=== 构建 musl ==="
    mkdir -p "$BUILD_DIR_MUSL"
    cd "$BUILD_DIR_MUSL" || error "无法进入构建目录"

# remove arch specified string optimization
rm -rf "$SRC_DIR_MUSL/src/string/"*/
cat > "$SRC_DIR_MUSL/src/stdio/sprintf.c" <<EOF
#include <stdio.h>
#include <stdarg.h>

int sprintf(char *restrict s, const char *restrict fmt, ...)
{
	char buf[4096];
	int ret;
	va_list ap;
	va_start(ap, fmt);
	ret = vsprintf(buf, fmt, ap);
	va_end(ap);
	for (int i=0 ; i<ret + 1; i++) {
		s[i] = buf[i];
	}
	return ret;
}
EOF

    build_step  "configure" "${LOG_DIR}/musl" \
        env CC="${CROSS_PREFIX}/bin/${TARGET}-gcc" \
        CXX="${CROSS_PREFIX}/bin/${TARGET}-g++" \
        CROSS_COMPILE="${CROSS_PREFIX}/bin/${TARGET}-" \
        "$SRC_DIR_MUSL/configure" \
        --build="$(gcc -dumpmachine)" \
        --host="$TARGET" \
        --target="$TARGET" \
        --prefix="/usr" \
        --exec-prefix="/usr" "${musl_extra_args[@]}"

    build_step "build" "${LOG_DIR}/musl" \
        make -j${THREADS}

    build_step "install" "${LOG_DIR}/musl" \
        make install DESTDIR="${CROSS_PREFIX}/${TARGET}"

cat > ${CROSS_PREFIX}/${TARGET}/usr/include/execinfo.h <<EOF
#ifndef _EXECINFO_H
#define _EXECINFO_H 1

static inline int backtrace (void **__array, int __size) {return 0;}
static inline char **backtrace_symbols (void *const *__array, int __size) {return (char**)0;}
static inline void backtrace_symbols_fd (void *const *__array, int __size, int __fd) {}
#endif /* execinfo.h  */
EOF

fi

# 完整GCC构建（包含C/C++）
step "=== 完整GCC构建 ==="
mkdir -p "$BUILD_DIR_GCC_FINAL"
cd "$BUILD_DIR_GCC_FINAL" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR}/gcc" \
    "$SRC_DIR_GCC/configure" \
    --target="$TARGET" \
    --prefix="$CROSS_PREFIX" \
    --disable-multilib \
    --disable-bootstrap \
    --enable-languages=c,c++,fortran,lto \
    --with-sysroot="${CROSS_PREFIX}/${TARGET}" \
    --with-build-sysroot="${CROSS_PREFIX}/${TARGET}" \
    --enable-threads=posix \
    --enable-shared \
    --disable-gprofng "${gcc_extra_args[@]}"

build_step "build" "${LOG_DIR}/gcc" \
    make -j${THREADS}

build_step "install" "${LOG_DIR}/gcc" \
    make install-strip-host install-target

# 完成输出
ok "=== 构建完成 ==="
echo -e "交叉编译器路径: ${GREEN}${CROSS_PREFIX}/bin${NC}"
echo -e "系统根目录: ${GREEN}${CROSS_PREFIX}/${TARGET}${NC}"
echo -e "日志目录: ${GREEN}${LOG_DIR}${NC}"

# 构建后处理
if [[ "$CLEAN_BUILD" == true ]]; then
    step "=== 清理构建目录和日志目录 ==="
    if [[ -d "$BUILD_DIR" ]]; then
        info "删除构建目录和日志目录: $BUILD_DIR $LOG_DIR"
        rm -rf "$BUILD_DIR"
        rm -rf "$LOG_DIR"
        ok "构建目录和日志目录清理完成"
    else
        warn "构建目录和日志目录不存在，跳过清理"
    fi
fi

if [[ "$ARCHIVE_RESULT" == true ]]; then
    step "=== 打包工具链 ==="
    if [[ -d "$CROSS_PREFIX" ]]; then
        # 获取工具链目录的父目录和目录名
        PARENT_DIR="$(dirname "$CROSS_PREFIX")"
        TOOLCHAIN_NAME="$(basename "$CROSS_PREFIX")"
        ARCHIVE_NAME="$PARENT_DIR/${TOOLCHAIN_NAME}.tar.xz"

        info "打包工具链到: $ARCHIVE_NAME"

        # 使用 tar 的 -C 选项指定工作目录，避免 cd
        if tar -cJf "$ARCHIVE_NAME" -C "$PARENT_DIR" "$TOOLCHAIN_NAME" 2>/dev/null; then
            ok "工具链打包完成: $ARCHIVE_NAME"

            # 删除原目录
            info "删除原工具链目录: $CROSS_PREFIX"
            rm -rf "$CROSS_PREFIX"
            ok "原目录删除完成"

            echo -e "打包文件: ${GREEN}$ARCHIVE_NAME${NC}"
        else
            error "打包失败"
        fi
    else
        warn "工具链目录不存在，跳过打包"
    fi
fi
