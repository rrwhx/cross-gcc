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

# ---------------------------------------------------------------------------
# 库定义 (声明式)
# 格式: "名称|版本|下载URL模板|构建系统|额外参数(空格分隔)"
# URL 模板中 {VER} 会被替换为版本号
# ---------------------------------------------------------------------------
LIB_DEFS=(
    "zlib|1.3.2|https://github.com/madler/zlib/releases/download/v{VER}/zlib-{VER}.tar.gz|autotools|"
    "zlib-ng|2.3.3|https://github.com/zlib-ng/zlib-ng/archive/refs/tags/{VER}.tar.gz|cmake|-DZLIB_COMPAT=OFF -DZLIB_ENABLE_TESTS=OFF"
    "lz4|1.10.0|https://github.com/lz4/lz4/archive/refs/tags/v{VER}.tar.gz|make|"
    "zstd|1.5.7|https://github.com/facebook/zstd/releases/download/v{VER}/zstd-{VER}.tar.gz|make|"
    "snappy|1.2.2|https://github.com/google/snappy/archive/refs/tags/{VER}.tar.gz|cmake|-DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF"
)

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
TARGET=""
TOOLCHAIN_DIR=""
WORK_DIR=$(pwd)
SKIP_LIBS=""   # 逗号分隔的字符串，避免空数组在 set -u 下的兼容性问题
ONLY_LIBS=""
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
        --skip)          SKIP_LIBS="${SKIP_LIBS:+${SKIP_LIBS},}$2"; shift 2;;
        --only)          ONLY_LIBS="${ONLY_LIBS:+${ONLY_LIBS},}$2"; shift 2;;
        -h|--help)       usage;;
        *)               error "未知选项: $1"; usage;;
    esac
done

if [[ -z "$TARGET" || -z "$TOOLCHAIN_DIR" ]]; then
    error "--target 和 --toolchain-dir 参数为必需。"
fi

# ---------------------------------------------------------------------------
# 目录与工具链设置
# ---------------------------------------------------------------------------
TOOLCHAIN_DIR=$(realpath "$TOOLCHAIN_DIR")
WORK_DIR=$(realpath "$WORK_DIR")
DOWNLOAD_DIR="${WORK_DIR}/downloads"
SRC_DIR="${WORK_DIR}/src-$TARGET"
BUILD_DIR="${WORK_DIR}/build-libs-$TARGET"
LOG_DIR="${WORK_DIR}/logs-libs-$TARGET"
TARGET_SYSROOT="$TOOLCHAIN_DIR/$TARGET"

if [[ ! -d "$TARGET_SYSROOT" ]]; then
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

if ! command -v "$CC" &>/dev/null; then
    error "无法在 PATH 中找到交叉编译器 $CC，请检查 toolchain-dir 结构"
fi

info "工具链目录: $TOOLCHAIN_DIR"
info "目标 Sysroot: $TARGET_SYSROOT"
info "交叉编译器: $CC"

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

# 判断某个库是否应该编译
should_build() {
    local lib="$1"

    # 如果指定了 --only，则仅编译列表中的库
    if [[ -n "$ONLY_LIBS" ]]; then
        [[ ",$ONLY_LIBS," == *",$lib,"* ]] || return 1
    fi

    # 如果在 --skip 列表中，则跳过
    if [[ -n "$SKIP_LIBS" ]]; then
        [[ ",$SKIP_LIBS," != *",$lib,"* ]] || return 1
    fi

    return 0
}

# 从库定义字符串中解析各字段
parse_lib_def() {
    local def="$1"
    LIB_NAME="${def%%|*}";  def="${def#*|}"
    LIB_VER="${def%%|*}";   def="${def#*|}"
    LIB_URL="${def%%|*}";   def="${def#*|}"
    LIB_BUILD="${def%%|*}"; def="${def#*|}"
    LIB_EXTRA="$def"

    # 替换 URL 模板中的版本占位符
    LIB_URL="${LIB_URL//\{VER\}/$LIB_VER}"
}

# 编译并安装单个库
build_package() {
    local lib_name="$1"
    local lib_ver="$2"
    local build_sys="$3"
    local extra_string="$4"

    # 将空格分隔的额外参数字符串转为数组
    local extra_args=()
    if [[ -n "$extra_string" ]]; then
        read -ra extra_args <<< "$extra_string"
    fi

    step "=== 编译并安装 ${lib_name} ==="
    local build_pkg_dir="$BUILD_DIR/${lib_name}"
    rm -rf "$build_pkg_dir" && mkdir -p "$build_pkg_dir"

    local src_pkg_dir="$SRC_DIR/${lib_name}-${lib_ver}"

    case "$build_sys" in
        autotools)
            cp -a "$src_pkg_dir/." "$build_pkg_dir/"
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
            cp -a "$src_pkg_dir/." "$build_pkg_dir/"
            (
                cd "$build_pkg_dir"
                build_step "${lib_name}_build" "$LOG_DIR" \
                    make -j"${THREADS}" CC="$CC" CXX="$CXX" AR="$AR" PREFIX=/usr "${extra_args[@]}"
                build_step "${lib_name}_install" "$LOG_DIR" \
                    make install DESTDIR="${TARGET_SYSROOT}" PREFIX=/usr
            )
            ;;
        cmake)
            local target_cpu="${TARGET%%-*}"
            local cmake_args=(
                -DCMAKE_SYSTEM_NAME=Linux
                -DCMAKE_SYSTEM_PROCESSOR="$target_cpu"
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

            # out-of-tree 构建，无需拷贝源码
            mkdir -p "$build_pkg_dir"
            (
                cd "$build_pkg_dir"
                build_step "${lib_name}_configure" "$LOG_DIR" \
                    cmake "$src_pkg_dir" "${cmake_args[@]}"
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

    ok "${lib_name} ${lib_ver} 编译安装完成"
}

# ---------------------------------------------------------------------------
# 阶段 1: 下载源码
# ---------------------------------------------------------------------------
step "=== 下载依赖库源码 ==="
for def in "${LIB_DEFS[@]}"; do
    parse_lib_def "$def"
    if should_build "$LIB_NAME"; then
        download "$LIB_URL" "$DOWNLOAD_DIR/${LIB_NAME}-${LIB_VER}.tar.gz"
    fi
done

# ---------------------------------------------------------------------------
# 阶段 2: 解压源码
# ---------------------------------------------------------------------------
step "=== 解压源码 ==="
for def in "${LIB_DEFS[@]}"; do
    parse_lib_def "$def"
    if should_build "$LIB_NAME" && [[ ! -d "$SRC_DIR/${LIB_NAME}-${LIB_VER}" ]]; then
        info "解压: ${LIB_NAME}-${LIB_VER}.tar.gz"
        tar -xf "$DOWNLOAD_DIR/${LIB_NAME}-${LIB_VER}.tar.gz" -C "$SRC_DIR"
    fi
done

# ---------------------------------------------------------------------------
# 阶段 3: 编译并安装
# ---------------------------------------------------------------------------
for def in "${LIB_DEFS[@]}"; do
    parse_lib_def "$def"
    if should_build "$LIB_NAME"; then
        build_package "$LIB_NAME" "$LIB_VER" "$LIB_BUILD" "$LIB_EXTRA"
    else
        info "跳过编译 ${LIB_NAME}"
    fi
done

ok "请求的依赖库已经成功交叉编译并安装到 Sysroot 中！"
echo -e "你可以通过目录 \033[0;32m${TARGET_SYSROOT}/usr/lib\033[0m 查看生成的库文件。"