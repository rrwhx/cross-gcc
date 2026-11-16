#!/usr/bin/env bash
# 批量构建原生及多版本交叉 GCC/LLVM 工具链的配方脚本
# 注意: 不使用 set -e，单个构建套件失败不中断后续套件 (各套件内部会汇总失败)
set -uo pipefail

# 获取脚本的绝对路径（在脚本开始时就确定）
if command -v readlink >/dev/null 2>&1; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
else
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
fi
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# 在公共库补默认值前，记录用户显式设置的编译并发。
preset_jobs="${JOBS:-}"
source "$SCRIPT_DIR/lib.sh"

# 工作目录按配方隔离，下载缓存默认共用启动目录下的 downloads。
WORK_DIR="$PWD"
common_args=(--download-dir "$PWD/downloads")
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

按预设版本依次构建原生及交叉 GCC/LLVM 工具链。
  --work-dir DIR      各配方工作目录的父目录 (默认: 当前目录)
  --download-dir DIR  所有配方共用的下载目录 (默认: 启动目录/downloads)
  -j, --jobs N        编译并发 (优先于 JOBS，LLVM 默认按可用内存估算)
  --mirror HOST      下载镜像源 (默认: $MIRROR)
  --fresh            构建前清理各配方的构建、日志和安装目录
  --clean            构建后删除构建和日志目录
  --archive          构建后打包并删除安装目录
  --static           静态链接工具链自身的可执行文件
  -h, --help         显示帮助

LLVM 链接并发通过 LLVM_LINK_JOBS 环境变量设置，默认按可用内存估算。
EOF
    exit 0
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --work-dir) require_option_value "$@"; WORK_DIR="$2"; shift 2;;
        --download-dir|--mirror)
            require_option_value "$@"; common_args+=("$1" "$2"); shift 2;;
        -j|--jobs)
            require_option_value "$@"; require_positive_integer "$1" "$2"
            preset_jobs="$2"; common_args+=("$1" "$2"); shift 2;;
        --fresh|--clean|--archive|--static) common_args+=("$1"); shift;;
        --link-jobs) error "请通过 LLVM_LINK_JOBS 环境变量设置链接并发";;
        -h|--help) usage;;
        *) error "未知选项: $1";;
    esac
done
[[ -n "$WORK_DIR" ]] || error "--work-dir 不能为空"
[[ -z "$preset_jobs" ]] || require_positive_integer "编译并发数" "$preset_jobs"
[[ -z "${LLVM_LINK_JOBS:-}" ]] || require_positive_integer "LLVM_LINK_JOBS" "$LLVM_LINK_JOBS"
mkdir -p "$WORK_DIR" || error "无法创建工作目录: $WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)" || error "无法访问工作目录: $WORK_DIR"
set -- "${common_args[@]}"
failed_cmds=()

# 每个套件失败后继续执行，最后统一报告失败命令和退出码。
run_build() {
    local status
    if "$@"; then
        return 0
    else
        status=$?
        failed_cmds+=("退出码 $status: $(format_cmd "$@")")
    fi
}

# LLVM 自动并发按编译 6 GiB/任务、链接 10 GiB/任务估算，手动设置优先。
run_llvm_build() {
    local memory_mb="" cpu_count compile_jobs link_jobs child_jobs
    local requested_compile="$preset_jobs" requested_link="${LLVM_LINK_JOBS:-}"
    cpu_count="$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || printf '1\n')"
    [[ "$cpu_count" =~ ^[1-9][0-9]*$ ]] || cpu_count=1
    if [[ -r /proc/meminfo ]]; then
        memory_mb="$(awk '
            /^MemTotal:/ { memory = $2 }
            /^MemAvailable:/ { memory = $2; exit }
            END { if (memory != "") print int(memory / 1024) }
        ' /proc/meminfo)" || memory_mb=""
    elif command -v vm_stat >/dev/null 2>&1; then
        memory_mb="$(vm_stat | awk '
            NR == 1 { for (i = 1; i <= NF; i++) if ($i == "of") page_size = $(i + 1) }
            /^Pages (free|inactive|speculative):/ { gsub(/\./, "", $NF); pages += $NF }
            END { if (page_size > 0) print int(pages * page_size / 1048576) }
        ')" || memory_mb=""
    fi
    if [[ ! "$memory_mb" =~ ^[0-9]+$ ]]; then
        warn "无法获取可用内存，LLVM 自动并发回退为 1"
        memory_mb=0
    fi
    compile_jobs=$((memory_mb / 6144))
    link_jobs=$((memory_mb / 10240))
    if (( compile_jobs < 1 )); then compile_jobs=1; fi
    if (( link_jobs < 1 )); then link_jobs=1; fi
    if (( compile_jobs > cpu_count )); then compile_jobs="$cpu_count"; fi
    if (( link_jobs > cpu_count )); then link_jobs="$cpu_count"; fi
    # 手动值覆盖自动默认值，不再按内存或 CPU 核数截断。
    compile_jobs="${requested_compile:-$compile_jobs}"
    link_jobs="${requested_link:-$link_jobs}"
    child_jobs="$link_jobs"
    if [[ "$compile_jobs" =~ ^[1-9][0-9]*$ && "$link_jobs" =~ ^[1-9][0-9]*$ ]] && (( compile_jobs < child_jobs )); then
        child_jobs="$compile_jobs"
    fi
    child_jobs="${CMAKE_BUILD_PARALLEL_LEVEL:-$child_jobs}"
    info "LLVM 可用内存约 ${memory_mb} MiB，CPU ${cpu_count}，编译并发 ${compile_jobs}，链接并发 ${link_jobs}，子构建并发 ${child_jobs}"
    # runtimes 子构建默认取较低的并发，也允许用户显式覆盖。
    run_build env CMAKE_BUILD_PARALLEL_LEVEL="$child_jobs" LLVM_LINK_JOBS="$link_jobs" \
        "$@" --jobs "$compile_jobs"
}

