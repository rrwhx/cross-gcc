#!/usr/bin/env bash
# Cross-compile LLVM/Clang toolchain
set -euo pipefail

# 获取脚本的绝对路径（在脚本开始时就确定）
if command -v readlink >/dev/null 2>&1; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
fi
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

source "$SCRIPT_DIR/lib.sh"

setup_error_trap

# ==============================================================================
# 默认版本设置
# ==============================================================================

LLVM_VER="${LLVM_VER:-22.1.8}"

# ==============================================================================
# 参数解析
# ==============================================================================

ARCH=""
WORK_DIR=$(pwd)
SRC_DIR=""
DOWNLOAD_DIR=""
TARGET_GCC_TOOLCHAIN=""
TARGET_SYSROOT=""
BUILD_DIR=""
INSTALL_DIR=""
LOG_DIR=""
LINK_JOBS=""
THREADS=${THREADS}
MIRROR="mirrors.tuna.tsinghua.edu.cn"
CLEAN_BUILD=false
ARCHIVE_RESULT=false
GIT_UPDATE=false
FRESH_BUILD=false

usage() {
    cat <<EOF
用法: $(basename "$0") --arch ARCH [选项]

交叉编译 LLVM/Clang 工具链

  --arch              目标架构 (必填, 例如: aarch64, riscv64, x86_64, loongarch64)
  --llvm-ver          LLVM 版本 (默认: $LLVM_VER, 支持 'git' 使用最新开发版)
  --src-dir           LLVM 源码目录 (直接指定已解压的源码路径，跳过下载/解压)
  --work-dir          工作目录前缀 (默认: 当前目录)
  --download-dir      源码下载目录 (默认: WORK_DIR/downloads)
  --target-gcc-toolchain  目标 GCC 工具链目录 (与 --target-sysroot 配对使用)
  --target-sysroot    目标 sysroot 目录 (与 --target-gcc-toolchain 配对使用)
  --build-dir         构建目录 (默认: WORK_DIR/build-llvm-ARCH)
  --install-dir       安装目录 (默认: WORK_DIR/install-llvm-ARCH)
  --log-dir           日志目录 (默认: WORK_DIR/logs-llvm-ARCH)
  --link-jobs         并行链接作业数 (LLVM_PARALLEL_LINK_JOBS)
  -j,--threads        并行编译线程数 (默认: ${THREADS})
  --mirror            下载镜像源 (默认: $MIRROR)

构建后处理选项:
  --git-update        当版本为 'git' 且仓库已存在时，拉取最新代码
  --fresh             构建前删除已有的 build/log/install 目录
  --clean             构建完成后删除构建目录和日志目录
  --archive           构建完成后将工具链打包成 tar.xz 并删除原目录

  -h,--help           显示帮助

示例:
  $(basename "$0") --arch riscv64
  $(basename "$0") --arch riscv64 --llvm-ver git --git-update
  $(basename "$0") --arch aarch64 --src-dir ./llvm-project
  $(basename "$0") --arch aarch64 --target-gcc-toolchain ./cross-aarch64-linux-gnu --target-sysroot ./cross-aarch64-linux-gnu/aarch64-linux-gnu
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)                  ARCH="$2"; shift 2;;
        --llvm-ver)              LLVM_VER="$2"; shift 2;;
        --src-dir)               SRC_DIR="$2"; shift 2;;
        --work-dir)              WORK_DIR="$2"; shift 2;;
        --download-dir)          DOWNLOAD_DIR="$2"; shift 2;;
        --target-gcc-toolchain)  TARGET_GCC_TOOLCHAIN="$2"; shift 2;;
        --target-sysroot)        TARGET_SYSROOT="$2"; shift 2;;
        --build-dir)             BUILD_DIR="$2"; shift 2;;
        --install-dir)           INSTALL_DIR="$2"; shift 2;;
        --log-dir)               LOG_DIR="$2"; shift 2;;
        --link-jobs)             LINK_JOBS="$2"; shift 2;;
        -j|--threads)            THREADS="$2"; shift 2;;
        --mirror)                MIRROR="$2"; shift 2;;
        --git-update)            GIT_UPDATE=true; shift;;
        --fresh)                 FRESH_BUILD=true; shift;;
        --clean)                 CLEAN_BUILD=true; shift;;
        --archive)               ARCHIVE_RESULT=true; shift;;
        -h|--help)               usage;;
        *)                       error "未知选项: $1"; usage;;
    esac
done

# ==============================================================================
# 参数验证
# ==============================================================================

if [[ -z "$ARCH" ]]; then
    error "--arch 参数为必需。"
fi

if [[ ( -n "$TARGET_GCC_TOOLCHAIN" && -z "$TARGET_SYSROOT" ) || ( -z "$TARGET_GCC_TOOLCHAIN" && -n "$TARGET_SYSROOT" ) ]]; then
    error "--target-gcc-toolchain 和 --target-sysroot 必须同时使用。"
fi

# ==============================================================================
# 环境设置
# ==============================================================================

WORK_DIR=$(realpath "$WORK_DIR")
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${WORK_DIR}/downloads}"
mkdir -p "$DOWNLOAD_DIR"
DOWNLOAD_DIR=$(realpath "$DOWNLOAD_DIR")

