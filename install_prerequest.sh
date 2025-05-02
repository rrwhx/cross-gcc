#!/bin/bash
set -e
#!/bin/bash

# 检测系统包管理器
if command -v apt-get &> /dev/null; then
    echo "检测到 apt 包管理器"
    sudo apt-get install -y \
        build-essential bison flex texinfo \
        python3 gawk git wget gzip bzip2 xz-utils \
        libgmp-dev libmpfr-dev libmpc-dev \
        gettext file rsync

elif command -v dnf &> /dev/null || command -v yum &> /dev/null; then
    echo "检测到 yum/dnf 包管理器"
    PKG_MANAGER=$(command -v dnf || command -v yum)
    sudo $PKG_MANAGER groupinstall -y "Development Tools"
    sudo $PKG_MANAGER install -y \
        bison flex texinfo python3 gawk \
        git wget gzip bzip2 xz \
        gmp-devel mpfr-devel libmpc-devel \
        gettext file rsync

elif command -v pacman &> /dev/null; then
    echo "检测到 pacman 包管理器"
    sudo pacman -S --needed --noconfirm \
        base-devel bison flex texinfo python \
        gawk git wget gzip bzip2 xz \
        gmp mpfr libmpc \
        gettext file rsync

else
    echo "错误：未检测到支持的包管理器"
    exit 1
fi

# 检查安装结果
if [ $? -eq 0 ]; then
    echo "软件包安装成功"
else
    echo "软件包安装失败"
    exit 1
fi

