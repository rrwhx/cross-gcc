#!/bin/bash

# 定义所有支持的架构和 libc 组合
arch_list=("aarch64" "loongarch64" "riscv32" "riscv64" "i686" "x86_64" "mipsel" "mips64el")
libc_list=("glibc" "musl")

# 遍历每个架构
for arch in "${arch_list[@]}"; do
    # 遍历每个 libc 类型
    for libc in "${libc_list[@]}"; do
        echo "======================================================================"
        echo "[INFO] 开始构建工具链：ARCH=$arch, LIBC=$libc"
        echo "======================================================================"

        # 调用构建脚本
        if ./build-toolchain-generic.sh --arch "$arch" --libc "$libc"; then
            echo "[OK] 构建成功：ARCH=$arch, LIBC=$libc"
        else
            echo "[ERROR] 构建失败：ARCH=$arch, LIBC=$libc"
            # 可选：记录失败日志到文件
            # echo "$arch-$libc" >> failed_builds.log
        fi
    done
done

echo "==============================================="
echo "[INFO] 全部构建任务已完成！"
echo "==============================================="
