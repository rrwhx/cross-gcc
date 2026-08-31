#!/usr/bin/env bash
# Native GCC toolchain build script
# 构建可在当前 host 上直接使用的本地 GCC 工具链（binutils + gcc），
# 使用 host 自带的 libc（不编译 glibc/musl，不使用交叉 sysroot）。

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

# 默认版本设置（支持环境变量覆盖）
# 组件版本默认值来自 versions.env (由 lib.sh 加载)，可用环境变量或命令行覆盖

# 初始化参数
DOWNLOAD_DIR=""; SRC_DIR=""; BUILD_DIR=""; LOG_DIR=""; INSTALL_DIR=""; WORK_DIR=""
# MIRROR 默认值由 lib.sh 提供，可通过 --mirror 覆盖
CLEAN_BUILD=false
ARCHIVE_RESULT=false
ENABLE_SANITIZER=true
ENABLE_GDB=true
FRESH_BUILD=false
STATIC_BUILD=false

# 支持的语言（可通过 --languages 覆盖）
GCC_LANGUAGES="c,c++,fortran,lto"

# 显示用法
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]
  构建当前 host 可直接使用的本地 GCC 工具链（binutils + gcc，使用 host libc）。

  --work-dir     工作目录前缀 (默认: 当前目录)
  --download-dir 源码下载目录 (默认: WORK_DIR/downloads)
  --src-dir      源码解压目录 (默认: 与 download-dir 相同)
  --build-dir    构建工作目录 (默认: WORK_DIR/build-native-HOST)
  --log-dir      日志目录 (默认: WORK_DIR/logs-native-HOST)
  --install-dir  工具链安装前缀 (默认: WORK_DIR/native-HOST)
  -j,--threads   构建线程数 (默认: $THREADS)
  --mirror       下载镜像源 (默认: $MIRROR)
  --languages    GCC 启用的语言 (默认: $GCC_LANGUAGES)

版本控制选项(支持 'git[:REF][:update]' 格式):
  --binutils-ver binutils 版本 (默认: $BINUTILS_VER)
  --gcc-ver      gcc 版本 (默认: $GCC_VER)
                 git 格式: git | git:TAG | git:update | git:TAG:update
  --gdb-ver      gdb 版本 (默认: $GDB_VER, 支持 git[:REF][:update])
                 仅当 binutils 为 release 源码包且开启 gdb 时用于单独编译 gdb

构建后处理选项:
  --enable-sanitizer / --disable-sanitizer 是否构建 GCC sanitizer 运行库 (默认开启)
  --enable-gdb / --disable-gdb 是否编译 gdb (默认关闭)
                 binutils 为 git 源时随 binutils 一起编译；为 release 源码包时单独下载 gdb 编译
  --static         静态链接工具链自身的可执行文件 (gcc/as/ld/gdb 等)，
                   产物不依赖 host 的 libc/libstdc++，可随意拷贝到同架构机器执行。
                   需要 host 提供 libc.a 等静态库 (如 glibc-static / libc6-dev)。
                   注意: 静态构建会失去两项能力 —
                   1) liblto_plugin 只生成静态库 (不生成 .so)，ld 的 LTO 插件不可用，
                      -fuse-linker-plugin 报错；-flto 改走 lto-wrapper 路径，
                      已验证 (含静态库归档) 链接结果正常。
                   2) cc1 的插件支持被关闭，-fplugin 不可用。
                   与 --enable-gdb 同用时: 需要 host 提供 libgmp.a/libmpfr.a (缺失则报错)，
                   并关闭 gdb 的 TUI/python/gdbserver 以保证全静态链接。
                   构建/日志/安装目录会自动追加 -static 后缀，与动态构建互不干扰。
  --fresh          构建前删除已有的 build/log/install 目录
  --clean          构建完成后删除构建目录和日志目录
  --archive        构建完成后将工具链打包成 tar.xz 并删除原目录

  -h,--help      显示帮助
示例:
  $(basename "$0")
  $(basename "$0") --gcc-ver 16.1.0 --binutils-ver 2.43
  $(basename "$0") --gcc-ver git:update --languages c,c++ --fresh
  $(basename "$0") --disable-gdb --static --fresh
