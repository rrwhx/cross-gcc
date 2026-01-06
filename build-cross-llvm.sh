#!/bin/bash

# Default values
ARCH="riscv64"
ROOTDIR=$(pwd)
SRC_DIR="../../llvm-project-llvmorg-21.1.8"

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --arch <arch>       Target architecture (default: riscv64)"
    echo "  --src_dir <dir>     LLVM source directory (default: ../../llvm-project-llvmorg-21.1.8)"
    echo "  --root_dir <dir>    Root directory for build and install (default: current directory)"
    echo "  -h, --help          Show this help message"
    exit 0
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --arch) ARCH="$2"; shift ;;
        --src_dir) SRC_DIR="$2"; shift ;;
        --root_dir) ROOTDIR="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

BUILD_DIR=${ROOTDIR}/build_llvm_${ARCH}
INSTALLDIR=${ROOTDIR}/install_llvm_${ARCH}

#rm -rf ${BUILD_DIR}
mkdir -p ${BUILD_DIR}
cd ${BUILD_DIR}
cmake \
  -G Ninja \
  "$SRC_DIR"/llvm \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$INSTALLDIR \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_TARGETS_TO_BUILD="AArch64;LoongArch;RISCV;X86" \
  -DLLVM_ENABLE_PROJECTS="lld;clang;flang" \
  -DLLVM_ENABLE_RUNTIMES="flang-rt;compiler-rt" \
  -DLLVM_DEFAULT_TARGET_TRIPLE=${ARCH}-unknown-linux-gnu \
  -DLLVM_ENABLE_ZLIB=FORCE_ON

  #-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
ninja
ninja install

