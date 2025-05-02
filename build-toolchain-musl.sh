#!/bin/bash
set -eo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # 重置颜色

# 输出函数
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
step()  { echo -e "${GREEN}[STEP]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# 错误处理
trap 'error "脚本在行号 $LINENO 处中断"' ERR

# 配置参数
export TARGET="${TARGET:-riscv64-linux-musl}"

case "$TARGET" in
    aarch64-linux-musl)    CROSS_KERNEL_NAME=arm64 ;;
    riscv64-linux-musl)    CROSS_KERNEL_NAME=riscv ;;
    loongarch64-linux-musl) CROSS_KERNEL_NAME=loongarch ;;
    x86_64-linux-musl) CROSS_KERNEL_NAME=x86 ;;
    *) error "不支持的架构: $TARGET" ;;
esac

glibc_extra_args=()
case "$TARGET" in
    aarch64-linux-musl) glibc_extra_args+=(libc_cv_slibdir=/usr/lib64) ;;
    x86_64-linux-musl)  glibc_extra_args+=(libc_cv_slibdir=/usr/lib) ;;
esac

#export CROSS_KERNEL_NAME=riscv
export DOWNLOAD_DIR="${PWD}/downloads"
export CROSS_PREFIX="${PWD}/cross-toolchain-install-${TARGET}"
export WORK_DIR="${PWD}/cross-toolchain-build-${TARGET}"
export LOG_DIR="${WORK_DIR}/logs"
export PATH="${CROSS_PREFIX}/bin:${PATH}"

# 版本配置
BINUTILS_VER="2.44"   # 修正版本号
GCC_VER="15.1.0"
GLIBC_VER="2.41"
MUSL_VER="1.2.5"
LINUX_VER="6.14"

# 初始化目录
step "创建目录结构"
#sudo mkdir -p "$CROSS_PREFIX" || error "无法创建交叉编译目录"
#sudo chown -R "$(id -un):" "$CROSS_PREFIX" || error "无法修改目录权限"
# 创建交叉编译目录（智能判断sudo使用）

current_user=$(id -un)
if ! mkdir -p "$CROSS_PREFIX"; then
    sudo mkdir -p "$CROSS_PREFIX" || error "无法创建交叉编译目录"
    # 如果使用sudo创建，强制修改所有者
    sudo chown -R "$current_user:" "$CROSS_PREFIX" || error "无法修改目录权限"
else
    # 普通创建成功后，确保递归设置所有者
    chown -R "$current_user:" "$CROSS_PREFIX" 2>/dev/null || {
        warn "尝试普通用户权限设置所有权失败，使用sudo重试"
        sudo chown -R "$current_user:" "$CROSS_PREFIX" || error "无法修改目录权限"
    }
fi

mkdir -p "$LOG_DIR"/{binutils,gcc,glibc,musl} || error "无法创建日志目录"

# 安装依赖
step "安装系统依赖"
#sudo apt-get update 2>&1 | tee -a "${LOG_DIR}/deps.log"
sudo apt-get install -y \
    build-essential bison flex texinfo \
    python3 gawk git wget gzip bzip2 xz-utils \
    libgmp-dev libmpfr-dev libmpc-dev \
    gettext file rsync 2>&1 | tee -a "${LOG_DIR}/deps.log" || error "依赖安装失败"

# 下载源码
step "下载源代码"
dl_files=(
    "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"
    "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
    "https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VER}.tar.xz"
    "https://musl.libc.org/releases/musl-${MUSL_VER}.tar.gz"
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VER}.tar.xz"
)

for url in "${dl_files[@]}"; do
    info "下载: ${url}"
    wget -nc -q --show-progress -P "$DOWNLOAD_DIR" "$url" || error "下载失败"
done

# 解压源码
step "解压源代码"
for url in "${dl_files[@]}"; do
    filename=$(basename "${url}")
    info "解压: ${filename}"
    tar -xf ${DOWNLOAD_DIR}/${filename} -C "$WORK_DIR" || error "解压失败"
done

# 构建函数
build_step() {
    local name=$1
    local log_dir=$2
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
mkdir -p "${WORK_DIR}/build-binutils"
cd "${WORK_DIR}/build-binutils" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR}/binutils" \
    "../binutils-${BINUTILS_VER}/configure" \
    --target="$TARGET" \
    --prefix="$CROSS_PREFIX" \
    --disable-multilib \
    --enable-gold=yes \
    --enable-plugins \
    --disable-gprofng

build_step "build" "${LOG_DIR}/binutils" \
    make -j"$(nproc)"

build_step "install" "${LOG_DIR}/binutils" \
    make install

