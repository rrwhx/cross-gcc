#!/usr/bin/env bash
# Native LLVM/Clang toolchain build script
# 构建可在当前 host 上直接使用的本地 LLVM/Clang 工具链（clang + lld + flang），
# 面向 host（native），使用 host 自带的 libc/libstdc++，不使用交叉 sysroot。

set -euo pipefail

# 获取脚本的绝对路径（在脚本开始时就确定）
if command -v readlink >/dev/null 2>&1; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    # macOS 兼容性处理
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

WORK_DIR=$(pwd)
SRC_DIR=""
DOWNLOAD_DIR=""
BUILD_DIR=""
INSTALL_DIR=""
LOG_DIR=""
LINK_JOBS=""
# MIRROR 默认值由 lib.sh 提供，可通过 --mirror 覆盖
# 默认后端集合（与 build-toolchain-llvm.sh 对称，native clang 亦可交叉到这些后端）
LLVM_TARGETS="AArch64;LoongArch;RISCV;X86"
LLVM_PROJECTS="lld;clang;flang"
LLVM_RUNTIMES="flang-rt;compiler-rt"
CLEAN_BUILD=false
ARCHIVE_RESULT=false
FRESH_BUILD=false
ENABLE_SANITIZER=true
STATIC_BUILD=false

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

构建当前 host 可直接使用的本地 LLVM/Clang 工具链（clang + lld + flang，使用 host libc）。

  --llvm-ver          LLVM 版本 (默认: $LLVM_VER, 支持 git[:REF][:update])
  --src-dir           LLVM 源码目录 (直接指定已解压的源码路径，跳过下载/解压)
  --work-dir          工作目录前缀 (默认: 当前目录)
  --download-dir      源码下载目录 (默认: WORK_DIR/downloads)
  --build-dir         构建目录 (默认: WORK_DIR/build-native-llvm-HOST)
  --install-dir       安装目录 (默认: WORK_DIR/native-HOST, 与 build-native-gcc.sh 同前缀，GCC/LLVM 可共存共用一条 PATH)
  --log-dir           日志目录 (默认: WORK_DIR/logs-native-llvm-HOST)
  --targets           LLVM 构建的后端 (默认: $LLVM_TARGETS)
  --projects          LLVM 启用的项目 (默认: $LLVM_PROJECTS)
  --runtimes          LLVM 启用的运行时 (默认: $LLVM_RUNTIMES)
  --enable-sanitizer / --disable-sanitizer 是否构建 compiler-rt sanitizer 运行库 (默认开启)
  --link-jobs         并行链接作业数 (LLVM_PARALLEL_LINK_JOBS)
  -j,--threads        并行编译线程数 (默认: ${THREADS})
  --mirror            下载镜像源 (默认: $MIRROR)
  --static            静态链接工具链自身的可执行文件 (clang/lld/flang 等)，产物不依赖 host
                      的 libc/libstdc++，可随意拷贝到同架构机器执行。需要 host 提供 libc.a
                      (glibc-static / libc6-dev) 与 libstdc++.a。目标侧运行时
                      (compiler-rt/flang-rt) 不受影响。会自动关闭 clang 插件与 LLVM dylib，
                      并给构建/日志/安装目录追加 -static 后缀，与动态构建互不干扰。
                      静态链接内存占用较高，必要时配合 --link-jobs 1 使用。

构建后处理选项:
  --fresh             构建前删除已有的 build/log/install 目录
  --clean             构建完成后删除构建目录和日志目录
  --archive           构建完成后将工具链打包成 tar.xz 并删除原目录

  -h,--help           显示帮助

