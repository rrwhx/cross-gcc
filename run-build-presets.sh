#!/usr/bin/env bash
# 批量构建多版本 GCC/LLVM 工具链的配方脚本
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
preset_threads="${THREADS:-}"
source "$SCRIPT_DIR/lib.sh"
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

# LLVM 自动并发按编译 4 GiB/任务、链接 10 GiB/任务估算，手动设置优先。
run_llvm_build() {
    local memory_mb="" cpu_count compile_jobs link_jobs child_jobs
    local requested_compile="$preset_threads" requested_link="${LLVM_LINK_JOBS:-}" previous="" arg
    for arg in "$@"; do
        case "$previous" in
            -j|--jobs)    requested_compile="$arg";;
            --link-jobs) requested_link="$arg";;
        esac
        previous="$arg"
    done
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
    compile_jobs=$((memory_mb / 4096))
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
    run_build env CMAKE_BUILD_PARALLEL_LEVEL="$child_jobs" \
        "$@" --jobs "$compile_jobs" --link-jobs "$link_jobs"
}

run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l musl  --gcc-ver 16.2.0 --musl-ver 1.2.6  --binutils-ver 2.46.1 --work-dir gcc_162-musl_126
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver git    --glibc-ver 2.43  --binutils-ver git    --work-dir gcc_dev-glibc_243
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 16.2.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir gcc_162-glibc_243
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 15.3.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir gcc_153-glibc_243
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 14.4.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir gcc_144-glibc_243
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 13.5.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir gcc_135-glibc_243
run_build "$SCRIPT_DIR/build-toolchain-gcc-batch.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 12.5.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir gcc_125-glibc_243
# ./build-toolchain-gcc-batch.sh "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 11.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --work-dir gcc_115-glibc_241
# ./build-toolchain-gcc-batch.sh "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 10.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --work-dir gcc_105-glibc_241
# ./build-toolchain-gcc-batch.sh "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 9.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --work-dir gcc_95-glibc_241


run_llvm_build "$SCRIPT_DIR/build-toolchain-llvm-batch.sh" "$@" -a aarch64,loongarch64,riscv64,x86_64 --toolchain-dir ./gcc_162-glibc_243/cross-{ARCH}-linux-gnu/ --llvm-ver git:llvmorg-23.1.5 --work-dir llvm_2315/
run_llvm_build "$SCRIPT_DIR/build-toolchain-llvm-batch.sh" "$@" -a aarch64,loongarch64,riscv64,x86_64 --toolchain-dir ./gcc_162-glibc_243/cross-{ARCH}-linux-gnu/ --llvm-ver git:llvmorg-22.1.8 --work-dir llvm_2218/
run_llvm_build "$SCRIPT_DIR/build-toolchain-llvm-batch.sh" "$@" -a aarch64,loongarch64,riscv64,x86_64 --toolchain-dir ./gcc_162-glibc_243/cross-{ARCH}-linux-gnu/ --llvm-ver git --work-dir llvm_dev/


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