# 初始GCC构建（仅支持C语言）
step "=== 初始GCC构建 ==="
mkdir -p "${WORK_DIR}/build-gcc-initial"
cd "${WORK_DIR}/build-gcc-initial" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR}/gcc" \
    "../gcc-${GCC_VER}/configure" \
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
    make -j"$(nproc)"

build_step "install" "${LOG_DIR}/gcc" \
    make install

# 准备Linux头文件
step "=== 准备Linux头文件 ==="
cd "${WORK_DIR}/linux-${LINUX_VER}" || error "无法进入Linux源码目录"
build_step "headers" "${LOG_DIR}/glibc" \
    make ARCH="${CROSS_KERNEL_NAME}" INSTALL_HDR_PATH="${CROSS_PREFIX}/${TARGET}/usr" headers_install

## 构建glibc
#step "=== 构建 glibc ==="
#mkdir -p "${WORK_DIR}/build-glibc"
#cd "${WORK_DIR}/build-glibc" || error "无法进入构建目录"
#
#build_step  "configure" "${LOG_DIR}/glibc" \
#    env CC="${CROSS_PREFIX}/bin/${TARGET}-gcc" \
#    CXX="${CROSS_PREFIX}/bin/${TARGET}-g++" \
#    "../glibc-${GLIBC_VER}/configure" \
#    --build="$(dpkg-architecture -q DEB_BUILD_GNU_TYPE)" \
#    --host="$TARGET" \
#    --target="$TARGET" \
#    --prefix="/usr" \
#    --exec-prefix="/usr" \
#    --with-headers="${CROSS_PREFIX}/${TARGET}/usr/include" \
#    --with-binutils="${CROSS_PREFIX}/$TARGET/bin" \
#    --disable-multilib \
#    --without-selinux \
#    libc_cv_forced_unwind=yes "${glibc_extra_args[@]}"
#
#build_step "build" "${LOG_DIR}/glibc" \
#    make -j"$(nproc)"
#
#build_step "install" "${LOG_DIR}/glibc" \
#    make install DESTDIR="${CROSS_PREFIX}/${TARGET}"

# 构建musl
step "=== 构建 musl ==="
mkdir -p "${WORK_DIR}/build-musl"
cd "${WORK_DIR}/build-musl" || error "无法进入构建目录"

build_step  "configure" "${LOG_DIR}/musl" \
    env CC="${CROSS_PREFIX}/bin/${TARGET}-gcc" \
    CXX="${CROSS_PREFIX}/bin/${TARGET}-g++" \
    CROSS_COMPILE="${CROSS_PREFIX}/bin/${TARGET}-" \
    "../musl-${MUSL_VER}/configure" \
    --build="$(dpkg-architecture -q DEB_BUILD_GNU_TYPE)" \
    --host="$TARGET" \
    --target="$TARGET" \
    --prefix="/usr" \
    --exec-prefix="/usr" \
    --with-headers="${CROSS_PREFIX}/${TARGET}/usr/include" \
    --with-binutils="${CROSS_PREFIX}/$TARGET/bin" \
    --disable-multilib \
    --without-selinux \
    libc_cv_forced_unwind=yes "${glibc_extra_args[@]}"

build_step "build" "${LOG_DIR}/musl" \
    make -j"$(nproc)"

build_step "install" "${LOG_DIR}/musl" \
    make install DESTDIR="${CROSS_PREFIX}/${TARGET}"



# 完整GCC构建（包含C/C++）
step "=== 完整GCC构建 ==="
mkdir -p "${WORK_DIR}/build-gcc-final"
cd "${WORK_DIR}/build-gcc-final" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR}/gcc" \
    "../gcc-${GCC_VER}/configure" \
    --target="$TARGET" \
    --prefix="$CROSS_PREFIX" \
    --disable-multilib \
    --disable-bootstrap \
    --enable-languages=c,c++,fortran,lto \
    --with-sysroot="${CROSS_PREFIX}/${TARGET}" \
    --with-build-sysroot="${CROSS_PREFIX}/${TARGET}" \
    --enable-threads=posix \
    --enable-shared \
    --disable-gprofng \
    --disable-libsanitizer

build_step "build" "${LOG_DIR}/gcc" \
    make -j"$(nproc)"

build_step "install" "${LOG_DIR}/gcc" \
    make install

# 完成输出
ok "=== 构建完成 ==="
echo -e "交叉编译器路径: ${GREEN}${CROSS_PREFIX}/bin${NC}"
echo -e "系统根目录: ${GREEN}${CROSS_PREFIX}/${TARGET}${NC}"
echo -e "日志目录: ${GREEN}${LOG_DIR}${NC}"

