#!/usr/bin/env bash
set -euo pipefail

# 检测系统包管理器
if [[ "$(uname -s)" == Darwin ]]; then
    command -v brew >/dev/null 2>&1 || {
        echo "错误：请先安装 Homebrew (https://brew.sh/)" >&2
        exit 1
    }
    echo "检测到 macOS / Homebrew"
    brew install \
        bash gcc make gnu-sed gawk grep coreutils findutils \
        bison flex texinfo rsync git wget curl xz \
        python cmake ninja pkgconf autoconf automake libtool

elif command -v apt-get &> /dev/null; then
    echo "检测到 apt 包管理器"
    sudo apt-get install -y \
        build-essential bison flex texinfo cmake \
        python3 gawk git wget curl gzip bzip2 xz-utils \
        libgmp-dev libmpfr-dev libmpc-dev libssl-dev libelf-dev zlib1g-dev \
        gettext file rsync cpio bc

elif command -v dnf &> /dev/null || command -v yum &> /dev/null; then
    echo "检测到 yum/dnf 包管理器"
    PKG_MANAGER=$(command -v dnf || command -v yum)
    sudo "$PKG_MANAGER" groupinstall -y "Development Tools"
    sudo "$PKG_MANAGER" install -y \
        bison flex texinfo cmake python3 gawk \
        git wget curl gzip bzip2 xz \
        gmp-devel mpfr-devel libmpc-devel openssl-devel elfutils-libelf-devel zlib-devel \
        gettext file rsync cpio bc

elif command -v pacman &> /dev/null; then
    echo "检测到 pacman 包管理器"
    sudo pacman -S --needed --noconfirm \
        base-devel bison flex texinfo cmake python \
        gawk git wget curl gzip bzip2 xz \
        gmp mpfr libmpc openssl libelf zlib \
        gettext file rsync cpio bc

else
    echo "错误：未检测到支持的包管理器"
    exit 1
fi

echo "软件包安装成功"

