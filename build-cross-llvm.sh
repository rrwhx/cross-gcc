#!/usr/bin/env bash

set -euo pipefail

# 加载公共库
source "$(dirname "$0")/lib.sh"

# ==============================================================================
# 辅助函数
# ==============================================================================

usage() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  --arch <arch>       目标架构 (必填)"
    echo "  --src-dir <dir>     LLVM 源码目录 (必填)"
    echo "  --work-dir <dir>    工作目录 (默认: 当前目录)"
    echo "  --target-gcc-toolchain <dir> 可选的目标 GCC 工具链目录"
    echo "  --target-sysroot <dir> 可选的目标 sysroot 目录"
    echo "  --build-dir <dir>   可选的构建目录"
    echo "  --install-dir <dir> 可选的安装目录"
    echo "  --log-dir <dir>     可选的日志目录"
    echo "  --link-jobs <n>     可选的并行链接作业数 (LLVM_PARALLEL_LINK_JOBS)"
    echo "  -h, --help          显示帮助信息"
    exit 0
}

# ==============================================================================
# 初始化与参数解析
# ==============================================================================

# 默认值
ARCH=""
WORK_DIR=$(pwd)
SRC_DIR=""
TARGET_GCC_TOOLCHAIN=""
TARGET_SYSROOT=""
BUILD_DIR=""
INSTALL_DIR=""
LOG_DIR=""
LINK_JOBS=""

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
            --link-jobs) LINK_JOBS="$2"; shift ;;
            -h|--help) usage ;;
            *) error "未知参数: $1"; ;;
        esac
        shift
    done
}

validate_args() {
    if [ -z "$ARCH" ]; then
        error "--arch 参数为必需，使用 --help 查看用法。"
    fi

    if [ -z "$SRC_DIR" ]; then
        error "--src-dir 参数为必需，使用 --help 查看用法。"
    fi

    if [[ ( -n "$TARGET_GCC_TOOLCHAIN" && -z "$TARGET_SYSROOT" ) || ( -z "$TARGET_GCC_TOOLCHAIN" && -n "$TARGET_SYSROOT" ) ]]; then
        error "--target-gcc-toolchain 和 --target-sysroot 必须同时使用。"
    fi

    if [ ! -d "$SRC_DIR" ]; then
        error "源码目录不存在: $SRC_DIR"
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

    info "目标架构      : ${ARCH}"
    info "源码目录      : ${SRC_DIR}"
    info "工作目录      : ${WORK_DIR}"
    info "构建目录      : ${BUILD_DIR}"
    info "安装目录      : ${INSTALL_DIR}"
    info "日志目录      : ${LOG_DIR}"

    if [ -n "$TARGET_GCC_TOOLCHAIN" ] && [ -n "$TARGET_SYSROOT" ]; then
        TARGET_GCC_TOOLCHAIN=$(realpath "$TARGET_GCC_TOOLCHAIN")
        TARGET_SYSROOT=$(realpath "$TARGET_SYSROOT")
        info "目标 GCC      : ${TARGET_GCC_TOOLCHAIN}"
        info "目标 Sysroot  : ${TARGET_SYSROOT}"
    fi
}

configure_llvm() {
    step "=== 配置 LLVM ==="

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

    if [ -n "$LINK_JOBS" ]; then
        CMAKE_EXTRA_ARGS+=("-DLLVM_PARALLEL_LINK_JOBS=${LINK_JOBS}")
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

      # NOTE: 构建 x86 目标时禁用 i386 运行时的备选方案：
      # 移除 -DLLVM_DEFAULT_TARGET_TRIPLE=${ARCH}-unknown-linux-gnu，改用 -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
      #-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
}

build_llvm() {
    step "=== 构建 LLVM ==="
    cd "${BUILD_DIR}"
    build_step "build" "${LOG_DIR}" ninja
}

install_llvm() {
    step "=== 安装 LLVM ==="
    cd "${BUILD_DIR}"
    build_step "install" "${LOG_DIR}" ninja install
    ok "LLVM 安装完成，路径: ${INSTALL_DIR}"
}

# ==============================================================================
# 主执行流程
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

