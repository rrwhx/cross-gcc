#!/usr/bin/env bash
set -euo pipefail

if command -v readlink >/dev/null 2>&1; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
fi
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

source "$SCRIPT_DIR/lib.sh"

setup_error_trap

ZLIB_VER="1.3.2"
LZ4_VER="1.10.0"
ZSTD_VER="1.5.7"
SNAPPY_VER="1.2.2"

TARGET=""
TOOLCHAIN_DIR=""
WORK_DIR=$(pwd)
SKIP_LIBS=()
ONLY_LIBS=()
THREADS=$(nproc 2>/dev/null || echo 4)

usage() {
    cat <<EOF
用法: $(basename "$0") --target TARGET --toolchain-dir DIR [选项]
  --target         目标架构三元组 (例如: riscv64-linux-gnu)
  --toolchain-dir  工具链所在的根目录 (例如: ./cross-riscv64-linux-gnu)
  --work-dir       工作目录前缀 (默认: 当前目录)
  --skip           跳过指定的库，多次使用指定多个 (例如: --skip lz4 --skip snappy)
  --only           仅编译指定的库，多次使用指定多个 (例如: --only zlib --only zstd)
  -h,--help        显示帮助
示例:
  $(basename "$0") --target riscv64-linux-gnu --toolchain-dir ./cross-riscv64-linux-gnu
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)        TARGET="$2"; shift 2;;
        --toolchain-dir) TOOLCHAIN_DIR="$2"; shift 2;;
        --work-dir)      WORK_DIR="$2"; shift 2;;
        --skip)          SKIP_LIBS+=("$2"); shift 2;;
        --only)          ONLY_LIBS+=("$2"); shift 2;;
        -h|--help)       usage;;
        *)               error "未知选项: $1"; usage;;
    esac
done

if [[ -z "$TARGET" || -z "$TOOLCHAIN_DIR" ]]; then
    error "--target 和 --toolchain-dir 参数为必需。"
fi

TOOLCHAIN_DIR=$(realpath "$TOOLCHAIN_DIR")
WORK_DIR=$(realpath "$WORK_DIR")
DOWNLOAD_DIR="${WORK_DIR}/downloads"
SRC_DIR="${WORK_DIR}/src-$TARGET"
BUILD_DIR="${WORK_DIR}/build-libs-$TARGET"
LOG_DIR="${WORK_DIR}/logs-libs-$TARGET"

TARGET_SYSROOT="$TOOLCHAIN_DIR/$TARGET"

if [ ! -d "$TARGET_SYSROOT" ]; then
    error "未找到目标 sysroot 目录: $TARGET_SYSROOT \n请检查 --target 和 --toolchain-dir 参数是否正确匹配。"
fi

mkdir -p "$DOWNLOAD_DIR" "$SRC_DIR" "$BUILD_DIR" "$LOG_DIR"

export PATH="$TOOLCHAIN_DIR/bin:$PATH"
export CC="${TARGET}-gcc"
export CXX="${TARGET}-g++"
export AR="${TARGET}-ar"
export AS="${TARGET}-as"
export LD="${TARGET}-ld"
export RANLIB="${TARGET}-ranlib"
export STRIP="${TARGET}-strip"
export NM="${TARGET}-nm"
export OBJCOPY="${TARGET}-objcopy"
export OBJDUMP="${TARGET}-objdump"

if ! command -v "$CC" &> /dev/null; then
    error "无法在 PATH 中找到交叉编译器 $CC，请检查 toolchain-dir 结构"
fi

info "工具链目录: $TOOLCHAIN_DIR"
info "目标 Sysroot: $TARGET_SYSROOT"
info "交叉编译器: $CC"

