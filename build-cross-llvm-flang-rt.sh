#!/usr/bin/env bash

# Default values
ARCH=""
WORK_DIR=$(pwd)
SRC_DIR=""
LLVM_DIR=""
TARGET_GCC_TOOLCHAIN=""
TARGET_SYSROOT=""

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --arch <arch>       Target architecture (required)"
    echo "  --src-dir <dir>     LLVM source directory (required)"
    echo "  --llvm-dir <dir>    LLVM host compilation toolchain/install directory (required)"
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
        --llvm-dir) LLVM_DIR="$2"; shift ;;
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

if [ -z "$LLVM_DIR" ]; then
    echo "Error: --llvm-dir is required."
    usage
fi

if [[ ( -n "$TARGET_GCC_TOOLCHAIN" && -z "$TARGET_SYSROOT" ) || ( -z "$TARGET_GCC_TOOLCHAIN" && -n "$TARGET_SYSROOT" ) ]]; then
    echo "Error: --target-gcc-toolchain and --target-sysroot must be used together."
    usage
fi

SRC_DIR=$(realpath "$SRC_DIR")
WORK_DIR=$(realpath "$WORK_DIR")
LLVM_DIR=$(realpath "$LLVM_DIR")

BUILD_DIR=${WORK_DIR}/build_llvm_flang_rt_${ARCH}
INSTALL_DIR=${LLVM_DIR}

CROSS_FLAGS=""
if [ -n "$TARGET_GCC_TOOLCHAIN" ] && [ -n "$TARGET_SYSROOT" ]; then
    TARGET_GCC_TOOLCHAIN=$(realpath "$TARGET_GCC_TOOLCHAIN")
    TARGET_SYSROOT=$(realpath "$TARGET_SYSROOT")
    CROSS_FLAGS="--sysroot=${TARGET_SYSROOT} --gcc-toolchain=${TARGET_GCC_TOOLCHAIN}"
fi

cd "$WORK_DIR"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"
 CC="${LLVM_DIR}/bin/clang" \
CXX="${LLVM_DIR}/bin/clang++" \
 FC="${LLVM_DIR}/bin/flang" \
cmake \
  -G Ninja \
  "$SRC_DIR"/runtimes \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DLLVM_ENABLE_RUNTIMES="flang-rt" \
  -DLLVM_DEFAULT_TARGET_TRIPLE=${ARCH}-unknown-linux-gnu \
  -DCMAKE_ASM_COMPILER_TARGET="${ARCH}-unknown-linux-gnu" \
  -DCMAKE_C_COMPILER_TARGET="${ARCH}-unknown-linux-gnu" \
  -DCMAKE_CXX_COMPILER_TARGET="${ARCH}-unknown-linux-gnu" \
  -DCMAKE_Fortran_COMPILER_TARGET="${ARCH}-unknown-linux-gnu" \
  -DCMAKE_C_FLAGS="${CROSS_FLAGS}" \
  -DCMAKE_CXX_FLAGS="${CROSS_FLAGS}" \
  -DCMAKE_Fortran_FLAGS="${CROSS_FLAGS}"

ninja
ninja install
