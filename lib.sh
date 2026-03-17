#!/usr/bin/env bash
# Common library for cross compiler build scripts

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # 重置颜色

# 输出函数
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
step()  { echo -e "${GREEN}[STEP]${NC} $*"; }
ok()    { echo -e "${BLUE}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# 捕获错误并提示
setup_error_trap() {
    trap 'error "错误发生在脚本第 ${LINENO} 行，详细信息请查看日志。"; exit 1' ERR
}

# 下载函数：若文件不存在则使用 curl 或 wget 下载 (curl 优先级更高)
download() {
    local url="$1"
    local dest="$2"
    if [[ -f "$dest" ]]; then
        info "已存在: $dest，跳过下载"
    else
        info "下载 $url ..."
        if command -v curl > /dev/null; then
            curl -fSL --insecure --progress-bar -o "$dest" "$url" || error "下载失败: $url"
        elif command -v wget > /dev/null; then
            wget -nc -q --show-progress -O "$dest" "$url" || error "下载失败: $url"
        else
            error "未安装 curl 或 wget，无法下载文件"
            exit 1
        fi
    fi
}

# 构建函数
build_step() {
    local name=$1
    local log_dir=$2
    mkdir -p "$log_dir"
    shift 2

    step "执行: $*"
    if "$@" 2>&1 | cat > "${log_dir}/${name}.log"; then
        ok "${name} 成功"
    else
        error "${name} 失败，详见 ${log_dir}/${name}.log"
    fi
}

# 清理构建和日志目录
clean_build_dir() {
    local build_dir="$1"
    local log_dir="$2"
    local clean_flag="$3"

    if [[ "$clean_flag" == true ]]; then
        step "=== 清理构建目录和日志目录 ==="
        if [[ -d "$build_dir" ]]; then
            info "删除构建目录和日志目录: $build_dir $log_dir"
            rm -rf "$build_dir"
            rm -rf "$log_dir"
            ok "构建目录和日志目录清理完成"
        else
            warn "构建目录和日志目录不存在，跳过清理"
        fi
    fi
}

# 打包工具链
archive_toolchain() {
    local prefix_dir="$1"
    local archive_flag="$2"

    if [[ "$archive_flag" == true ]]; then
        step "=== 打包工具链 ==="
        if [[ -d "$prefix_dir" ]]; then
            # 获取工具链目录的父目录和目录名
            local parent_dir="$(dirname "$prefix_dir")"
            local toolchain_name="$(basename "$prefix_dir")"
            local archive_name="$parent_dir/${toolchain_name}.tar.xz"

            info "打包工具链到: $archive_name"

            # 使用 tar 的 -C 选项指定工作目录，避免 cd
            if tar -cJf "$archive_name" -C "$parent_dir" "$toolchain_name" 2>/dev/null; then
                ok "工具链打包完成: $archive_name"

                # 删除原目录
                info "删除原工具链目录: $prefix_dir"
                rm -rf "$prefix_dir"
                ok "原目录删除完成"

                echo -e "打包文件: ${GREEN}$archive_name${NC}"
            else
                error "打包失败"
            fi
        else
            warn "工具链目录不存在，跳过打包"
        fi
    fi
}
