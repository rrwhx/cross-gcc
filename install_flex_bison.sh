#!/usr/bin/env bash
# ============================================================
# install_flex_bison.sh
# 下载、编译、安装 flex + bison + texinfo，供 glibc 编译使用
# 默认安装前缀: $HOME/.local
# ============================================================

set -euo pipefail

# ─── 颜色输出 ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── 可配置变量 ──────────────────────────────────────────────
PREFIX="${PREFIX:-$HOME/.local}"
BUILD_DIR="${BUILD_DIR:-/tmp/build_flex_bison_$$}"

FLEX_VERSION="${FLEX_VERSION:-2.6.4}"
BISON_VERSION="${BISON_VERSION:-3.8.2}"
TEXINFO_VERSION="${TEXINFO_VERSION:-7.3}"

JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"
# 为了兼容 macOS 较新版 Clang，避免 implicit-function-declaration 错误
export CFLAGS="-g -O2 -Wno-implicit-function-declaration"

# ─── 帮助信息 ────────────────────────────────────────────────
usage() {
  cat <<EOF
用法: $0 [选项]

选项:
  -p, --prefix PATH       安装前缀 (默认: \$HOME/.local)
  -j, --jobs N            并行编译数 (默认: nproc)
  --flex-version VER      flex 版本 (默认: ${FLEX_VERSION})
  --bison-version VER     bison 版本 (默认: ${BISON_VERSION})
  --texinfo-version VER   texinfo 版本 (默认: ${TEXINFO_VERSION})
  --keep-build            安装后保留构建目录
  -h, --help              显示帮助

环境变量:
  PREFIX          等同于 --prefix
  JOBS            等同于 --jobs
  BUILD_DIR       构建目录 (默认: /tmp/build_flex_bison_PID)

示例:
  $0
  $0 --prefix /opt/tools --jobs 8
  PREFIX=/usr/local $0
EOF
  exit 0
}

# ─── 参数解析 ────────────────────────────────────────────────
KEEP_BUILD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--prefix)        PREFIX="$2";        shift 2 ;;
    -j|--jobs)          JOBS="$2";          shift 2 ;;
    --flex-version)     FLEX_VERSION="$2";  shift 2 ;;
    --bison-version)    BISON_VERSION="$2"; shift 2 ;;
    --texinfo-version)  TEXINFO_VERSION="$2"; shift 2 ;;
    --keep-build)       KEEP_BUILD=true;    shift   ;;
    -h|--help)          usage ;;
    *) die "未知参数: $1，使用 --help 查看帮助" ;;
  esac
done

FLEX_URL="https://github.com/westes/flex/releases/download/v${FLEX_VERSION}/flex-${FLEX_VERSION}.tar.gz"
BISON_URL="https://mirrors.tuna.tsinghua.edu.cn/gnu/bison/bison-${BISON_VERSION}.tar.xz"
TEXINFO_URL="https://mirrors.tuna.tsinghua.edu.cn/gnu/texinfo/texinfo-${TEXINFO_VERSION}.tar.xz"

# ─── 清理函数 ────────────────────────────────────────────────
cleanup() {
  if [[ "$KEEP_BUILD" == false && -d "$BUILD_DIR" ]]; then
    info "清理构建目录: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
  fi
}
trap cleanup EXIT

# ─── 检查依赖工具 ────────────────────────────────────────────
check_deps() {
  info "检查构建依赖..."
  local missing=()
  local tools=(gcc make curl tar gzip xz m4)
  for t in "${tools[@]}"; do
    if ! command -v "$t" &>/dev/null; then
      missing+=("$t")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "缺少以下工具: ${missing[*]}\n请先安装后再运行此脚本"
  fi
  success "依赖工具检查通过"
}

# ─── 下载函数 ────────────────────────────────────────────────
download() {
  local url="$1"
  local dest="$2"
  local name
  name=$(basename "$dest")

  if [[ -f "$dest" ]]; then
    info "$name 已存在，跳过下载"
    return
  fi

  info "下载: $url"
  if command -v curl &>/dev/null; then
    curl -fSL --progress-bar -o "$dest" "$url" \
      || die "下载失败: $url"
  else
    wget -q --show-progress -O "$dest" "$url" \
      || die "下载失败: $url"
  fi
  success "下载完成: $name"
}

# ─── 解压函数 ────────────────────────────────────────────────
extract() {
  local archive="$1"
  local dest_dir="$2"
  info "解压: $(basename "$archive")"
  mkdir -p "$dest_dir"
  tar -xf "$archive" -C "$dest_dir" --strip-components=1 \
    || die "解压失败: $archive"
  success "解压完成"
}

# ─── 构建安装函数 ─────────────────────────────────────────────
build_and_install() {
  local name="$1"
  local src_dir="$2"
  local extra_flags="${3:-}"

  info "配置 $name (prefix=$PREFIX, jobs=$JOBS)..."
  pushd "$src_dir" > /dev/null

  local tag
  tag="$(echo "$name" | tr ' ' '_')"
  local conf_log="$BUILD_DIR/${tag}_configure.log"
  local build_log="$BUILD_DIR/${tag}_build.log"
  local install_log="$BUILD_DIR/${tag}_install.log"

  if ! ./configure \
    --prefix="$PREFIX" \
    --disable-dependency-tracking \
    $extra_flags > "$conf_log" 2>&1; then
    tail -n 20 "$conf_log"
    die "配置 $name 失败！请查看日志: $conf_log"
  fi

  info "编译 $name ..."
  if ! make -j"$JOBS" > "$build_log" 2>&1; then
    tail -n 20 "$build_log"
    die "编译 $name 失败！请查看日志: $build_log"
  fi

  info "安装 $name ..."
  if ! make install > "$install_log" 2>&1; then
    tail -n 20 "$install_log"
    die "安装 $name 失败！请查看日志: $install_log"
  fi

  popd > /dev/null
  success "$name 安装完成"
}

