#!/usr/bin/env bash

# 检查 download_prerequisites 文件是否存在
if [ ! -f "./contrib/download_prerequisites" ]; then
    echo "错误: ./contrib/download_prerequisites 文件不存在！"
    exit 1
fi

# 检查压缩包完整性
check_archive_integrity() {
    local filename="$1"
    
    # 根据文件扩展名使用不同的验证方法
    case "$filename" in
        *.tar.gz|*.tgz)
            if ! gzip -t "$filename" 2>/dev/null; then
                echo "错误: gzip 完整性检查失败: $filename"
                return 1
            fi
            ;;
        *.tar.bz2|*.tbz2)
            if ! bzip2 -t "$filename" 2>/dev/null; then
                echo "错误: bzip2 完整性检查失败: $filename"
                return 1
            fi
            ;;
        *.tar.xz|*.txz)
            if ! xz -t "$filename" 2>/dev/null; then
                echo "错误: xz 完整性检查失败: $filename"
                return 1
            fi
            ;;
        *)
            # 对于未知格式，尝试列出内容
            if ! tar -tf "$filename" >/dev/null 2>&1; then
                echo "错误: 无法验证压缩包完整性: $filename"
                return 1
            fi
            ;;
    esac
    
    return 0
}

# 检查文件完整性
check_file_integrity() {
    local filename="$1"
    local min_size=10240  # 10KB作为最小有效文件大小
    
    # 检查文件是否存在
    if [ ! -f "$filename" ]; then
        return 1
    fi
   
    # 检查压缩包完整性
    if ! check_archive_integrity "$filename"; then
        return 1
    fi
    
    return 0
}

# 下载文件函数
download_file() {
    local url="$1"
    local filename="$2"
    local max_retries=2
    
    # 检查文件是否存在且有效
    if check_file_integrity "$filename"; then
        echo "文件已验证: $filename (跳过下载)"
        return 0
    fi
    
    for ((attempt=1; attempt<=max_retries; attempt++)); do
        echo "正在下载 [$attempt/$max_retries]: $url"
        
        # 使用wget下载
        if wget --no-check-certificate --quiet --show-progress -O "$filename" "$url"; then
            # 下载后验证完整性
            if check_file_integrity "$filename"; then
                echo "下载成功: $filename"
                return 0
            else
                echo "下载文件不完整: $filename"
            fi
        else
            echo "下载失败: $filename"
        fi
        
        # 尝试备用源（仅对isl）
        if [[ "$filename" == *"isl"* && $attempt -eq 1 ]]; then
            echo "尝试备用源: https://libisl.sourceforge.io/$filename"
            url="https://libisl.sourceforge.io/$filename"
            continue
        fi
        
        # 删除可能损坏的文件
        rm -f "$filename"
        sleep 1  # 重试前等待
    done
    
    echo "错误: 无法下载有效文件: $filename"
    return 1
}

    gmp_file=$(grep "^gmp="     ./contrib/download_prerequisites | grep "gmp-.*tar.bz2" -o)
   mpfr_file=$(grep "^mpfr="    ./contrib/download_prerequisites | grep "mpfr-.*tar.bz2" -o)
    mpc_file=$(grep "^mpc="     ./contrib/download_prerequisites | grep "mpc-.*tar.gz" -o)
    isl_file=$(grep "^isl="     ./contrib/download_prerequisites | grep "isl-.*tar.bz2" -o)
gettext_file=$(grep "^gettext=" ./contrib/download_prerequisites | grep "gettext-.*tar.gz" -o)

# 下载所有文件
download_file "https://mirrors.tuna.tsinghua.edu.cn/gnu/gmp/${gmp_file}" "$gmp_file" || exit 1
download_file "https://mirrors.tuna.tsinghua.edu.cn/gnu/mpfr/${mpfr_file}" "$mpfr_file" || exit 1
download_file "https://mirrors.tuna.tsinghua.edu.cn/gnu/mpc/${mpc_file}" "$mpc_file" || exit 1
download_file "https://mirrors.tuna.tsinghua.edu.cn/gnu/gettext/${gettext_file}" "$gettext_file" || exit 1
download_file "https://libisl.sourceforge.io/${isl_file}" "$isl_file" || exit 1

# 运行原始脚本（跳过下载）
echo "运行 ./contrib/download_prerequisites (跳过下载)..."
./contrib/download_prerequisites

echo "所有依赖已准备就绪且通过完整性检查！"
