#!/usr/bin/env bash
# Toolchain smoke test
# 用交叉工具链编译 C/C++/Fortran (动态与静态链接) 的最小程序，
# 并可选地通过 qemu-user 运行，验证产物确实可在目标架构上执行。
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
# 参数
# ---------------------------------------------------------------------------
TARGET=""
TOOLCHAIN_DIR=""
WORK_DIR=$(pwd)
QEMU_DIR=""
RUN_MODE="static"   # none | static | all
STRICT=false
LANGUAGE_LIST="c,c++,fortran"

usage() {
    cat <<EOF
用法: $(basename "$0") --toolchain-dir DIR --target TRIPLE [选项]

用交叉工具链编译并（可选）在 qemu-user 下运行 C/C++/Fortran 冒烟测试。

  --toolchain-dir DIR  工具链根目录 (含 bin/<target>-gcc), 例如 ./cross-riscv64-linux-gnu
  --target TRIPLE      目标三元组, 例如 riscv64-linux-gnu
  --work-dir DIR       测试工作目录 (默认: 当前目录)
  --qemu-dir DIR       qemu-user 二进制目录 (默认: 从 PATH 查找 qemu-<arch>)
  --run-mode MODE      运行模式: none(仅编译) | static(运行静态产物,默认) | all(静态+动态)
  --languages LIST     要测试的语言 (逗号分隔: c,c++,fortran，默认全部；cxx 为 c++ 别名)
  --strict             选定语言编译器或需要运行的 QEMU 缺失时判定失败
  -h,--help            显示帮助

说明:
  - 编译阶段覆盖选定语言的动态与静态链接；缺少编译器记录 SKIP，严格模式视为失败。
  - 运行阶段默认只跑静态产物 (不依赖目标动态库/加载器, 最稳定)；
    --run-mode all 会额外用 'qemu -L <sysroot>' 运行动态产物。
  - 若找不到对应的 qemu-<arch>, 运行项标记为 SKIP, 编译项仍会执行。

示例:
  $(basename "$0") --toolchain-dir ./cross-riscv64-linux-gnu --target riscv64-linux-gnu
  $(basename "$0") --toolchain-dir ./cross-aarch64-linux-gnu --target aarch64-linux-gnu --run-mode all
  $(basename "$0") --toolchain-dir ./cross-loongarch64-linux-gnu --target loongarch64-linux-gnu --run-mode none
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --toolchain-dir) TOOLCHAIN_DIR="$2"; shift 2;;
        --target)        TARGET="$2"; shift 2;;
        --work-dir)      WORK_DIR="$2"; shift 2;;
        --qemu-dir)      QEMU_DIR="$2"; shift 2;;
        --run-mode)      RUN_MODE="$2"; shift 2;;
        --languages)     LANGUAGE_LIST="$2"; shift 2;;
        --strict)        STRICT=true; shift;;
        -h|--help)       usage;;
        *)               error "未知选项: $1"; usage;;
    esac
done

if [[ -z "$TARGET" || -z "$TOOLCHAIN_DIR" ]]; then
    error "--toolchain-dir 和 --target 参数为必需。"
fi

case "$RUN_MODE" in
    none|static|all) ;;
    *) error "无效的 --run-mode: $RUN_MODE (可选: none|static|all)";;
esac

[[ -n "$LANGUAGE_LIST" && "$LANGUAGE_LIST" != ,* && "$LANGUAGE_LIST" != *, && "$LANGUAGE_LIST" != *,,* ]] \
    || error "--languages 必须是非空语言列表"
declare -a REQUESTED_LANGS=()
IFS=',' read -ra language_values <<< "$LANGUAGE_LIST"
for language in "${language_values[@]}"; do
    case "$language" in
        c|fortran) normalized="$language";;
        c++|cxx) normalized=cxx;;
        *) error "不支持的测试语言: $language";;
    esac
    for existing in "${REQUESTED_LANGS[@]}"; do
        [[ "$existing" != "$normalized" ]] || error "重复的测试语言: $language"
    done
    REQUESTED_LANGS+=("$normalized")
done

TOOLCHAIN_DIR=$(realpath "$TOOLCHAIN_DIR")
WORK_DIR=$(realpath "$WORK_DIR")
SYSROOT="$TOOLCHAIN_DIR/$TARGET"

if [[ ! -d "$SYSROOT" ]]; then
    error "未找到目标 sysroot: $SYSROOT (请检查 --toolchain-dir 与 --target 是否匹配)"
fi

export PATH="$TOOLCHAIN_DIR/bin:$PATH"
CC="${TARGET}-gcc"
CXX="${TARGET}-g++"
FC="${TARGET}-gfortran"
READELF="${TARGET}-readelf"

