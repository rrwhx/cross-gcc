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
BINUTILS_VER="${BINUTILS_VER:-2.46.1}"
GCC_VER="${GCC_VER:-16.1.0}"

# 初始化参数
DOWNLOAD_DIR=""; SRC_DIR=""; BUILD_DIR=""; LOG_DIR=""; INSTALL_DIR=""; WORK_DIR=""
THREADS=${THREADS}  # 默认并行构建线程数
MIRROR="mirrors.tuna.tsinghua.edu.cn"
CLEAN_BUILD=false
ARCHIVE_RESULT=false
ENABLE_SANITIZER=false
ENABLE_GDB=false
FRESH_BUILD=false

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

构建后处理选项:
  --enable-sanitizer 开启 GCC sanitizer (默认关闭)
  --enable-gdb / --disable-gdb 是否编译 gdb (默认关闭, 需 binutils 使用 git 源)
  --fresh          构建前删除已有的 build/log/install 目录
  --clean          构建完成后删除构建目录和日志目录
  --archive        构建完成后将工具链打包成 tar.xz 并删除原目录

  -h,--help      显示帮助
示例:
  $(basename "$0")
  $(basename "$0") --gcc-ver 16.1.0 --binutils-ver 2.43
  $(basename "$0") --gcc-ver git:update --languages c,c++ --fresh
EOF
    exit 1
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
        --enable-sanitizer) ENABLE_SANITIZER=true; shift;;
        --enable-gdb)  ENABLE_GDB=true; shift;;
        --disable-gdb) ENABLE_GDB=false; shift;;
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

# sanitizer 处理
gcc_extra_args=()
if [[ "$ENABLE_SANITIZER" == false ]]; then
    gcc_extra_args+=(--disable-libsanitizer)
fi

# 设置默认目录
if [[ -n "$WORK_DIR" ]]; then
    mkdir -p "$WORK_DIR"
fi
BASE_DIR="${WORK_DIR:-$PWD}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$BASE_DIR/downloads}"
SRC_DIR="${SRC_DIR:-$DOWNLOAD_DIR}"
BUILD_DIR="${BUILD_DIR:-$BASE_DIR/build-native-$HOST_TRIPLE}"
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs-native-$HOST_TRIPLE}"
INSTALL_DIR="${INSTALL_DIR:-$BASE_DIR/native-$HOST_TRIPLE}"

DOWNLOAD_DIR=$(realpath "$DOWNLOAD_DIR")
SRC_DIR=$(realpath "$SRC_DIR")
BUILD_DIR=$(realpath "$BUILD_DIR")
LOG_DIR=$(realpath "$LOG_DIR")
INSTALL_DIR=$(realpath "$INSTALL_DIR")
mkdir -p "$DOWNLOAD_DIR" "$SRC_DIR" "$BUILD_DIR" "$LOG_DIR" "$INSTALL_DIR"

if [[ "$FRESH_BUILD" == true ]]; then
    step "=== 清理已有的 build/log/install 目录 ==="
    assert_safe_to_delete "$BUILD_DIR"
    assert_safe_to_delete "$LOG_DIR"
    assert_safe_to_delete "$INSTALL_DIR"
    rm -rf "$BUILD_DIR" "$LOG_DIR" "$INSTALL_DIR"
    mkdir -p "$BUILD_DIR" "$LOG_DIR" "$INSTALL_DIR"
fi

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

LOG_DIR_BINUTILS="$LOG_DIR/binutils"
LOG_DIR_GCC="$LOG_DIR/gcc"

# 设置安装前缀
INSTALL_PREFIX="$INSTALL_DIR"
info "工具链安装前缀: $INSTALL_PREFIX"
info "下载目录: $DOWNLOAD_DIR"
info "源码目录: $SRC_DIR"
info "构建目录: $BUILD_DIR"
info "日志目录: $LOG_DIR"
info "构建线程数: $THREADS"

# 根据 --enable-gdb/--disable-gdb 决定 binutils 是否编译 gdb
# gdb 仅存在于 binutils git 源 (binutils-gdb.git) 中，release tarball 不含 gdb
binutils_gdb_args=()
if [[ "$BINUTILS_VER" == git* ]]; then
    if [[ "$ENABLE_GDB" == true ]]; then
        binutils_gdb_args+=(--enable-gdb)
    else
        binutils_gdb_args+=(--disable-gdb --disable-sim)
    fi
elif [[ "$ENABLE_GDB" == true ]]; then
    warn "启用 gdb 需要 binutils 使用 git 源 (--binutils-ver git[:REF][:update])，当前为 release tarball(不含 gdb)，gdb 将不会被编译"
fi

step "下载源代码"
dl_files=()

fetch_source() {
    local name=$1
    local ver=$2
    local src_dir=$3
    local git_url=$4
    local tar_url=$5

    if [[ "$ver" == git* ]]; then
        parse_git_ver "$ver"
        git_clone "$git_url" "$src_dir" 1 "$_GIT_UPDATE" "$_GIT_REF"
    else
        dl_files+=("$tar_url")
    fi
}

fetch_source "Binutils" "$BINUTILS_VER" "$SRC_DIR_BINUTILS" "https://${MIRROR}/git/binutils-gdb.git" "https://${MIRROR}/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"
fetch_source "GCC" "$GCC_VER" "$SRC_DIR_GCC" "https://${MIRROR}/git/gcc.git" "https://${MIRROR}/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"

for url in "${dl_files[@]}"; do
    filename=$(basename "${url}")
    download "$url" "$DOWNLOAD_DIR/$filename"
done

# 解压源码
step "解压源代码"
for url in "${dl_files[@]}"; do
    filename=$(basename "${url}")
    info "解压: ${filename}"
    srcdir="$SRC_DIR/${filename%.tar*}"
    if [[ -d "$srcdir" ]]; then
        info "$srcdir 已解压"
    else
        tar -xf ${DOWNLOAD_DIR}/${filename} -C "$SRC_DIR" || error "解压失败"
    fi
done

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
    --enable-gold=yes \
    --enable-plugins \
    --disable-nls \
    --disable-werror \
    "${binutils_gdb_args[@]}"

build_step "build" "${LOG_DIR_BINUTILS}" \
    make -j${THREADS}

build_step "install" "${LOG_DIR_BINUTILS}" \
    make install-strip

# 准备 GCC 源码并下载依赖库
step "==== 准备 GCC 源码 ==="
cd "$SRC_DIR_GCC" || error "无法进入构建目录"
# 下载 GMP/MPFR/MPC 等依赖（放入 gcc/ 目录）
if [[ ! -f "prereq_done" ]]; then
    build_step "gcc_download_prerequisites" "${LOG_DIR_GCC}" "${SCRIPT_DIR}/prepare-gcc.sh"
    info "GCC 依赖下载完成 (日志: $LOG_DIR_GCC)"
    touch prereq_done
fi

# 构建 GCC（native: 单阶段，使用 host libc）
step "=== 构建 GCC ==="
mkdir -p "$BUILD_DIR_GCC"
cd "$BUILD_DIR_GCC" || error "无法进入构建目录"

build_step "configure" "${LOG_DIR_GCC}" \
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

# 构建后处理
clean_build_dir "$BUILD_DIR" "$LOG_DIR" "$CLEAN_BUILD"
archive_toolchain "$INSTALL_PREFIX" "$ARCHIVE_RESULT"
