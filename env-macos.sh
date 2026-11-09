#!/usr/bin/env bash

# 首次安装依赖: ./install-prerequisites.sh

case "${1:-}" in
    -h|--help) echo "用法: $(basename "$0") COMMAND [ARGS...]（使用 Homebrew 构建环境执行命令）"; exit 0;;
    "") echo "错误: 缺少要执行的命令" >&2; exit 1;;
    -*) echo "错误: 未知选项: $1" >&2; exit 1;;
esac

ulimit -n 16384

# Homebrew 前缀自动探测 (Apple Silicon: /opt/homebrew, Intel: /usr/local)
HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /opt/homebrew)}"

# Homebrew bash 为必需工具：构建脚本依赖高版本 bash 特性 (如 set -u 下空数组展开需 bash 4.4+)，
# macOS 系统自带 bash 3.2 不满足，禁止回退
BASH_BIN="$HOMEBREW_PREFIX/bin/bash"
if [[ ! -x "$BASH_BIN" ]]; then
    echo "错误: 未找到 Homebrew bash ($BASH_BIN)，请先执行 brew install bash" >&2
    exit 1
fi

# 未指定 CC/CXX 时使用最新 Homebrew GCC (可用 GCC_MAJOR 环境变量覆盖)
if [[ -z "${CC:-}" || -z "${CXX:-}" ]]; then
    if [[ -z "${GCC_MAJOR:-}" ]]; then
        GCC_MAJOR=$(ls "$HOMEBREW_PREFIX"/bin/gcc-[0-9]* 2>/dev/null | sed -E 's/.*gcc-([0-9]+)$/\1/' | sort -n | tail -1)
    fi
    if [[ -z "${GCC_MAJOR:-}" ]]; then
        echo "错误: 未在 $HOMEBREW_PREFIX/bin 找到 gcc-N，请先执行 brew install gcc" >&2
        exit 1
    fi
    for compiler in "gcc-${GCC_MAJOR}" "g++-${GCC_MAJOR}"; do
        if [[ ! -x "$HOMEBREW_PREFIX/bin/$compiler" ]]; then
            echo "错误: 未找到 Homebrew 编译器 $HOMEBREW_PREFIX/bin/${compiler}，请检查 GCC_MAJOR 或执行 brew install gcc" >&2
            exit 1
        fi
    done
fi
CC="${CC:-gcc-${GCC_MAJOR}}"
CXX="${CXX:-g++-${GCC_MAJOR}}"

# GNU make 为必需工具：macOS 系统自带 make 版本过旧，会导致奇怪构建错误，禁止回退
MAKE_BIN="$HOMEBREW_PREFIX/opt/make/libexec/gnubin/make"
if [[ ! -x "$MAKE_BIN" ]]; then
    echo "错误: 未找到 GNU make ($MAKE_BIN)，请先执行 brew install make" >&2
    exit 1
fi

# 检查 Homebrew 工具目录：存在的加入 PATH，缺失的警告并跳过 (格式: 相对目录:brew包名)
GNU_TOOL_DIRS=(
    "opt/coreutils/libexec/gnubin:coreutils"
    "opt/grep/libexec/gnubin:grep"
    "opt/findutils/libexec/gnubin:findutils"
    "opt/bison/bin:bison"
    "opt/flex/bin:flex"
    "opt/texinfo/bin:texinfo"
    "opt/python@3/libexec/bin:python"
    "opt/gawk/libexec/gnubin:gawk"
    "opt/gnu-sed/libexec/gnubin:gnu-sed"
)

GNU_PATHS=("$HOMEBREW_PREFIX/bin" "$HOMEBREW_PREFIX/opt/make/libexec/gnubin")
MISSING_PKGS=()
for entry in "${GNU_TOOL_DIRS[@]}"; do
    dir="$HOMEBREW_PREFIX/${entry%%:*}"
    pkg="${entry##*:}"
    if [[ -d "$dir" ]]; then
        GNU_PATHS+=("$dir")
    else
        echo "警告: Homebrew 工具目录不存在，已跳过: $dir (对应包: $pkg)" >&2
        MISSING_PKGS+=("$pkg")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    echo "警告: 部分 Homebrew 工具未安装，完整构建可能失败，建议执行: brew install ${MISSING_PKGS[*]}" >&2
fi

# 拼接冒号分隔的 PATH
GNU_PATH_STR=$(IFS=:; echo "${GNU_PATHS[*]}")

# Linux Kbuild 和交叉构建 glibc 需要单独指定本机辅助工具的编译器。
exec env \
    CXX="$CXX" \
    CC="$CC" \
    BUILD_CC="${BUILD_CC:-$CC}" \
    HOSTCC="${HOSTCC:-$CC}" \
    HOSTCXX="${HOSTCXX:-$CXX}" \
    MAKE="$MAKE_BIN" \
    PATH="$GNU_PATH_STR:$PATH" \
    "$@"

    # 用法示例 (脚本 shebang 为 #!/usr/bin/env bash，经 PATH 优先解析，自动使用 Homebrew bash 执行):
    # ./env-macos.sh ./build-toolchain-gcc-batch.sh -a aarch64,loongarch64,riscv32,riscv64 -l glibc,musl --clean --archive
    # ./env-macos.sh ./build-toolchain-gcc.sh --arch riscv64 --libc musl --clean --archive