BUILD_DIR="${BUILD_DIR:-${WORK_DIR}/build-llvm-${ARCH}}"
INSTALL_DIR="${INSTALL_DIR:-${WORK_DIR}/install-llvm-${ARCH}}"
LOG_DIR="${LOG_DIR:-${WORK_DIR}/logs-llvm-${ARCH}}"

mkdir -p "${BUILD_DIR}" "${INSTALL_DIR}" "${LOG_DIR}"

BUILD_DIR=$(realpath "$BUILD_DIR")
INSTALL_DIR=$(realpath "$INSTALL_DIR")
LOG_DIR=$(realpath "$LOG_DIR")

if [[ "$FRESH_BUILD" == true ]]; then
    step "=== 清理已有的 build/log/install 目录 ==="
    rm -rf "$BUILD_DIR" "$LOG_DIR" "$INSTALL_DIR"
    mkdir -p "$BUILD_DIR" "$LOG_DIR" "$INSTALL_DIR"
fi

# ==============================================================================
# 获取源码
# ==============================================================================

if [[ -n "$SRC_DIR" ]]; then
    SRC_DIR=$(realpath "$SRC_DIR")
    if [[ ! -d "$SRC_DIR" ]]; then
        error "源码目录不存在: $SRC_DIR"
    fi
else
    if [[ "$LLVM_VER" == "git" ]]; then
        SRC_DIR="$DOWNLOAD_DIR/llvm-project"
        git_clone "https://${MIRROR}/git/llvm-project.git" "$SRC_DIR" 1 "$GIT_UPDATE"
    else
        LLVM_TAR="llvm-project-${LLVM_VER}.src.tar.xz"
        LLVM_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VER}/${LLVM_TAR}"
        download "$LLVM_URL" "$DOWNLOAD_DIR/$LLVM_TAR"

        SRC_DIR="$DOWNLOAD_DIR/llvm-project-${LLVM_VER}.src"
        if [[ ! -d "$SRC_DIR" ]]; then
            step "=== 解压 LLVM 源码 ==="
            info "解压: $LLVM_TAR"
            tar -xf "$DOWNLOAD_DIR/$LLVM_TAR" -C "$DOWNLOAD_DIR"
        fi
    fi
fi

info "目标架构: ${ARCH}"
info "LLVM 版本: ${LLVM_VER}"
info "源码目录: ${SRC_DIR}"
info "工作目录: ${WORK_DIR}"
info "构建目录: ${BUILD_DIR}"
info "安装目录: ${INSTALL_DIR}"
info "日志目录: ${LOG_DIR}"
info "构建线程数: ${THREADS}"

if [[ -n "$TARGET_GCC_TOOLCHAIN" && -n "$TARGET_SYSROOT" ]]; then
    TARGET_GCC_TOOLCHAIN=$(realpath "$TARGET_GCC_TOOLCHAIN")
    TARGET_SYSROOT=$(realpath "$TARGET_SYSROOT")
    info "目标 GCC: ${TARGET_GCC_TOOLCHAIN}"
    info "目标 Sysroot: ${TARGET_SYSROOT}"
fi

# ==============================================================================
# 构建流程
# ==============================================================================

step "=== 配置 LLVM ==="
CMAKE_EXTRA_ARGS=()
if [[ -n "$TARGET_GCC_TOOLCHAIN" && -n "$TARGET_SYSROOT" ]]; then
    EXTRA_FLAGS=""
    if [[ "$ARCH" == "x86_64" ]]; then
        EXTRA_FLAGS=";-DCAN_TARGET_i386=OFF"
    fi

    CMAKE_EXTRA_ARGS+=(
        "-DBUILTINS_CMAKE_ARGS=-DCMAKE_SYSROOT=${TARGET_SYSROOT};-DCMAKE_CXX_FLAGS=--gcc-toolchain=${TARGET_GCC_TOOLCHAIN}${EXTRA_FLAGS}"
        "-DRUNTIMES_CMAKE_ARGS=-DCMAKE_SYSROOT=${TARGET_SYSROOT};-DCMAKE_CXX_FLAGS=--gcc-toolchain=${TARGET_GCC_TOOLCHAIN}${EXTRA_FLAGS}"
    )
fi

if [[ -n "$LINK_JOBS" ]]; then
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
    -DLLVM_DEFAULT_TARGET_TRIPLE="${ARCH}-unknown-linux-gnu" \
    -DLLVM_ENABLE_ZLIB=FORCE_ON
    # NOTE: 构建 x86 目标时禁用 i386 运行时的备选方案：
    # 移除 -DLLVM_DEFAULT_TARGET_TRIPLE，改用 -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON

step "=== 构建 LLVM ==="
cd "${BUILD_DIR}"
build_step "build" "${LOG_DIR}" ninja -j"${THREADS}"

step "=== 安装 LLVM ==="
cd "${BUILD_DIR}"
build_step "install" "${LOG_DIR}" ninja install

# ==============================================================================
# 完成输出
# ==============================================================================

ok "=== LLVM 构建完成 ==="
echo -e "安装目录: ${GREEN}${INSTALL_DIR}${NC}"
echo -e "日志目录: ${GREEN}${LOG_DIR}${NC}"

# 构建后处理
clean_build_dir "$BUILD_DIR" "$LOG_DIR" "$CLEAN_BUILD"
archive_toolchain "$INSTALL_DIR" "$ARCHIVE_RESULT"

