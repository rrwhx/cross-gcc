#!/bin/bash

# Default values
ARCH=""
WORK_DIR=$(pwd)
SRC_DIR=""
TARGET_GCC_TOOLCHAIN=""
TARGET_SYSROOT=""

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --arch <arch>       Target architecture (required)"
    echo "  --src-dir <dir>     LLVM source directory (required)"
    echo "  --work-dir <dir>    Work directory for build and install (default: current directory)"
    echo "  --target-gcc-toolchain <dir> Optional target GCC toolchain directory"
    echo "  --target-sysroot <dir> Optional target sysroot directory"
    echo "  -h, --help          Show this help message"
    exit 0
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --arch) ARCH="$2"; shift ;;
        --src-dir) SRC_DIR="$2"; shift ;;
        --work-dir) WORK_DIR="$2"; shift ;;
        --target-gcc-toolchain) TARGET_GCC_TOOLCHAIN="$2"; shift ;;
        --target-sysroot) TARGET_SYSROOT="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$ARCH" ]; then
    echo "Error: --arch is required."
    usage
fi

if [ -z "$SRC_DIR" ]; then
    echo "Error: --src-dir is required."
    usage
fi

if [[ ( -n "$TARGET_GCC_TOOLCHAIN" && -z "$TARGET_SYSROOT" ) || ( -z "$TARGET_GCC_TOOLCHAIN" && -n "$TARGET_SYSROOT" ) ]]; then
    echo "Error: --target-gcc-toolchain and --target-sysroot must be used together."
    usage
fi

SRC_DIR=$(realpath "$SRC_DIR")
WORK_DIR=$(realpath "$WORK_DIR")

BUILD_DIR=${WORK_DIR}/build_llvm_${ARCH}
INSTALL_DIR=${WORK_DIR}/install_llvm_${ARCH}

CMAKE_EXTRA_ARGS=()
if [ -n "$TARGET_GCC_TOOLCHAIN" ] && [ -n "$TARGET_SYSROOT" ]; then
    TARGET_GCC_TOOLCHAIN=$(realpath "$TARGET_GCC_TOOLCHAIN")
    TARGET_SYSROOT=$(realpath "$TARGET_SYSROOT")
    CMAKE_EXTRA_ARGS+=(
        "-DBUILTINS_CMAKE_ARGS=-DCMAKE_SYSROOT=${TARGET_SYSROOT};-DCMAKE_CXX_FLAGS=--gcc-toolchain=${TARGET_GCC_TOOLCHAIN}"
        "-DRUNTIMES_CMAKE_ARGS=-DCMAKE_SYSROOT=${TARGET_SYSROOT};-DCMAKE_CXX_FLAGS=--gcc-toolchain=${TARGET_GCC_TOOLCHAIN}"
    )
fi

#rm -rf ${BUILD_DIR}
mkdir -p ${BUILD_DIR}
cd ${BUILD_DIR}
cmake \
  -G Ninja \
  "$SRC_DIR"/llvm \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_TARGETS_TO_BUILD="AArch64;LoongArch;RISCV;X86" \
  -DLLVM_ENABLE_PROJECTS="lld;clang;flang" \
  -DLLVM_ENABLE_RUNTIMES="flang-rt;compiler-rt" \
  -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
  "${CMAKE_EXTRA_ARGS[@]}" \
  -DLLVM_DEFAULT_TARGET_TRIPLE=${ARCH}-unknown-linux-gnu \
  -DLLVM_ENABLE_ZLIB=FORCE_ON

  #-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
ninja
ninja install