EOF
    exit 0
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --work-dir)    WORK_DIR="$2"; shift 2;;
        --download-dir)DOWNLOAD_DIR="$2"; shift 2;;
        --src-dir)     SRC_DIR="$2"; shift 2;;
        --build-dir)   BUILD_DIR="$2"; shift 2;;
        --log-dir)     LOG_DIR="$2"; shift 2;;
        --install-dir) INSTALL_DIR="$2"; shift 2;;
        -j|--threads)  THREADS="$2"; shift 2;;
        --mirror)      MIRROR="$2"; shift 2;;
        --languages)   GCC_LANGUAGES="$2"; shift 2;;
        --binutils-ver)BINUTILS_VER="$2"; shift 2;;
        --gcc-ver)     GCC_VER="$2"; shift 2;;
        --gdb-ver)     GDB_VER="$2"; shift 2;;
        --enable-sanitizer) ENABLE_SANITIZER=true; shift;;
        --disable-sanitizer) ENABLE_SANITIZER=false; shift;;
        --enable-gdb)  ENABLE_GDB=true; shift;;
        --disable-gdb) ENABLE_GDB=false; shift;;
        --static)      STATIC_BUILD=true; shift;;
        --fresh)       FRESH_BUILD=true; shift;;
        --clean)       CLEAN_BUILD=true; shift;;
        --archive)     ARCHIVE_RESULT=true; shift;;
        -h|--help)     usage;;
        *)             error "未知选项: $1"; usage;;
    esac
done

# host 三元组（native: build == host == target）
if ! command -v gcc >/dev/null 2>&1; then
    error "未找到 host gcc，无法确定本机三元组，请先安装系统编译器"
fi
HOST_TRIPLE="$(gcc -dumpmachine)"
info "host 三元组 (HOST_TRIPLE): $HOST_TRIPLE"

# 显示版本信息
info "=== 组件版本信息 ==="
info "Binutils 版本: $BINUTILS_VER"
info "GCC 版本: $GCC_VER"
info "启用语言: $GCC_LANGUAGES"
info "sanitizer: $([[ "$ENABLE_SANITIZER" == true ]] && echo 开启 || echo 关闭)"
info "静态链接: $([[ "$STATIC_BUILD" == true ]] && echo 开启 || echo 关闭)"

# sanitizer 处理
gcc_extra_args=()
if [[ "$ENABLE_SANITIZER" == false ]]; then
    gcc_extra_args+=(--disable-libsanitizer)
fi

# 静态链接处理
# 三个组件的静态链接方式不同, 原因如下:
# - binutils/gdb 的可执行文件全部由 libtool 链接。libtool 会把 -static 降级理解为
#   "优先选用静态库", 并不会真正传给链接器, 只有 -all-static 才会生成全静态可执行文件;
#   而 configure 会把空的 LDFLAGS 写进 Makefile, 所以环境变量不生效, 必须用 make
#   命令行覆盖 (优先级最高且会传递给子 make)。
#   但 -all-static 又不能出现在 configure 阶段: gcc 不认识该选项, 会导致子目录
#   configure 报 "C compiler cannot create executables"。
#   因此采用两段式构建: 先用 make configure-host 跑完所有子目录 configure,
#   再带 LDFLAGS=-all-static 执行真正的编译与链接。
# - gcc 的 host 工具 (gcc/cc1/cc1plus/...) 由 gcc 自己直接链接, 不经过 libtool,
#   因此 configure 阶段的 LDFLAGS=-static 即可生效; GCC 顶层会把 host 的 LDFLAGS 与
#   target 的 LDFLAGS_FOR_TARGET 分开传递, 所以 target 运行库 (libgcc_s.so/
#   libstdc++.so 等) 仍保持共享构建, 不受本选项影响。
binutils_static_args=()
gdb_static_args=()
gdb_only_static_args=()
gcc_static_args=()
binutils_make_args=()
gdb_make_args=()
gcc_configure_env=()
# binutils 功能开关默认值 (动态构建): 启用 gold 与链接期 LTO 插件
binutils_feature_args=(--enable-gold=yes --enable-plugins)
STATIC_SUFFIX=""
if [[ "$STATIC_BUILD" == true ]]; then
    STATIC_SUFFIX="-static"
    # 关闭 gold (C++/libtool, 静态链接易出问题) 与 gprofng (依赖共享 collector 库);
    # 但保留 plugins: ar/ranlib/nm 及 libtool 安装 .a 时会用 `ranlib --plugin`,
    # 关闭 plugins 会让静态 ranlib 不认识 --plugin 而导致安装失败。
    binutils_feature_args=(--disable-gold --enable-plugins --disable-gprofng)
    binutils_static_args+=(--disable-shared)
    binutils_make_args=("LDFLAGS=-all-static")

    # gdb 专属的静态开关 (关闭依赖动态加载的 python/TUI/gdbserver)，
    # 随 binutils 树编译时也需要传入。gdb 14+ 依赖的 GMP/MPFR 静态库须由 host 提供。
    gdb_only_static_args=(--with-static-standard-libraries
                          --without-python --disable-tui --disable-gdbserver)
    gdb_static_args+=(--disable-shared --disable-gprofng "${gdb_only_static_args[@]}")
    gdb_make_args=("LDFLAGS=-all-static")
    [[ "$ENABLE_GDB" == true ]] && require_static_gdb_libs

    gcc_static_args+=(--disable-plugin)
    gcc_configure_env=(env "LDFLAGS=-static")

    # 简单前置检查：静态链接需要 host 提供 libc.a
    if ! host_has_static_lib libc.a; then
        warn "未找到 libc.a，静态链接可能失败。请安装 glibc-static (RPM) 或 libc6-dev (DEB)。"
    fi
