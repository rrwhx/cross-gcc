#!/usr/bin/env bash

# brew install bash gnu-sed gawk make bison rsync grep coreutils gcc

ulimit -n 16384
DARWIN_VERSION=$(uname -r | cut -d. -f1)
env \
    CXX=aarch64-apple-darwin${DARWIN_VERSION}-g++-15 \
    CC=aarch64-apple-darwin${DARWIN_VERSION}-gcc-15 \
    MAKE=/opt/homebrew/opt/make/libexec/gnubin/make \
    PATH="/opt/homebrew/bin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/grep/libexec/gnubin:/opt/homebrew/opt/findutils/libexec/gnubin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/gawk/libexec/gnubin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:$PATH" \
    "$@"

    # /opt/homebrew/bin/bash ./build_all.sh -a aarch64,loongarch64,riscv32,riscv64 -l glibc,musl --clean --archive
    # /opt/homebrew/bin/bash ./build-toolchain-generic.sh --arch riscv64 --libc musl --clean --archive
