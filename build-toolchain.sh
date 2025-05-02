#!/bin/bash
set -eo pipefail

# 配置参数
export TARGET="riscv64-linux-gnu"
export CROSS_KERNEL_NAME=riscv
export CROSS_PREFIX="/opt/cross"${CROSS_KERNEL_NAME}
export WORK_DIR="$PWD/cross-toolchain"
export LOG_DIR="$WORK_DIR/logs"
export PATH="$CROSS_PREFIX/bin:$PATH"

# 版本配置
BINUTILS_VER="2.44"
GCC_VER="15.1.0"
GLIBC_VER="2.41"
LINUX_VER="6.14"

# 初始化目录
sudo mkdir -p "$CROSS_PREFIX"
sudo chown -R $(whoami) "$CROSS_PREFIX"
mkdir -p "$LOG_DIR"/{binutils,gcc,glibc}

# 安装依赖
#sudo apt-get update | tee -a "$LOG_DIR/deps.log"
sudo apt-get install -y \
    build-essential bison flex texinfo \
    python3 gawk git wget gzip bzip2 xz-utils \
    libgmp-dev libmpfr-dev libmpc-dev \
    gettext file rsync 2>&1 | tee -a "$LOG_DIR/deps.log"

# 下载源码
wget -nc -P "$WORK_DIR" \
    https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz \
    https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz \
    https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VER}.tar.xz \
    https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VER}.tar.xz

# 解压源码
for pkg in binutils-${BINUTILS_VER} gcc-${GCC_VER} glibc-${GLIBC_VER} linux-${LINUX_VER}; do
    tar xf "$WORK_DIR/${pkg}.tar.xz" -C "$WORK_DIR"
done

# 构建Binutils
echo "=== 构建Binutils ==="
mkdir -p "$WORK_DIR/build-binutils"
cd "$WORK_DIR/build-binutils"
"../binutils-${BINUTILS_VER}/configure" \
    --target=$TARGET \
    --prefix="$CROSS_PREFIX" \
    --disable-multilib \
    --enable-gold=yes \
    --enable-plugins 2>&1 | tee "$LOG_DIR/binutils/configure.log"

make -j$(nproc) 2>&1 | tee "$LOG_DIR/binutils/build.log"
make install 2>&1 | tee "$LOG_DIR/binutils/install.log"

# 初始GCC构建（仅支持C语言）
echo "=== 初始GCC构建 ==="
mkdir -p "$WORK_DIR/build-gcc-initial"
cd "$WORK_DIR/build-gcc-initial"
"../gcc-${GCC_VER}/configure" \
    --target=$TARGET \
    --prefix="$CROSS_PREFIX" \
    --disable-multilib \
    --enable-languages=c \
    --without-headers \
    --with-newlib \
    --disable-nls \
    --disable-shared \
    --disable-threads --disable-libatomic --disable-libgomp --disable-libquadmath --disable-libssp --disable-libvtv --disable-libstdcxx 2>&1 | tee "$LOG_DIR/gcc/initial-configure.log"

make -j$(nproc) 2>&1 | tee "$LOG_DIR/gcc/initial-build.log"
make install 2>&1 | tee "$LOG_DIR/gcc/initial-install.log"

# 准备Linux头文件
echo "=== 准备Linux头文件 ==="
cd "$WORK_DIR/linux-${LINUX_VER}"
make ARCH=${CROSS_KERNEL_NAME} INSTALL_HDR_PATH="$CROSS_PREFIX/$TARGET/usr" headers_install 2>&1 | tee "$LOG_DIR/glibc/linux-headers.log"

# 构建glibc
echo "=== 构建glibc ==="
mkdir -p "$WORK_DIR/build-glibc"
cd "$WORK_DIR/build-glibc"
CC="$CROSS_PREFIX/bin/$TARGET-gcc" \
CXX="$CROSS_PREFIX/bin/$TARGET-g++" \
"../glibc-${GLIBC_VER}/configure" \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    --host=$TARGET \
    --target=$TARGET \
    --prefix="/usr" \
    --exec-prefix="/usr" \
    --with-headers="$CROSS_PREFIX/$TARGET/usr/include" \
    --with-binutils=$CROSS_PREFIX/$TARGET/bin \
    --disable-multilib \
    --without-selinux \
    libc_cv_forced_unwind=yes 2>&1 | tee "$LOG_DIR/glibc/configure.log"

make -j$(nproc) 2>&1 | tee "$LOG_DIR/glibc/build.log"
make install DESTDIR="$CROSS_PREFIX/$TARGET"  2>&1 | tee "$LOG_DIR/glibc/install.log"

# 完整GCC构建（包含C/C++）
echo "=== 完整GCC构建 ==="
mkdir -p "$WORK_DIR/build-gcc-final"
cd "$WORK_DIR/build-gcc-final"
"../gcc-${GCC_VER}/configure" \
    --target=$TARGET \
    --prefix="$CROSS_PREFIX" \
    --disable-multilib \
    --disable-bootstrap \
    --enable-languages=c,c++,fortran,lto \
    --with-sysroot="$CROSS_PREFIX/$TARGET" \
    --with-build-sysroot="$CROSS_PREFIX/$TARGET" \
    --enable-threads=posix \
    --enable-shared 2>&1 | tee "$LOG_DIR/gcc/final-configure.log"

    #--with-sysroot="$CROSS_PREFIX/$TARGET" \
make -j$(nproc) 2>&1 | tee "$LOG_DIR/gcc/final-build.log"
make install 2>&1 | tee "$LOG_DIR/gcc/final-install.log"

echo "=== 构建完成 ==="
echo "交叉编译器路径: $CROSS_PREFIX/bin"
echo "系统根目录: $CROSS_PREFIX/$TARGET"
echo "日志目录: $LOG_DIR"