fi

# 设置默认目录
if [[ -n "$WORK_DIR" ]]; then
    mkdir -p "$WORK_DIR"
fi
BASE_DIR="${WORK_DIR:-$PWD}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$BASE_DIR/downloads}"
SRC_DIR="${SRC_DIR:-$DOWNLOAD_DIR}"
BUILD_DIR="${BUILD_DIR:-$BASE_DIR/build-native-$HOST_TRIPLE$STATIC_SUFFIX}"
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs-native-$HOST_TRIPLE$STATIC_SUFFIX}"
INSTALL_DIR="${INSTALL_DIR:-$BASE_DIR/native-$HOST_TRIPLE$STATIC_SUFFIX}"
canonicalize_dirs DOWNLOAD_DIR SRC_DIR BUILD_DIR LOG_DIR INSTALL_DIR

fresh_clean_dirs "$FRESH_BUILD" "$BUILD_DIR" "$LOG_DIR" "$INSTALL_DIR"

# 设置各组件源码目录
if [[ "$BINUTILS_VER" == git* ]]; then
    SRC_DIR_BINUTILS="$SRC_DIR/binutils"
else
    SRC_DIR_BINUTILS="$SRC_DIR/binutils-${BINUTILS_VER}"
fi

if [[ "$GCC_VER" == git* ]]; then
    SRC_DIR_GCC="$SRC_DIR/gcc"
else
    SRC_DIR_GCC="$SRC_DIR/gcc-${GCC_VER}"
fi

# 设置各组件构建目录
BUILD_DIR_BINUTILS="$BUILD_DIR/build-binutils"
BUILD_DIR_GCC="$BUILD_DIR/build-gcc"
BUILD_DIR_GDB="$BUILD_DIR/build-gdb"

LOG_DIR_BINUTILS="$LOG_DIR/binutils"
LOG_DIR_GCC="$LOG_DIR/gcc"
LOG_DIR_GDB="$LOG_DIR/gdb"

# 设置安装前缀
INSTALL_PREFIX="$INSTALL_DIR"
info "工具链安装前缀: $INSTALL_PREFIX"
info "下载目录: $DOWNLOAD_DIR"
info "源码目录: $SRC_DIR"
info "构建目录: $BUILD_DIR"
info "日志目录: $LOG_DIR"
info "构建线程数: $THREADS"

# 确保 GCC 依赖 (gmp/mpfr/mpc/isl) 已下载并解压 (幂等, 由 prereq_done 标记守护)
ensure_gcc_prerequisites() {
    cd "$SRC_DIR_GCC" || error "无法进入 GCC 源码目录"
    if [[ ! -f "prereq_done" ]]; then
        build_step "gcc_download_prerequisites" "${LOG_DIR_GCC}" "${SCRIPT_DIR}/prepare-gcc.sh"
        info "GCC 依赖下载完成 (日志: $LOG_DIR_GCC)"
        touch prereq_done
    fi
}