示例:
  $(basename "$0")
  $(basename "$0") --llvm-ver 22.1.8 --targets X86
  $(basename "$0") --llvm-ver git:update --projects clang,lld --fresh
  $(basename "$0") --projects clang,lld --runtimes compiler-rt --static --fresh --link-jobs 2
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --llvm-ver)              LLVM_VER="$2"; shift 2;;
        --src-dir)               SRC_DIR="$2"; shift 2;;
        --work-dir)              WORK_DIR="$2"; shift 2;;
        --download-dir)          DOWNLOAD_DIR="$2"; shift 2;;
        --build-dir)             BUILD_DIR="$2"; shift 2;;
        --install-dir)           INSTALL_DIR="$2"; shift 2;;
        --log-dir)               LOG_DIR="$2"; shift 2;;
        --targets)               LLVM_TARGETS="$2"; shift 2;;
        --projects)              LLVM_PROJECTS="$2"; shift 2;;
        --runtimes)              LLVM_RUNTIMES="$2"; shift 2;;
        --enable-sanitizer)      ENABLE_SANITIZER=true; shift;;
        --disable-sanitizer)     ENABLE_SANITIZER=false; shift;;
        --link-jobs)             LINK_JOBS="$2"; shift 2;;
        -j|--threads)            THREADS="$2"; shift 2;;
        --mirror)                MIRROR="$2"; shift 2;;
        --static)                STATIC_BUILD=true; shift;;
        --fresh)                 FRESH_BUILD=true; shift;;
        --clean)                 CLEAN_BUILD=true; shift;;
        --archive)               ARCHIVE_RESULT=true; shift;;
        -h|--help)               usage;;
        *)                       error "未知选项: $1"; usage;;
    esac
done

# 允许使用逗号分隔后端/项目/运行时（更符合 CLI 习惯），内部转换为 CMake 需要的分号
LLVM_TARGETS="${LLVM_TARGETS//,/;}"
LLVM_PROJECTS="${LLVM_PROJECTS//,/;}"
LLVM_RUNTIMES="${LLVM_RUNTIMES//,/;}"

# ==============================================================================
# 前置依赖检查
# ==============================================================================

command -v cmake >/dev/null 2>&1 || error "未找到 cmake，请先安装 cmake"
command -v ninja >/dev/null 2>&1 || error "未找到 ninja，请先安装 ninja-build"

# host 三元组（native: build == host == target）
if command -v gcc >/dev/null 2>&1; then
    HOST_TRIPLE="$(gcc -dumpmachine)"
elif command -v clang >/dev/null 2>&1; then
    HOST_TRIPLE="$(clang -dumpmachine)"
else
    HOST_TRIPLE="$(uname -m)"
fi

# ==============================================================================
# 环境设置
# ==============================================================================

WORK_DIR=$(realpath "$WORK_DIR")
STATIC_SUFFIX=""
if [[ "$STATIC_BUILD" == true ]]; then
    STATIC_SUFFIX="-static"
fi
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${WORK_DIR}/downloads}"
BUILD_DIR="${BUILD_DIR:-${WORK_DIR}/build-native-llvm-${HOST_TRIPLE}${STATIC_SUFFIX}}"
INSTALL_DIR="${INSTALL_DIR:-${WORK_DIR}/native-${HOST_TRIPLE}${STATIC_SUFFIX}}"
LOG_DIR="${LOG_DIR:-${WORK_DIR}/logs-native-llvm-${HOST_TRIPLE}${STATIC_SUFFIX}}"
canonicalize_dirs DOWNLOAD_DIR BUILD_DIR INSTALL_DIR LOG_DIR

fresh_clean_dirs "$FRESH_BUILD" "$BUILD_DIR" "$LOG_DIR" "$INSTALL_DIR"

# ==============================================================================
# 获取源码
# ==============================================================================

if [[ -n "$SRC_DIR" ]]; then
    SRC_DIR=$(realpath "$SRC_DIR")
    if [[ ! -d "$SRC_DIR" ]]; then
        error "源码目录不存在: $SRC_DIR"
    fi
