#!/bin/bash

# 默认支持的架构和 libc 列表
declare -a default_arch_list=("aarch64" "loongarch64" "riscv32" "riscv64" "i686" "x86_64" "mipsel" "mips64el" "mips" "mips64")
declare -a default_libc_list=("glibc" "musl")

# 可配置变量
declare -a arch_list=()
declare -a libc_list=()
declare -A task_status  # 记录任务状态（pid -> "arch:libc"）
declare -a pids=()      # 记录所有后台任务PID

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch|-a)
            IFS=',' read -ra arch_list <<< "$2"
            shift 2
            ;;
        --libc|-l)
            IFS=',' read -ra libc_list <<< "$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  -a, --arch <arch_list>   Architectures (comma-separated), default: ${default_arch_list[*]}"
            echo "  -l, --libc <libc_list>   Libc types (comma-separated), default: ${default_libc_list[*]}"
            echo "  -h, --help                Show help"
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'"
            exit 1
            ;;
    esac
done

# 设置默认值
[[ ${#arch_list[@]} -eq 0 ]] && arch_list=("${default_arch_list[@]}")
[[ ${#libc_list[@]} -eq 0 ]] && libc_list=("${default_libc_list[@]}")

# 打印配置
echo "==============================================="
echo "[CONFIG] 目标架构: ${arch_list[*]}"
echo "[CONFIG] 目标 libc: ${libc_list[*]}"
echo "==============================================="

# 启动所有构建任务（后台运行）
for arch in "${arch_list[@]}"; do
    for libc in "${libc_list[@]}"; do
        echo "[INFO] 启动后台任务：ARCH=$arch, LIBC=$libc"
        # 启动任务并记录PID
        ./build-toolchain-generic.sh --arch "$arch" --libc "$libc" > "build_${arch}_${libc}.log" 2>&1 &
        pid=$!
        pids+=("$pid")
        task_status["$pid"]="$arch:$libc"  # 记录任务参数
    done
done

# 等待所有任务完成并统计结果
success=0
fail=0
for pid in "${pids[@]}"; do
    if wait "$pid"; then
        arch_libc="${task_status[$pid]}"
        arch="${arch_libc%:*}"
        libc="${arch_libc#*:}"
        echo "[OK] 构建成功：ARCH=$arch, LIBC=$libc"
        ((success++))
    else
        arch_libc="${task_status[$pid]}"
        arch="${arch_libc%:*}"
        libc="${arch_libc#*:}"
        echo "[ERROR] 构建失败：ARCH=$arch, LIBC=$libc"
        ((fail++))
    fi
done

# 输出总结报告
echo "==============================================="
echo "[RESULT] 全部构建任务完成"
echo "-----------------------------------------------"
echo "成功: $success"
echo "失败: $fail"
echo "日志文件: build_<arch>_<libc>.log"
echo "==============================================="

exit $((fail > 0 ? 1 : 0))  # 若有失败则返回非零状态码