# 根据 --enable-gdb/--disable-gdb 决定 gdb 的编译方式:
# - binutils 为 git 源 (binutils-gdb.git) 时, gdb 随 binutils 一起编译;
# - binutils 为 release 源码包 (不含 gdb) 时, 单独下载 gdb 源码包并独立编译。
binutils_gdb_args=()
BUILD_GDB_SEPARATE=false
if [[ "$BINUTILS_VER" == git* ]]; then
    if [[ "$ENABLE_GDB" == true ]]; then
        binutils_gdb_args+=(--enable-gdb "${gdb_only_static_args[@]}")
    else
        binutils_gdb_args+=(--disable-gdb --disable-sim)
    fi
elif [[ "$ENABLE_GDB" == true ]]; then
    BUILD_GDB_SEPARATE=true
    if [[ "$GDB_VER" == git* ]]; then
        SRC_DIR_GDB="$SRC_DIR/binutils-gdb"
    else
        SRC_DIR_GDB="$SRC_DIR/gdb-${GDB_VER}"
    fi
    info "binutils 为 release 源码包(不含 gdb)，将单独下载并编译 gdb ${GDB_VER}"
fi

step "下载源代码"
dl_files=()

fetch_source "$BINUTILS_VER" "$SRC_DIR_BINUTILS" "https://${MIRROR}/git/binutils-gdb.git" "https://${MIRROR}/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"
fetch_source "$GCC_VER" "$SRC_DIR_GCC" "https://${MIRROR}/git/gcc.git" "https://${MIRROR}/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
if [[ "$BUILD_GDB_SEPARATE" == true ]]; then
    fetch_source "$GDB_VER" "$SRC_DIR_GDB" "https://${MIRROR}/git/binutils-gdb.git" "https://${MIRROR}/gnu/gdb/gdb-${GDB_VER}.tar.xz"
fi

download_dl_files "$DOWNLOAD_DIR"

# 解压源码
step "解压源代码"
extract_dl_files "$DOWNLOAD_DIR" "$SRC_DIR"

# 让后续 GCC 构建优先使用本次编译安装的 binutils（as/ld/ar 等）
export PATH="${INSTALL_PREFIX}/bin:${PATH}"

# 构建 Binutils（native: 不指定 --target）
step "=== 构建 Binutils ==="
mkdir -p "$BUILD_DIR_BINUTILS"
cd "$BUILD_DIR_BINUTILS" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR_BINUTILS}" \
    "$SRC_DIR_BINUTILS/configure" \
    --prefix="$INSTALL_PREFIX" \
    --disable-multilib \
    "${binutils_feature_args[@]}" \
    --disable-nls \
    --disable-werror \
    "${binutils_static_args[@]}" \
    "${binutils_gdb_args[@]}"

# 静态构建时先跑完子目录 configure (不带 -all-static, 否则 gcc 无法识别该选项)
if [[ "$STATIC_BUILD" == true ]]; then
    build_step "configure-host" "${LOG_DIR_BINUTILS}" \
        make -j${THREADS} configure-host
fi

build_step "build" "${LOG_DIR_BINUTILS}" \
    make -j${THREADS} "${binutils_make_args[@]}"

build_step "install" "${LOG_DIR_BINUTILS}" \
    make install-strip "${binutils_make_args[@]}"

# 使用 release 源码包时单独编译 gdb (git 源已随 binutils 编译)
if [[ "$BUILD_GDB_SEPARATE" == true ]]; then
    step "=== 构建 GDB (独立) ==="
    mkdir -p "$BUILD_DIR_GDB"
    cd "$BUILD_DIR_GDB" || error "无法进入构建目录"
    build_step "configure" "${LOG_DIR_GDB}" \
        "$SRC_DIR_GDB/configure" \
        --prefix="$INSTALL_PREFIX" \
        --disable-multilib \
        --disable-nls \
        --disable-werror \
        --disable-sim \
        "${gdb_static_args[@]}"
    # 仅构建/安装 gdb 组件, 避免覆盖 binutils 已安装的 bfd/opcodes 等
    if [[ "$STATIC_BUILD" == true ]]; then
        build_step "configure-host" "${LOG_DIR_GDB}" \
            make -j${THREADS} configure-host
    fi
    build_step "build" "${LOG_DIR_GDB}" \
        make -j${THREADS} all-gdb "${gdb_make_args[@]}"
    build_step "install" "${LOG_DIR_GDB}" \
        make install-gdb "${gdb_make_args[@]}"
