#!/usr/bin/env bash
./build-all.sh -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l musl  --gcc-ver 16.1.0 --musl-ver 1.2.6  --binutils-ver 2.46.0 --work-dir gcc_161-musl_126
./build-all.sh -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver git    --glibc-ver 2.43  --binutils-ver 2.46.0 --work-dir gcc_latest-glibc243
./build-all.sh -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 16.1.0 --glibc-ver 2.43  --binutils-ver 2.46.0 --work-dir gcc_161-glibc_243
./build-all.sh -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 15.3.0 --glibc-ver 2.43  --binutils-ver 2.46.0 --work-dir gcc_153-glibc_243
./build-all.sh -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 15.2.0 --glibc-ver 2.43  --binutils-ver 2.46.0 --work-dir gcc_152-glibc_243
./build-all.sh -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 14.4.0 --glibc-ver 2.43  --binutils-ver 2.46.0 --work-dir gcc_144-glibc_243
./build-all.sh -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 13.4.0 --glibc-ver 2.43  --binutils-ver 2.46.0 --work-dir gcc_134-glibc_243
./build-all.sh -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 12.5.0 --glibc-ver 2.43  --binutils-ver 2.46.0 --work-dir gcc_125-glibc_243
# ./build-all.sh -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 11.5.0 --glibc-ver 2.41  --binutils-ver 2.46.0 --work-dir gcc_115-glibc_241
# ./build-all.sh -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 10.5.0 --glibc-ver 2.41  --binutils-ver 2.46.0 --work-dir gcc_105-glibc_241
# ./build-all.sh -a aarch64,loongarch64,riscv32,riscv64,x86_64 -l glibc --gcc-ver 9.5.0 --glibc-ver 2.41  --binutils-ver 2.46.0 --work-dir gcc_95-glibc_241

# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 16.1.0 --glibc-ver 2.43  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_161-glibc_243
# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 15.3.0 --glibc-ver 2.43  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_153-glibc_243
# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 14.4.0 --glibc-ver 2.43  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_144-glibc_243
# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 13.4.0 --glibc-ver 2.43  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_134-glibc_243
# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 12.5.0 --glibc-ver 2.43  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_125-glibc_243
# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 11.5.0 --glibc-ver 2.41  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_115-glibc_241
# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 10.5.0 --glibc-ver 2.41  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_105-glibc_241
# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver  9.5.0 --glibc-ver 2.41  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_95-glibc_241


# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 16.1.0 --glibc-ver 2.41  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_161-glibc_241
# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 15.3.0 --glibc-ver 2.41  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_153-glibc_241
# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 14.4.0 --glibc-ver 2.41  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_144-glibc_241
# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 13.4.0 --glibc-ver 2.41  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_134-glibc_241
# ./build-toolchain-generic.sh --arch x86_64 --libc glibc --gcc-ver 12.5.0 --glibc-ver 2.41  --binutils-ver 2.46.0 --download-dir ./x86_64/downloads/ --work-dir x86_64/gcc_125-glibc_241

./build-all-llvm.sh -a aarch64,loongarch64,riscv64,x86_64 --gcc-dir ./gcc_161-glibc_243/cross-{ARCH}-linux-gnu/ -v git:llvmorg-22.1.8:update --work-dir llvm_2218/

