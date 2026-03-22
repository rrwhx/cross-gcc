#!/bin/bash -x

LLVM_DIR=/u/cpu-arc/lxy497151/llvm-release/LLVM-21.1.8-Linux-X64/

ARCH=${1:-riscv64}
#CROSS_FLAGS="--sysroot=/u/cpu-arc/lxy497151/cross-gcc/cross-${ARCH}-linux-gnu/${ARCH}-linux-gnu --gcc-toolchain=/u/cpu-arc/lxy497151/cross-gcc/cross-${ARCH}-linux-gnu"

ROOTDIR=`pwd`
BUILD_DIR=${ROOTDIR}/build_llvm_${ARCH}_by_clang
INSTALLDIR=${ROOTDIR}/install_llvm_${ARCH}_by_clang

cd $ROOTDIR
#rm -rf ${BUILD_DIR}
mkdir ${BUILD_DIR}
cd ${BUILD_DIR}
 CC=${LLVM_DIR}/bin/clang \
CXX=${LLVM_DIR}/bin/clang++ \
 FC=${LLVM_DIR}/bin/flang \
cmake \
  -G Ninja \
  ../../llvm-project-llvmorg-21.1.8/llvm/ \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$INSTALLDIR \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DLLVM_TARGETS_TO_BUILD="AArch64;LoongArch;RISCV;X86" \
  -DLLVM_ENABLE_PROJECTS="lld;clang;flang" \
  -DLLVM_ENABLE_RUNTIMES="flang-rt;compiler-rt" \
  -DLLVM_DEFAULT_TARGET_TRIPLE=${ARCH}-unknown-linux-gnu \
  -DCMAKE_C_FLAGS="${CROSS_FLAGS}" \
  -DCMAKE_CXX_FLAGS="${CROSS_FLAGS}" \
  -DCMAKE_Fortran_FLAGS="${CROSS_FLAGS}" \
  -DLLVM_ENABLE_ZLIB=ON

ninja
ninja install
