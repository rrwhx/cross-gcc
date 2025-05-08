#!/bin/bash

# 默认支持的架构和 libc 列表
declare -a default_arch_list=("aarch64" "loongarch64" "riscv32" "riscv64" "i686" "x86_64" "mipsel" "mips64el" "mips" "mips64")
declare -a default_libc_list=("glibc" "musl")

# 初始化可配置的变量
declare -a arch_list=()
declare -a libc_list=()

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch|--architecture|-a)
            # 按逗号分割用户输入的架构列表
            IFS=',' read -ra arch_list <<< "$2"
            shift 2  # 跳過选项和值
            ;;
        --libc|--libc-type|-l)
            # 按逗号分割用户输入的 libc 列表
            IFS=',' read -ra libc_list <<< "$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  -a, --arch <架构列表>      指定架构（逗号分隔），默认: ${default_arch_list[*]}"
            echo "  -l, --libc <libc列表>      指定libc类型（逗号分隔），默认: ${default_libc_list[*]}"
            echo "  -h, --help                 显示帮助信息"
            exit 0
            ;;
        *)
            echo "错误：未知选项 '$1'，使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

# 如果用户未指定参数，使用默认值
[[ ${#arch_list[@]} -eq 0 ]] && arch_list=("${default_arch_list[@]}")
[[ ${#libc_list[@]} -eq 0 ]] && libc_list=("${default_libc_list[@]}")

# 打印配置信息
echo "==============================================="
echo "[CONFIG] 目标架构: ${arch_list[*]}"
echo "[CONFIG] 目标 libc: ${libc_list[*]}"
echo "==============================================="

# 遍历每个架构和 libc 组合
for arch in "${arch_list[@]}"; do
    for libc in "${libc_list[@]}"; do
        echo "======================================================================"
        echo "[INFO] 开始构建工具链：ARCH=$arch, LIBC=$libc"
        echo "======================================================================"

        if ./build-toolchain-generic.sh --arch "$arch" --libc "$libc"; then
            echo "[OK] 构建成功：ARCH=$arch, LIBC=$libc"
        else
            echo "[ERROR] 构建失败：ARCH=$arch, LIBC=$libc"
            # 可选：记录失败日志
            # echo "$arch-$libc" >> failed_builds.log
        fi
    done
done

echo "==============================================="
echo "[INFO] 全部构建任务已完成！"
echo "==============================================="