else
    if [[ "$LLVM_VER" == git* ]]; then
        SRC_DIR="$DOWNLOAD_DIR/llvm-project"
        parse_git_ver "$LLVM_VER"
        git_clone "https://${MIRROR}/git/llvm-project.git" "$SRC_DIR" 1 "$_GIT_UPDATE" "$_GIT_REF"
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

info "host 三元组 (HOST_TRIPLE): ${HOST_TRIPLE}"
info "LLVM 版本: ${LLVM_VER}"
info "构建后端: ${LLVM_TARGETS}"
info "启用项目: ${LLVM_PROJECTS}"
info "启用运行时: ${LLVM_RUNTIMES}"
info "sanitizer: $([[ "$ENABLE_SANITIZER" == true ]] && echo 开启 || echo 关闭)"
info "静态链接: $([[ "$STATIC_BUILD" == true ]] && echo 开启 || echo 关闭)"
info "源码目录: ${SRC_DIR}"
info "工作目录: ${WORK_DIR}"
info "构建目录: ${BUILD_DIR}"
info "安装目录: ${INSTALL_DIR}"
info "日志目录: ${LOG_DIR}"
info "构建线程数: ${THREADS}"

# ==============================================================================
# 构建流程
# ==============================================================================

step "=== 配置 LLVM ==="
CMAKE_EXTRA_ARGS=()
if [[ -n "$LINK_JOBS" ]]; then
    CMAKE_EXTRA_ARGS+=("-DLLVM_PARALLEL_LINK_JOBS=${LINK_JOBS}")
fi

# zlib 默认强制开启；静态构建需要 host 提供 libz.a，否则退化为关闭
LLVM_ZLIB_OPT=FORCE_ON

# 静态链接处理
# CMAKE_EXE_LINKER_FLAGS=-static 只作用于本次 CMake 工程 (llvm/clang/lld/flang 等 host
# 可执行文件)。compiler-rt / flang-rt 由 llvm_ExternalProject_Add 起独立的子 CMake 构建，
# 不继承这里的 CMAKE_EXE_LINKER_FLAGS，但仍显式在 RUNTIMES/BUILTINS_CMAKE_ARGS 里清空，
# 避免将来 LLVM 改变透传行为时把目标侧运行时也静态化。
if [[ "$STATIC_BUILD" == true ]]; then
    CMAKE_EXTRA_ARGS+=(
        "-DCMAKE_EXE_LINKER_FLAGS=-static"
        # PIC=OFF 才能跳过 libclang-cpp.so / libLLVM.so 等共享库
        # (否则会把非 PIC 的 libz.a 链进共享库而失败)
        -DLLVM_ENABLE_PIC=OFF
        # 静态可执行文件没有 dynamic section，安装阶段的 RPATH 改写会失败
        -DCMAKE_SKIP_RPATH=ON
        -DLLVM_STATIC_LINK_CXX_STDLIB=ON
        -DLLVM_BUILD_LLVM_DYLIB=OFF
        -DLLVM_LINK_LLVM_DYLIB=OFF
        -DLLVM_BUILD_LLVM_C_DYLIB=OFF
        -DCLANG_LINK_CLANG_DYLIB=OFF
        -DLLVM_ENABLE_PLUGINS=OFF
        -DCLANG_PLUGIN_SUPPORT=OFF
        -DLLVM_ENABLE_LIBEDIT=OFF
        -DLLVM_ENABLE_LIBXML2=OFF
        -DLLVM_ENABLE_ZSTD=OFF
        "-DRUNTIMES_CMAKE_ARGS=-DCMAKE_EXE_LINKER_FLAGS="
        "-DBUILTINS_CMAKE_ARGS=-DCMAKE_EXE_LINKER_FLAGS="
    )

    host_libc_a="$(gcc -print-file-name=libc.a 2>/dev/null || true)"
    if [[ ! -f "$host_libc_a" ]]; then
        warn "未找到 libc.a，静态链接可能失败。请安装 glibc-static (RPM) 或 libc6-dev (DEB)。"
    fi
    host_libstdcxx_a="$(gcc -print-file-name=libstdc++.a 2>/dev/null || true)"
    if [[ ! -f "$host_libstdcxx_a" ]]; then
        warn "未找到 libstdc++.a，静态链接可能失败。请安装 libstdc++-static (RPM) 或 libstdc++-dev (DEB)。"
    fi
    host_libz_a="$(gcc -print-file-name=libz.a 2>/dev/null || true)"
    if [[ -f "$host_libz_a" ]]; then
        # FindZLIB 默认优先找到 libz.so，-static 下显式链接 .so 会报
        # "attempted static link of dynamic object"，因此直接指定静态库。
        host_libz_a="$(realpath "$host_libz_a")"
        CMAKE_EXTRA_ARGS+=(
            "-DZLIB_LIBRARY_RELEASE=${host_libz_a}"
            "-DZLIB_LIBRARY=${host_libz_a}"
        )
    else
        LLVM_ZLIB_OPT=OFF
        warn "未找到 libz.a，静态构建已关闭 zlib 支持 (装 zlib-static / zlib1g-dev 可启用)。"
    fi
