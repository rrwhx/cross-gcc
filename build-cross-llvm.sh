#!/bin/bash

set -euo pipefail

# source common library
source "$(dirname "$0")/lib.sh"

# ==============================================================================
# Helper functions
# ==============================================================================

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --arch <arch>       Target architecture (required)"
    echo "  --src-dir <dir>     LLVM source directory (required)"
    echo "  --work-dir <dir>    Work directory for build and install (default: current directory)"
    echo "  --target-gcc-toolchain <dir> Optional target GCC toolchain directory"
    echo "  --target-sysroot <dir> Optional target sysroot directory"
    echo "  --build-dir <dir>   Optional build directory"
    echo "  --install-dir <dir> Optional install directory"
    echo "  --log-dir <dir>     Optional log directory"
    echo "  -h, --help          Show this help message"
    exit 0
}

# ==============================================================================
# Initialization and parameter parsing
# ==============================================================================

# Default values
ARCH=""
WORK_DIR=$(pwd)
SRC_DIR=""
TARGET_GCC_TOOLCHAIN=""
TARGET_SYSROOT=""
BUILD_DIR=""
INSTALL_DIR=""
LOG_DIR=""

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --arch) ARCH="$2"; shift ;;
            --src-dir) SRC_DIR="$2"; shift ;;
            --work-dir) WORK_DIR="$2"; shift ;;
            --target-gcc-toolchain) TARGET_GCC_TOOLCHAIN="$2"; shift ;;
            --target-sysroot) TARGET_SYSROOT="$2"; shift ;;
            --build-dir) BUILD_DIR="$2"; shift ;;
            --install-dir) INSTALL_DIR="$2"; shift ;;
            --log-dir) LOG_DIR="$2"; shift ;;
            -h|--help) usage ;;
            *) error "Unknown parameter passed: $1"; ;;
        esac
        shift
    done
}

validate_args() {
    if [ -z "$ARCH" ]; then
        error "--arch is required. Use --help for usage."
    fi

    if [ -z "$SRC_DIR" ]; then
        error "--src-dir is required. Use --help for usage."
    fi

    if [[ ( -n "$TARGET_GCC_TOOLCHAIN" && -z "$TARGET_SYSROOT" ) || ( -z "$TARGET_GCC_TOOLCHAIN" && -n "$TARGET_SYSROOT" ) ]]; then
        error "--target-gcc-toolchain and --target-sysroot must be used together."
    fi

    if [ ! -d "$SRC_DIR" ]; then
        error "Source directory not found: $SRC_DIR"
    fi
}

setup_environment() {
    SRC_DIR=$(realpath "$SRC_DIR")
    WORK_DIR=$(realpath "$WORK_DIR")

    BUILD_DIR="${BUILD_DIR:-${WORK_DIR}/build_llvm_${ARCH}}"
    INSTALL_DIR="${INSTALL_DIR:-${WORK_DIR}/install_llvm_${ARCH}}"
    LOG_DIR="${LOG_DIR:-${WORK_DIR}/logs_llvm_${ARCH}}"

    mkdir -p "${BUILD_DIR}" "${INSTALL_DIR}" "${LOG_DIR}"

    BUILD_DIR=$(realpath "$BUILD_DIR")
    INSTALL_DIR=$(realpath "$INSTALL_DIR")
    LOG_DIR=$(realpath "$LOG_DIR")

    info "Architecture  : ${ARCH}"
    info "Source Dir    : ${SRC_DIR}"
    info "Working Dir   : ${WORK_DIR}"
    info "Build Dir     : ${BUILD_DIR}"
    info "Install Dir   : ${INSTALL_DIR}"
    info "Log Dir       : ${LOG_DIR}"

    if [ -n "$TARGET_GCC_TOOLCHAIN" ] && [ -n "$TARGET_SYSROOT" ]; then
        TARGET_GCC_TOOLCHAIN=$(realpath "$TARGET_GCC_TOOLCHAIN")
        TARGET_SYSROOT=$(realpath "$TARGET_SYSROOT")
        info "Target GCC    : ${TARGET_GCC_TOOLCHAIN}"
        info "Target Sysroot: ${TARGET_SYSROOT}"
    fi
}

configure_llvm() {
    step "=== Configuring LLVM ==="

    local CMAKE_EXTRA_ARGS=()
    if [ -n "$TARGET_GCC_TOOLCHAIN" ] && [ -n "$TARGET_SYSROOT" ]; then
        local EXTRA_FLAGS=""
        if [ "$ARCH" = "x86_64" ]; then
            EXTRA_FLAGS=";-DCAN_TARGET_i386=OFF"
        fi

        CMAKE_EXTRA_ARGS+=(
            "-DBUILTINS_CMAKE_ARGS=-DCMAKE_SYSROOT=${TARGET_SYSROOT};-DCMAKE_CXX_FLAGS=--gcc-toolchain=${TARGET_GCC_TOOLCHAIN}${EXTRA_FLAGS}"
            "-DRUNTIMES_CMAKE_ARGS=-DCMAKE_SYSROOT=${TARGET_SYSROOT};-DCMAKE_CXX_FLAGS=--gcc-toolchain=${TARGET_GCC_TOOLCHAIN}${EXTRA_FLAGS}"
        )
    fi

    cd "${BUILD_DIR}"

    build_step "configure" "${LOG_DIR}" \
      cmake \
      -G Ninja \
      "${SRC_DIR}/llvm" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_TARGETS_TO_BUILD="AArch64;LoongArch;RISCV;X86" \
      -DLLVM_ENABLE_PROJECTS="lld;clang;flang" \
      -DLLVM_ENABLE_RUNTIMES="flang-rt;compiler-rt" \
      -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
      "${CMAKE_EXTRA_ARGS[@]}" \
      -DLLVM_DEFAULT_TARGET_TRIPLE=${ARCH}-unknown-linux-gnu \
      -DLLVM_ENABLE_ZLIB=FORCE_ON

      # disable i386 runtime when build x86 target
      # remove -DLLVM_DEFAULT_TARGET_TRIPLE=${ARCH}-unknown-linux-gnu, add -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
      #-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
}

build_llvm() {
    step "=== Building LLVM ==="
    cd "${BUILD_DIR}"
    build_step "build" "${LOG_DIR}" ninja
}

install_llvm() {
    step "=== Installing LLVM ==="
    cd "${BUILD_DIR}"
    build_step "install" "${LOG_DIR}" ninja install
    ok "LLVM installation completed at ${INSTALL_DIR}"
}

# ==============================================================================
# Main execution
# ==============================================================================

main() {
    parse_args "$@"
    validate_args
    setup_environment
    configure_llvm
    build_llvm
    install_llvm
}

main "$@"