# GCC 配方：原生与交叉工具链。
run_build "$SCRIPT_DIR/build-native-gcc.sh" "$@" --gcc-ver 16.2.0 --binutils-ver 2.46.1 --work-dir "$WORK_DIR/native_gcc_162"
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l musl  --gcc-ver 16.2.0 --musl-ver 1.2.6  --binutils-ver 2.46.1 --work-dir "$WORK_DIR/gcc_162-musl_126"
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver git    --glibc-ver 2.43  --binutils-ver git    --work-dir "$WORK_DIR/gcc_dev-glibc_243"
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 16.2.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir "$WORK_DIR/gcc_162-glibc_243"
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 15.3.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir "$WORK_DIR/gcc_153-glibc_243"
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 14.4.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir "$WORK_DIR/gcc_144-glibc_243"
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 13.5.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir "$WORK_DIR/gcc_135-glibc_243"
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 12.5.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir "$WORK_DIR/gcc_125-glibc_243"
# ./build-toolchain-gcc-batch.sh "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 11.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --work-dir gcc_115-glibc_241
# ./build-toolchain-gcc-batch.sh "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 10.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --work-dir gcc_105-glibc_241
# ./build-toolchain-gcc-batch.sh "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 9.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --work-dir gcc_95-glibc_241


# LLVM 配方：原生与交叉工具链。
run_llvm_build "$SCRIPT_DIR/build-native-llvm.sh" "$@" --llvm-ver git:llvmorg-23.1.5 --work-dir "$WORK_DIR/native_llvm_2315"
run_llvm_build "$SCRIPT_DIR/build-toolchain-llvm-batch.sh" "$@" -a aarch64,loongarch64,riscv64,x86_64 --toolchain-dir "$WORK_DIR/gcc_162-glibc_243/cross-{ARCH}-linux-gnu" --llvm-ver git:llvmorg-23.1.5 --work-dir "$WORK_DIR/llvm_2315"
run_llvm_build "$SCRIPT_DIR/build-toolchain-llvm-batch.sh" "$@" -a aarch64,loongarch64,riscv64,x86_64 --toolchain-dir "$WORK_DIR/gcc_162-glibc_243/cross-{ARCH}-linux-gnu" --llvm-ver git:llvmorg-22.1.8 --work-dir "$WORK_DIR/llvm_2218"
run_llvm_build "$SCRIPT_DIR/build-toolchain-llvm-batch.sh" "$@" -a aarch64,loongarch64,riscv64,x86_64 --toolchain-dir "$WORK_DIR/gcc_162-glibc_243/cross-{ARCH}-linux-gnu" --llvm-ver git --work-dir "$WORK_DIR/llvm_dev"


# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 16.2.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_162-glibc_243
# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 15.3.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_153-glibc_243
# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 14.4.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_144-glibc_243
# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 13.5.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_135-glibc_243
# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 12.5.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_125-glibc_243
# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 11.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_115-glibc_241
# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 10.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_105-glibc_241
# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver  9.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_95-glibc_241


# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 16.2.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_162-glibc_241
# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 15.3.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_153-glibc_241
# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 14.4.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_144-glibc_241
# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 13.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_135-glibc_241
# ./build-toolchain-gcc.sh "$@" --arch x86_64 --libc glibc --gcc-ver 12.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_125-glibc_241


if [[ ${#failed_cmds[@]} -gt 0 ]]; then
    for cmd in "${failed_cmds[@]}"; do
        warn "构建套件失败 ($cmd)"
    done
    exit 1
fi