if ! command -v "$CC" >/dev/null 2>&1; then
    error "无法在 PATH 中找到交叉编译器 $CC，请检查 --toolchain-dir 结构"
fi

TESTDIR="$WORK_DIR/test-toolchain-$TARGET"
assert_safe_to_delete "$TESTDIR"
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"

info "工具链目录: $TOOLCHAIN_DIR"
info "目标三元组: $TARGET"
info "目标 sysroot: $SYSROOT"
info "运行模式: $RUN_MODE"
info "测试目录: $TESTDIR"

# ---------------------------------------------------------------------------
# qemu-user 定位
# ---------------------------------------------------------------------------
ARCH="${TARGET%%-*}"
case "$ARCH" in
    i686) QEMU_ARCH="i386" ;;
    *)    QEMU_ARCH="$ARCH" ;;
esac

QEMU=""
if [[ "$RUN_MODE" != none ]]; then
    for cand in \
        ${QEMU_DIR:+"$QEMU_DIR/qemu-$QEMU_ARCH"} \
        "qemu-$QEMU_ARCH" \
        "qemu-$QEMU_ARCH-static"; do
        if [[ "$cand" == */* ]]; then
            [[ -x "$cand" ]] && { QEMU="$cand"; break; }
        elif command -v "$cand" >/dev/null 2>&1; then
            QEMU="$(command -v "$cand")"; break
        fi
    done
    if [[ -z "$QEMU" ]]; then
        warn "未找到 qemu-$QEMU_ARCH，将仅编译不运行 (可用 build-qemu.sh 构建，或 --qemu-dir 指定)"
    else
        info "qemu-user: $QEMU"
    fi
fi

info "交叉编译器: $CC"
info "编译器版本: $("$CC" --version 2>/dev/null | head -1)"

# ---------------------------------------------------------------------------
# 测试源码
# ---------------------------------------------------------------------------
cat > "$TESTDIR/hello.c" <<'EOF'
#include <stdio.h>
int main(void) {
    printf("hello from C\n");
    return 0;
}
EOF

cat > "$TESTDIR/hello.cpp" <<'EOF'
#include <iostream>
#include <vector>
#include <numeric>
int main() {
    std::vector<int> v{1, 2, 3, 4};
    int s = std::accumulate(v.begin(), v.end(), 0);
    std::cout << "hello from C++ sum=" << s << std::endl;
    return s == 10 ? 0 : 1;
}
EOF

cat > "$TESTDIR/hello.f90" <<'EOF'
program hello
    print *, "hello from Fortran"
end program hello
EOF

# ---------------------------------------------------------------------------
# 结果统计
# ---------------------------------------------------------------------------
declare -a RESULTS=()
PASS=0; FAIL=0; SKIP=0
MISSING=0

record() {
    local st="$1" name="$2"
    case "$st" in
        PASS) ((++PASS));;
        FAIL) ((++FAIL));;
        SKIP) ((++SKIP));;
    esac
    RESULTS+=("$st|$name")
}

# 编译并（可选）运行单个用例
# 参数: lang(c|cxx|fortran) link(dynamic|static)
test_one() {
    local lang="$1" link="$2"
    local name="${lang}-${link}"
    local compiler src expect
    case "$lang" in
        c)       compiler="$CC";  src="$TESTDIR/hello.c";   expect="hello from C" ;;
        cxx)     compiler="$CXX"; src="$TESTDIR/hello.cpp"; expect="hello from C++" ;;
        fortran) compiler="$FC";  src="$TESTDIR/hello.f90"; expect="hello from Fortran" ;;
    esac

    local bin="$TESTDIR/$name"
    local clog="$TESTDIR/$name.compile.log"
    local flags=()
    [[ "$link" == static ]] && flags+=(-static)

    step "--- 用例 [$name] ---"
    info "工作目录: $TESTDIR"

    # 编译
    local ccmd=("$compiler" "$src" -o "$bin" "${flags[@]}")
    info "编译命令: ${ccmd[*]}"
    info "编译日志: $clog"
    if (cd "$TESTDIR" && "${ccmd[@]}") > "$clog" 2>&1 && [[ -s "$bin" ]]; then
        record PASS "compile $name"
        ok "编译成功: $name -> $bin"
    else
        record FAIL "compile $name"
        warn "编译失败: $name (日志: $clog)"
        tail -n 15 "$clog" >&2 || true
        return 0
    fi

    # 打印 ELF 架构信息（仅供参考）
    if command -v "$READELF" >/dev/null 2>&1; then
        local machine
        machine=$("$READELF" -h "$bin" 2>/dev/null | awk -F: '/Machine:/{gsub(/^[ \t]+/,"",$2); print $2}') || true
        [[ -n "$machine" ]] && info "ELF Machine: $machine  ($(du -h "$bin" | cut -f1))"
    fi

    # 是否运行 (return 0 避免在 static/none 模式下跳过运行时触发 set -e)
    local do_run=false
    case "$RUN_MODE" in
        all)    do_run=true ;;
        static) [[ "$link" == static ]] && do_run=true ;;
        none)   do_run=false ;;
    esac

    if [[ "$do_run" != true ]]; then
        record SKIP "run $name"
        info "跳过运行: $name (run-mode=$RUN_MODE)"
        return 0
    fi

    if [[ -z "$QEMU" ]]; then
        record SKIP "run $name"
        ((++MISSING))
        info "跳过运行: $name (无 qemu-$QEMU_ARCH)"
        return 0
    fi

    # 动态产物需要通过 -L 指向 sysroot 以定位动态加载器与 libc；
    # 而 libstdc++/libgfortran/libgcc_s 等 GCC 运行时库不在 sysroot 内，
    # 需定位其真实目录并经 LD_LIBRARY_PATH 透传给 qemu (qemu 会回退到真实主机路径加载)。
    local qargs=() qenv=() ldpath=""
    if [[ "$link" == dynamic ]]; then
        qargs+=(-L "$SYSROOT")
        if command -v "$READELF" >/dev/null 2>&1; then
            local soname libpath dir
            while read -r soname; do
                [[ -z "$soname" ]] && continue
                libpath=$("$CC" -print-file-name="$soname" 2>/dev/null)
                if [[ "$libpath" == /* && -e "$libpath" ]]; then
                    dir=$(dirname "$(realpath "$libpath")")
                    case ":$ldpath:" in *":$dir:"*) ;; *) ldpath="${ldpath:+$ldpath:}$dir" ;; esac
                fi
            done < <("$READELF" -d "$bin" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p')
            [[ -n "$ldpath" ]] && qenv=(env "LD_LIBRARY_PATH=$ldpath")
        fi
    fi

    local runcmd=()
    [[ ${#qenv[@]} -gt 0 ]] && runcmd+=("${qenv[@]}")
    runcmd+=("$QEMU" "${qargs[@]}" "$bin")
    info "运行命令: ${runcmd[*]}"
    [[ -n "$ldpath" ]] && info "运行库路径: LD_LIBRARY_PATH=$ldpath"

    local out
    if out=$(timeout 30 "${runcmd[@]}" </dev/null 2>&1) && grep -qF "$expect" <<<"$out"; then
        record PASS "run $name"
        [[ -n "$out" ]] && info "程序输出: $(head -1 <<<"$out")"
        ok "运行成功: $name"
    else
        record FAIL "run $name"
        warn "运行失败: $name"
        [[ -n "${out:-}" ]] && { echo "$out" | head -n 15 >&2 || true; }
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------
declare -a LANGS=()
for lang in "${REQUESTED_LANGS[@]}"; do
    case "$lang" in
        c) compiler="$CC";;
        cxx) compiler="$CXX";;
        fortran) compiler="$FC";;
    esac
    if command -v "$compiler" >/dev/null 2>&1; then
        LANGS+=("$lang")
    else
        warn "未找到 $compiler，跳过 $lang 测试"
        record SKIP "compile $lang-dynamic (缺少 $compiler)"
        record SKIP "compile $lang-static (缺少 $compiler)"
        ((++MISSING))
    fi
done

step "=== 开始工具链测试: $TARGET ==="
for lang in "${LANGS[@]}"; do
    for link in dynamic static; do
        test_one "$lang" "$link"
    done
done

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo ""
info "=== 测试汇总 ($TARGET) ==="
for r in "${RESULTS[@]}"; do
    st="${r%%|*}"; name="${r#*|}"
    case "$st" in
        PASS) echo -e "  ${GREEN}PASS${NC}  $name" ;;
        FAIL) echo -e "  ${RED}FAIL${NC}  $name" ;;
        SKIP) echo -e "  ${YELLOW}SKIP${NC}  $name" ;;
    esac
done
echo ""
info "通过: $PASS  失败: $FAIL  跳过: $SKIP  缺失: $MISSING"
[[ $FAIL -eq 0 && $PASS -gt 0 ]] || error "存在失败或没有实际通过的测试"
[[ "$STRICT" != true || $MISSING -eq 0 ]] || error "存在缺失的必需测试项 (--strict)"
ok "工具链测试通过"