fi

# sanitizer 由 compiler-rt 提供，默认开启
SANITIZER_ONOFF=OFF
if [[ "$ENABLE_SANITIZER" == true ]]; then
    SANITIZER_ONOFF=ON
    case ";${LLVM_RUNTIMES};" in
        *";compiler-rt;"*) ;;
        *) warn "已启用 sanitizer 但 --runtimes 未包含 compiler-rt，sanitizer 运行库不会被构建" ;;
    esac
fi

cd "${BUILD_DIR}"

# native: 不设置 LLVM_DEFAULT_TARGET_TRIPLE，默认即 host 三元组
build_step "configure" "${LOG_DIR}" \
    cmake \
    -G Ninja \
    "${SRC_DIR}/llvm" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_TARGETS_TO_BUILD="${LLVM_TARGETS}" \
    -DLLVM_ENABLE_PROJECTS="${LLVM_PROJECTS}" \
    -DLLVM_ENABLE_RUNTIMES="${LLVM_RUNTIMES}" \
    -DCOMPILER_RT_BUILD_SANITIZERS=${SANITIZER_ONOFF} \
    -DLLVM_ENABLE_ZLIB=${LLVM_ZLIB_OPT} \
    "${CMAKE_EXTRA_ARGS[@]}"

step "=== 构建 LLVM ==="
cd "${BUILD_DIR}"
build_step "build" "${LOG_DIR}" ninja -j"${THREADS}"

step "=== 安装 LLVM ==="
cd "${BUILD_DIR}"
build_step "install" "${LOG_DIR}" ninja install

if [[ "$STATIC_BUILD" == true ]]; then
    static_check_paths=()
    for exe in clang clang++ clang-cpp lld ld.lld llvm-ar llvm-nm llvm-objdump \
               llvm-ranlib llvm-strip llvm-config flang flang-new; do
        static_check_paths+=("${INSTALL_DIR}/bin/${exe}")
    done
    verify_static_binaries "${static_check_paths[@]}" || true
fi

# ==============================================================================
# 完成输出
# ==============================================================================

ok "=== LLVM 构建完成 ==="
echo -e "本地编译器路径: ${GREEN}${INSTALL_DIR}/bin${NC}"
echo -e "日志目录:       ${GREEN}${LOG_DIR}${NC}"
echo ""
echo -e "使用方法:"
echo -e "  ${GREEN}export PATH=\"${INSTALL_DIR}/bin:\$PATH\"${NC}"
echo -e "  ${GREEN}clang --version${NC}"

# 构建后处理
clean_build_dir "$BUILD_DIR" "$LOG_DIR" "$CLEAN_BUILD"
archive_toolchain "$INSTALL_DIR" "$ARCHIVE_RESULT"