should_build() {
    local lib="$1"
    if [ ${#ONLY_LIBS[@]} -gt 0 ]; then
        local in_only=false
        for only in "${ONLY_LIBS[@]}"; do
            if [ "$only" == "$lib" ]; then
                in_only=true
                break
            fi
        done
        if [ "$in_only" == false ]; then return 1; fi
    fi

    for skip in "${SKIP_LIBS[@]}"; do
        if [ "$skip" == "$lib" ]; then return 1; fi
    done
    return 0
}

step "=== 下载依赖库源码 ==="
if should_build "zlib"; then download "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" "$DOWNLOAD_DIR/zlib-${ZLIB_VER}.tar.gz"; fi
if should_build "lz4"; then download "https://github.com/lz4/lz4/archive/refs/tags/v${LZ4_VER}.tar.gz" "$DOWNLOAD_DIR/lz4-${LZ4_VER}.tar.gz"; fi
if should_build "zstd"; then download "https://github.com/facebook/zstd/releases/download/v${ZSTD_VER}/zstd-${ZSTD_VER}.tar.gz" "$DOWNLOAD_DIR/zstd-${ZSTD_VER}.tar.gz"; fi
if should_build "snappy"; then download "https://github.com/google/snappy/archive/refs/tags/${SNAPPY_VER}.tar.gz" "$DOWNLOAD_DIR/snappy-${SNAPPY_VER}.tar.gz"; fi

step "=== 解压源码 ==="
if should_build "zlib" && [ ! -d "$SRC_DIR/zlib-${ZLIB_VER}" ]; then
    info "解压: zlib-${ZLIB_VER}.tar.gz"
    tar -xf "$DOWNLOAD_DIR/zlib-${ZLIB_VER}.tar.gz" -C "$SRC_DIR"
fi
if should_build "lz4" && [ ! -d "$SRC_DIR/lz4-${LZ4_VER}" ]; then
    info "解压: lz4-${LZ4_VER}.tar.gz"
    tar -xf "$DOWNLOAD_DIR/lz4-${LZ4_VER}.tar.gz" -C "$SRC_DIR"
fi
if should_build "zstd" && [ ! -d "$SRC_DIR/zstd-${ZSTD_VER}" ]; then
    info "解压: zstd-${ZSTD_VER}.tar.gz"
    tar -xf "$DOWNLOAD_DIR/zstd-${ZSTD_VER}.tar.gz" -C "$SRC_DIR"
fi
if should_build "snappy" && [ ! -d "$SRC_DIR/snappy-${SNAPPY_VER}" ]; then
    info "解压: snappy-${SNAPPY_VER}.tar.gz"
    tar -xf "$DOWNLOAD_DIR/snappy-${SNAPPY_VER}.tar.gz" -C "$SRC_DIR"
fi

build_package() {
    local lib_name=$1
    local lib_ver=$2
    local build_sys=$3
    shift 3
    local extra_args=("$@")

    step "=== 编译并安装 ${lib_name} ==="
    local build_pkg_dir="$BUILD_DIR/${lib_name}"
    rm -rf "$build_pkg_dir" && mkdir -p "$build_pkg_dir"

    cp -a "$SRC_DIR/${lib_name}-${lib_ver}/." "$build_pkg_dir/"

    case "$build_sys" in
        autotools)
            (
                cd "$build_pkg_dir"
                build_step "${lib_name}_configure" "$LOG_DIR" \
                    ./configure --host="${TARGET}" --prefix=/usr "${extra_args[@]}"
                build_step "${lib_name}_build" "$LOG_DIR" \
                    make -j"${THREADS}"
                build_step "${lib_name}_install" "$LOG_DIR" \
                    make install DESTDIR="${TARGET_SYSROOT}"
            )
            ;;
        make)
            (
                cd "$build_pkg_dir"
                build_step "${lib_name}_build" "$LOG_DIR" \
                    make -j"${THREADS}" CC="$CC" CXX="$CXX" AR="$AR" PREFIX=/usr "${extra_args[@]}"
                build_step "${lib_name}_install" "$LOG_DIR" \
                    make install DESTDIR="${TARGET_SYSROOT}" PREFIX=/usr
            )
            ;;
        cmake)
            local cmake_common_args=(
                -DCMAKE_SYSTEM_NAME=Linux
                -DCMAKE_SYSROOT="$TARGET_SYSROOT"
                -DCMAKE_FIND_ROOT_PATH="$TARGET_SYSROOT"
                -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
                -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
                -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
                -DCMAKE_C_COMPILER="$CC"
                -DCMAKE_CXX_COMPILER="$CXX"
                -DCMAKE_INSTALL_PREFIX=/usr
                -DCMAKE_POLICY_VERSION_MINIMUM=3.5
                "${extra_args[@]}"
            )

            mkdir -p "${build_pkg_dir}/build"
            (
                cd "${build_pkg_dir}/build"
                build_step "${lib_name}_configure" "$LOG_DIR" \
                    cmake .. "${cmake_common_args[@]}"
                build_step "${lib_name}_build" "$LOG_DIR" \
                    make -j"${THREADS}"
                build_step "${lib_name}_install" "$LOG_DIR" \
                    make install DESTDIR="${TARGET_SYSROOT}"
            )
            ;;
        *)
            error "未知的构建框架: $build_sys (库: $lib_name)"
            ;;
    esac
}

if should_build "zlib"; then build_package zlib "${ZLIB_VER}" autotools; else info "跳过编译 zlib"; fi
if should_build "lz4"; then build_package lz4 "${LZ4_VER}" make; else info "跳过编译 lz4"; fi
if should_build "zstd"; then build_package zstd "${ZSTD_VER}" make; else info "跳过编译 zstd"; fi
if should_build "snappy"; then
    build_package snappy "${SNAPPY_VER}" cmake -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF
else
    info "跳过编译 snappy"
fi

ok "请求的依赖库已经成功交叉编译并安装到 Sysroot 中！"
echo -e "你可以通过目录 \033[0;32m${TARGET_SYSROOT}/usr/lib\033[0m 查看生成的库文件。"