fi

# 准备 GCC 源码并下载依赖库
step "==== 准备 GCC 源码 ==="
ensure_gcc_prerequisites

# 构建 GCC（native: 单阶段，使用 host libc）
step "=== 构建 GCC ==="
mkdir -p "$BUILD_DIR_GCC"
cd "$BUILD_DIR_GCC" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR_GCC}" \
    "${gcc_configure_env[@]}" \
    "$SRC_DIR_GCC/configure" \
    --prefix="$INSTALL_PREFIX" \
    --disable-multilib \
    --disable-bootstrap \
    --enable-checking=release \
    --enable-languages="$GCC_LANGUAGES" \
    --enable-threads=posix \
    --enable-shared \
    --disable-nls \
    --disable-werror \
    "${gcc_static_args[@]}" \
    "${gcc_extra_args[@]}"

build_step "build" "${LOG_DIR_GCC}" \
    make -j${THREADS}

build_step "install" "${LOG_DIR_GCC}" \
    make install-strip-host install-target

# 完成输出
ok "=== 构建完成 ==="

# 运行时动态库目录（多数 64 位平台为 lib64，部分平台为 lib）
RUNTIME_LIBDIR="${INSTALL_PREFIX}/lib64"
[[ -d "$RUNTIME_LIBDIR" ]] || RUNTIME_LIBDIR="${INSTALL_PREFIX}/lib"

echo -e "本地编译器路径: ${GREEN}${INSTALL_PREFIX}/bin${NC}"
echo -e "运行时库目录:   ${GREEN}${RUNTIME_LIBDIR}${NC}"
echo -e "日志目录:       ${GREEN}${LOG_DIR}${NC}"
echo ""
echo -e "使用方法:"
echo -e "  # 1) 将编译器加入 PATH"
echo -e "  ${GREEN}export PATH=\"${INSTALL_PREFIX}/bin:\$PATH\"${NC}"
echo -e "  # 运行新编译器生成的 C++/共享库程序时，需让新版 libstdc++/libgcc_s 可被加载，任选其一:"
echo -e "  # 2) 运行前设置动态库搜索路径"
echo -e "  ${GREEN}export LD_LIBRARY_PATH=\"${RUNTIME_LIBDIR}:\$LD_LIBRARY_PATH\"${NC}"
echo -e "  # 3) 编译时将库路径写入 rpath（免去每次设置环境变量）"
echo -e "  ${GREEN}g++ prog.cpp -Wl,-rpath,${RUNTIME_LIBDIR}${NC}"
echo -e "  # 4) 或静态链接运行时库"
echo -e "  ${GREEN}g++ -static-libstdc++ -static-libgcc prog.cpp${NC}"

# 静态链接校验：确认关键可执行文件不再依赖动态库
if [[ "$STATIC_BUILD" == true ]]; then
    libexec_dir="$(dirname "$("${INSTALL_PREFIX}/bin/gcc" -print-prog-name=cc1 2>/dev/null || true)")"
    verify_static_binaries \
        "${INSTALL_PREFIX}/bin/as" "${INSTALL_PREFIX}/bin/ld" "${INSTALL_PREFIX}/bin/ar" \
        "${INSTALL_PREFIX}/bin/objdump" "${INSTALL_PREFIX}/bin/gcc" "${INSTALL_PREFIX}/bin/g++" \
        "${INSTALL_PREFIX}/bin/gdb" "${libexec_dir}/cc1" "${libexec_dir}/cc1plus" || true
fi

# 构建后处理
clean_build_dir "$BUILD_DIR" "$LOG_DIR" "$CLEAN_BUILD"
archive_toolchain "$INSTALL_PREFIX" "$ARCHIVE_RESULT"
