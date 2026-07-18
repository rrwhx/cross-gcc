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

"$SCRIPT_DIR/build-all.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver git:update    --glibc-ver 2.43  --binutils-ver git:update    --work-dir gcc_dev-glibc243
"$SCRIPT_DIR/build-all.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l musl  --gcc-ver 16.1.0 --musl-ver 1.2.6  --binutils-ver 2.46.1 --work-dir gcc_161-musl_126
"$SCRIPT_DIR/build-all.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 16.1.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir gcc_161-glibc_243
"$SCRIPT_DIR/build-all.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 15.3.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir gcc_153-glibc_243
"$SCRIPT_DIR/build-all.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 14.4.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir gcc_144-glibc_243
"$SCRIPT_DIR/build-all.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 13.4.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir gcc_134-glibc_243
"$SCRIPT_DIR/build-all.sh" "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 12.5.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --work-dir gcc_125-glibc_243
# ./build-all.sh "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 11.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --work-dir gcc_115-glibc_241
# ./build-all.sh "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 10.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --work-dir gcc_105-glibc_241
# ./build-all.sh "$@" -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 9.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --work-dir gcc_95-glibc_241


"$SCRIPT_DIR/build-all-llvm.sh" "$@" -a aarch64,loongarch64,riscv64,x86_64 --gcc-dir ./gcc_161-glibc_243/cross-{ARCH}-linux-gnu/ -v git:llvmorg-22.1.8:update --work-dir llvm_2218/
"$SCRIPT_DIR/build-all-llvm.sh" "$@" -a aarch64,loongarch64,riscv64,x86_64 --gcc-dir ./gcc_161-glibc_243/cross-{ARCH}-linux-gnu/ -v git:update --work-dir llvm_dev/


# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 16.1.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_161-glibc_243
# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 15.3.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_153-glibc_243
# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 14.4.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_144-glibc_243
# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 13.4.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_134-glibc_243
# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 12.5.0 --glibc-ver 2.43  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_125-glibc_243
# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 11.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_115-glibc_241
# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 10.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_105-glibc_241
# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver  9.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_95-glibc_241


# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 16.1.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_161-glibc_241
# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 15.3.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_153-glibc_241
# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 14.4.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_144-glibc_241
# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 13.4.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_134-glibc_241
# ./build-toolchain-generic.sh "$@" --arch x86_64 --libc glibc --gcc-ver 12.5.0 --glibc-ver 2.41  --binutils-ver 2.46.1 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_125-glibc_241


