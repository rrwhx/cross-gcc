#!/bin/bash
set -e

# 配置参数
export CROSS_PREFIX="${CROSS_PREFIX:-/opt/cross}"
export TARGET="loongarch64-linux-gnu"
export PATH="$CROSS_PREFIX/bin:$PATH"

BINUTILS_VER="2.44"
GCC_VER="15.1.0"
WORK_DIR="$PWD/cross-build"

# 安装依赖
# sudo apt update
sudo apt install -y build-essential bison flex texinfo \
    libgmp-dev libmpfr-dev libmpc-dev git wget

# 创建目录
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 下载源码
wget -nc https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz
wget -nc https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz
tar xf binutils-${BINUTILS_VER}.tar.xz
tar xf gcc-${GCC_VER}.tar.xz

# 构建Binutils
mkdir -p build-binutils && cd build-binutils
../binutils-${BINUTILS_VER}/configure \
    --target=$TARGET \
    --prefix=$CROSS_PREFIX \
    --disable-multilib \
    --enable-gold=yes
make -j$(nproc)
sudo make install
cd ..

# 构建GCC
mkdir -p build-gcc && cd build-gcc
../gcc-${GCC_VER}/configure \
    --target=$TARGET \
    --prefix=$CROSS_PREFIX \
    --disable-multilib \
    --enable-languages=c,c++ \
    --with-gnu-as \
    --with-gnu-ld
make -j$(nproc) all-gcc
sudo make install-gcc
cd ..

echo "安装完成！将以下内容添加到~/.bashrc："
echo "export PATH=\"$CROSS_PREFIX/bin:\$PATH\""

