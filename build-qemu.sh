#!/usr/bin/env bash
# 从源码构建 QEMU (qemu-system-* 系统模拟 与 qemu-*-linux-user 用户态模拟)。
# 自动安装构建依赖 (apt / dnf / yum)，克隆源码 (若缺失)，配置 + 编译 + 安装。
# 产物可供 test-qemu-run.sh (系统模拟) 与 test-toolchain.sh (用户态模拟) 使用。
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

# ---------------------------------------------------------------------------
# 默认配置
# ---------------------------------------------------------------------------
SRC_DIR=""
BUILD_DIR=""
PREFIX=""
TARGETS=""
ARCH_LIST=""
JOBS="$THREADS"
REPO="https://mirrors.bfsu.edu.cn/git/qemu.git"
REF="v11.0.0"
DO_INSTALL=true
DO_DEPS=false

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

从源码构建 QEMU。默认构建 riscv64 的系统模拟与用户态模拟。

  -s,--src DIR       QEMU 源码目录 (默认: ./qemu, 缺失时从 --repo 克隆 --ref)
  -b,--build DIR     out-of-tree 构建目录 (默认: <src>/build)
  -p,--prefix DIR    安装前缀 (默认: ./qemu-install)
  -a,--arch LIST     架构列表 (逗号分隔), 每个展开为 <arch>-softmmu,<arch>-linux-user
                     (例如: aarch64,loongarch64,riscv64,x86_64)
  -t,--targets LIST  直接指定 QEMU target-list (优先级高于 --arch)
  -j,--jobs N        并行编译线程数 (默认: $JOBS)
  -r,--repo URL      源码缺失时克隆的 QEMU git 地址 (默认: $REPO)
     --ref REF       克隆的分支/标签/提交 (默认: $REF)
     --install       执行 make install (默认)
     --no-install    跳过 make install
     --deps          安装系统依赖 (需 sudo)
     --no-deps       跳过系统依赖安装 (默认)
  -h,--help          显示帮助

示例:
  $(basename "$0")                                  # riscv64 系统+用户态 -> ./qemu-install
  $(basename "$0") -a aarch64,loongarch64,riscv64,x86_64
  $(basename "$0") -t riscv64-linux-user -j 16 --deps         # 首次构建: 自动装依赖 (需 sudo)
  $(basename "$0") -s ~/qemu --ref master -p ~/qemu_upstream

安装完成后，测试脚本可通过 --qemu-dir 指向 <prefix>/bin 使用:
  ./test-qemu-run.sh --qemu-dir ./qemu-install/bin
  ./test-toolchain.sh --toolchain-dir ./cross-riscv64-linux-gnu --target riscv64-linux-gnu \\
      --run-mode all --qemu-dir ./qemu-install/bin
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--src)      SRC_DIR="$2";    shift 2 ;;
        -b|--build)    BUILD_DIR="$2";  shift 2 ;;
        -p|--prefix)   PREFIX="$2";     shift 2 ;;
        -a|--arch)     ARCH_LIST="$2";  shift 2 ;;
        -t|--targets)  TARGETS="$2";    shift 2 ;;
        -j|--jobs)     JOBS="$2";       shift 2 ;;
        -r|--repo)     REPO="$2";       shift 2 ;;
        --ref)         REF="$2";        shift 2 ;;
        --install)     DO_INSTALL=true;  shift  ;;
        --no-install)  DO_INSTALL=false; shift  ;;
        --deps)        DO_DEPS=true;     shift  ;;
        --no-deps)     DO_DEPS=false;    shift  ;;
        -h|--help)     usage ;;
        *) error "未知选项: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# 计算 target-list：架构 -> <q>-softmmu,<q>-linux-user
# ---------------------------------------------------------------------------
qemu_targets_for_arch() {
    local a="$1" q
    case "$a" in
        i686) q="i386" ;;
        *)    q="$a" ;;
    esac
    printf '%s-softmmu,%s-linux-user' "$q" "$q"
}

if [[ -z "$TARGETS" ]]; then
    if [[ -n "$ARCH_LIST" ]]; then
        IFS=',' read -ra _arches <<< "$ARCH_LIST"
        parts=()
        for a in "${_arches[@]}"; do
            parts+=("$(qemu_targets_for_arch "$a")")
        done
        TARGETS=$(IFS=,; echo "${parts[*]}")
    else
        TARGETS="riscv64-softmmu,riscv64-linux-user"
    fi
fi

SRC_DIR="${SRC_DIR:-$PWD/qemu}"
BUILD_DIR="${BUILD_DIR:-$SRC_DIR/build}"
PREFIX="${PREFIX:-$PWD/qemu-install}"

info "源码目录: $SRC_DIR"
info "构建目录: $BUILD_DIR"
info "安装前缀: $PREFIX"
info "target-list: $TARGETS"
info "构建线程数: $JOBS"

# ---------------------------------------------------------------------------
# 权限助手
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    SUDO=""
    warn "非 root 且未找到 sudo；依赖安装可能失败。"