# ─── 验证安装 ────────────────────────────────────────────────
verify() {
  local bin_dir="$PREFIX/bin"
  local all_ok=true

  echo ""
  info "═══ 验证安装结果 ═══"

  # 临时将 $PREFIX/bin 加入 PATH 进行验证
  export PATH="$bin_dir:$PATH"

  for tool in flex bison makeinfo; do
    local bin="$bin_dir/$tool"
    if [[ ! -x "$bin" ]]; then
      echo -e "  ${RED}✗${NC} $tool 二进制不存在: $bin"
      all_ok=false
      continue
    fi

    local ver
    ver=$("$bin" --version 2>&1 | head -1) || true
    if [[ -n "$ver" ]]; then
      echo -e "  ${GREEN}✓${NC} $tool => $ver"
    else
      echo -e "  ${RED}✗${NC} $tool 无法运行"
      all_ok=false
    fi
  done

  # 额外检查 flex 库 (glibc 需要 libfl)
  local libfl
  libfl=$(find "$PREFIX/lib" -name "libfl*" 2>/dev/null | head -1)
  if [[ -n "$libfl" ]]; then
    echo -e "  ${GREEN}✓${NC} libfl => $libfl"
  else
    warn "未找到 libfl 库 (某些 glibc 版本可能需要)"
  fi

  echo ""
  if [[ "$all_ok" == true ]]; then
    success "所有工具验证通过！"
  else
    die "部分工具验证失败，请检查上方错误"
  fi
}

# ─── 打印 PATH 配置提示 ───────────────────────────────────────
print_env_hint() {
  echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN} 安装成功！${NC}\n"
  echo " 请将以下内容加入您的 shell 配置文件"
  echo " (~/.bashrc / ~/.zshrc / ~/.profile):"
  echo ""
  echo "   export PATH=\"${PREFIX}/bin:\$PATH\""
  echo "   export LD_LIBRARY_PATH=\"${PREFIX}/lib:\$LD_LIBRARY_PATH\""
  echo "   # macOS 用户请考虑设置 (如果 SIP 允许):"
  echo "   # export DYLD_LIBRARY_PATH=\"${PREFIX}/lib:\$DYLD_LIBRARY_PATH\""
  echo ""
  echo " 立即生效（当前 shell）:"
  echo "   export PATH=\"${PREFIX}/bin:\$PATH\""
  echo ""
  echo " 在 glibc 构建时指定工具:"
  echo "   ../configure --prefix=<glibc安装路径> \\"
  echo "     LEX=\"${PREFIX}/bin/flex\" \\"
  echo "     YACC=\"${PREFIX}/bin/bison -y\""
  echo -e "${CYAN}══════════════════════════════════════════════════════${NC}\n"
}

# ─── 主流程 ──────────────────────────────────────────────────
main() {
  echo -e "${CYAN}"
  echo "=========================================================="
  echo " flex + bison + texinfo 自动构建安装脚本"
  echo "=========================================================="
  echo " flex 版本    : ${FLEX_VERSION}"
  echo " bison 版本   : ${BISON_VERSION}"
  echo " texinfo 版本 : ${TEXINFO_VERSION}"
  echo " 安装前缀    : ${PREFIX}"
  echo " 构建目录    : ${BUILD_DIR}"
  echo "=========================================================="
  echo -e "${NC}"

  check_deps

  # 创建目录
  mkdir -p "$BUILD_DIR" "$PREFIX/bin" "$PREFIX/lib"

  # ── 下载源码 ──
  local flex_tar="$BUILD_DIR/flex-${FLEX_VERSION}.tar.gz"
  local bison_tar="$BUILD_DIR/bison-${BISON_VERSION}.tar.xz"
  local texinfo_tar="$BUILD_DIR/texinfo-${TEXINFO_VERSION}.tar.xz"

  download "$FLEX_URL"    "$flex_tar"
  download "$BISON_URL"   "$bison_tar"
  download "$TEXINFO_URL" "$texinfo_tar"

  # ── 解压 ──
  local flex_src="$BUILD_DIR/flex-src"
  local bison_src="$BUILD_DIR/bison-src"
  local texinfo_src="$BUILD_DIR/texinfo-src"

  extract "$flex_tar"    "$flex_src"
  extract "$bison_tar"   "$bison_src"
  extract "$texinfo_tar" "$texinfo_src"

  # ── 构建安装 flex ──
  echo ""
  info "━━━ 开始构建 flex ${FLEX_VERSION} ━━━"
  # flex 可能需要 autoreconf（部分版本）
  if [[ ! -f "$flex_src/configure" ]]; then
    info "运行 autoreconf..."
    pushd "$flex_src" > /dev/null
    autoreconf -fi
    popd > /dev/null
  fi
  build_and_install "flex ${FLEX_VERSION}" "$flex_src"

  # ── 构建安装 bison ──
  echo ""
  info "━━━ 开始构建 bison ${BISON_VERSION} ━━━"
  # bison 需要 m4，已在依赖检查中确认
  build_and_install "bison ${BISON_VERSION}" "$bison_src"

  # ── 构建安装 texinfo ──
  echo ""
  info "━━━ 开始构建 texinfo ${TEXINFO_VERSION} ━━━"
  build_and_install "texinfo ${TEXINFO_VERSION}" "$texinfo_src"

  # ── 验证 ──
  verify

  # ── 提示 ──
  print_env_hint
}

main "$@"