fi

# ---------------------------------------------------------------------------
# 依赖安装
# ---------------------------------------------------------------------------
detect_pm() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    else echo unknown
    fi
}

install_deps_apt() {
    step "通过 apt-get 安装构建依赖"
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update
    # meson 在 configure 期间需要 git 拉取 wrap 子项目
    # (如 tests/fp/berkeley-softfloat-3.wrap)，即使 QEMU 源码是本地的。
    $SUDO apt-get install -y --no-install-recommends \
        build-essential pkg-config ca-certificates git \
        python3 python3-pip python3-venv python3-tomli \
        ninja-build meson \
        libglib2.0-dev libpixman-1-dev libslirp-dev \
        zlib1g-dev libfdt-dev libcap-ng-dev libattr1-dev \
        flex bison
}

install_deps_yum() {
    local pm="$1"
    step "通过 $pm 安装构建依赖"
    local DNF_OPTS=(--setopt=*.skip_if_unavailable=True --setopt=timeout=15)

    $SUDO "$pm" "${DNF_OPTS[@]}" install -y epel-release || true
    if command -v dnf >/dev/null 2>&1; then
        # 阿里云 epel-aliyuncs-release 会引入 epel-modular 源，其镜像常超时；
        # 禁用它避免后续 dnf 调用卡住。
        $SUDO dnf config-manager --set-disabled epel-modular  2>/dev/null || true
        $SUDO dnf config-manager --set-disabled epel-testing  2>/dev/null || true
        $SUDO dnf config-manager --set-enabled  crb           2>/dev/null || \
        $SUDO dnf config-manager --set-enabled  powertools    2>/dev/null || true
    fi

    $SUDO "$pm" "${DNF_OPTS[@]}" install -y \
        make gcc gcc-c++ pkgconfig python3 python3-pip git \
        ninja-build meson \
        glib2-devel pixman-devel \
        zlib-devel libfdt-devel libcap-ng-devel libattr-devel \
        flex bison ca-certificates
    $SUDO "$pm" "${DNF_OPTS[@]}" install -y libslirp-devel \
        || warn "libslirp-devel 不可用，继续 (不含 slirp 网络)"
}

if [[ "$DO_DEPS" == true ]]; then
    PM="$(detect_pm)"
    case "$PM" in
        apt)     install_deps_apt ;;
        dnf|yum) install_deps_yum "$PM" ;;
        unknown) error "不支持的发行版：未找到 apt-get / dnf / yum。" ;;
    esac
else
    info "跳过依赖安装 (默认。如需自动安装构建依赖请加 --deps)"
fi

# ---------------------------------------------------------------------------
# 确保 QEMU 的 mkvenv 所需 python 依赖
# QEMU 的 configure 会运行 scripts/mkvenv.py，其导入 tomllib (Python 3.11+ 内置)
# 或在旧版本 Python 上回退到 'tomli'。
# ---------------------------------------------------------------------------
ensure_python_tomli() {
    local py
    py="$(command -v python3 || true)"
    [[ -z "$py" ]] && { warn "未找到 python3"; return 0; }
    if "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
        return 0
    fi
    "$py" -c 'import tomli' 2>/dev/null && return 0
    info "为 $py 安装 'tomli'"
    "$py" -m pip install --user tomli 2>/dev/null \
        || "$py" -m pip install tomli 2>/dev/null \
        || $SUDO "$py" -m pip install tomli \
        || warn "安装 tomli 失败；configure 可能失败"
}
ensure_python_tomli

# ---------------------------------------------------------------------------
# 获取源码
# ---------------------------------------------------------------------------
if [[ ! -f "$SRC_DIR/configure" ]]; then
    step "QEMU 源码不在 $SRC_DIR；克隆 $REPO @ $REF"
    if ! command -v git >/dev/null 2>&1; then
        error "git 未安装，无法克隆 QEMU 源码"
    fi
    git clone --depth 1 --branch "$REF" "$REPO" "$SRC_DIR" \
        || error "git 克隆失败 ($REPO @ $REF)"
else
    info "使用已有 QEMU 源码: $SRC_DIR"
fi

# ---------------------------------------------------------------------------
# 配置 + 编译 + 安装
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

step "=== 配置 QEMU ==="
"$SRC_DIR/configure" \
    --prefix="$PREFIX" \
    --target-list="$TARGETS" \
    --disable-werror

step "=== 编译 QEMU (并行 $JOBS) ==="
make -j"$JOBS"

if [[ "$DO_INSTALL" == true ]]; then
    step "=== 安装 QEMU 到 $PREFIX ==="
    make install
    PREFIX=$(realpath "$PREFIX")
    ok "完成。二进制位于 ${GREEN}${PREFIX}/bin${NC}"
    info "测试脚本可使用: --qemu-dir ${PREFIX}/bin"
else
    BUILD_DIR=$(realpath "$BUILD_DIR")
    ok "完成 (跳过安装 --no-install)。二进制位于 ${GREEN}${BUILD_DIR}${NC}"
fi
