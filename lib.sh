#!/usr/bin/env bash
# Common library for cross compiler build scripts

# 颜色定义（非终端时禁用颜色）
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' BLUE='' YELLOW='' CYAN='' NC=''
fi

# 输出函数
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
step()  { echo -e "${GREEN}[STEP]${NC} $*"; }
ok()    { echo -e "${BLUE}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }

# 跨平台 CPU 线程数检测 (可被各脚本直接使用)
THREADS=${THREADS:-$(nproc 2>/dev/null || sysctl -n hw.logicalcpu_max 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}

# 默认下载镜像源 (可被环境变量或各脚本 --mirror 覆盖)
# 备选: mirrors.tuna.tsinghua.edu.cn, mirrors.bfsu.edu.cn, mirror.nju.edu.cn
MIRROR="${MIRROR:-mirrors.bfsu.edu.cn}"

# 组件版本默认值集中在 versions.env, 那里用 ${VAR:-默认值} 写法, 所以直接 source 即可:
# 已设置的环境变量原样保留, 未设置或为空则取默认值。
# 优先级: 命令行参数 > 环境变量 > versions.env
# (各脚本在 source lib.sh 之后才解析命令行, 那里的直接赋值会覆盖此处结果)
_versions_env="$(dirname "${BASH_SOURCE[0]}")/versions.env"
# 缺文件就直接报错: 否则版本变为空值, 会在后面以难懂的下载 404 形式爆出来
[[ -f "$_versions_env" ]] || error "缺少版本配置文件: $_versions_env"
# shellcheck source=versions.env
source "$_versions_env"
unset _versions_env

# 捕获错误并提示
setup_error_trap() {
    trap 'error "错误发生在脚本第 ${LINENO} 行，详细信息请查看日志。"; exit 1' ERR
}

# 下载函数：先下载到同目录临时文件，成功后原子替换 (curl 优先级更高)
download() {
    local url="$1"
    local dest="$2"
    if [[ -f "$dest" ]]; then
        info "已存在: ${dest}，跳过下载"
    else
        info "下载 $url ..."
        [[ ! -d "$dest" ]] || error "下载目标是目录: $dest"
        local temp_file
        temp_file="$(mktemp "${dest}.part.XXXXXX")" || error "无法创建下载临时文件: $dest"
        if command -v curl > /dev/null; then
            if ! curl -fSL --insecure --progress-bar -o "$temp_file" "$url"; then
                rm -f -- "$temp_file"
                error "下载失败: $url"
            fi
        elif command -v wget > /dev/null; then
            if ! wget -q --show-progress -O "$temp_file" "$url"; then
                rm -f -- "$temp_file"
                error "下载失败: $url"
            fi
        else
            rm -f -- "$temp_file"
            error "未安装 curl 或 wget，无法下载文件"
        fi
        if ! mv -f -- "$temp_file" "$dest"; then
            rm -f -- "$temp_file"
            error "无法保存下载文件: $dest"
        fi
    fi
}

# 校验源码引用：分支、标签、显式 refs/... 或完整提交 SHA。
git_validate_ref() {
    local ref="$1"
    [[ -z "$ref" || "$ref" == HEAD ]] && return 0
    [[ "$ref" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] && return 0
    [[ "$ref" != -* ]] || error "无效的 Git 引用: $ref"
    git check-ref-format --allow-onelevel "$ref" >/dev/null 2>&1 \
        || error "无效的 Git 引用: $ref（提交请使用完整 SHA）"
}

# Git 版本参数解析：解析 "git[:REF][:update]" 格式。
# 输出变量: _GIT_REF, _GIT_UPDATE
parse_git_ver() {
    local ver="${1:-}"
    _GIT_REF=""
    _GIT_UPDATE=false
    case "$ver" in
        git) return 0 ;;
        git:update) _GIT_UPDATE=true; return 0 ;;
        git:*) _GIT_REF="${ver#git:}" ;;
        *) error "无效的 Git 版本参数: $ver" ;;
    esac
    if [[ "$_GIT_REF" == *:update ]]; then
        _GIT_REF="${_GIT_REF%:update}"
        _GIT_UPDATE=true
    fi
    [[ -n "$_GIT_REF" ]] || error "Git 引用不能为空: $ver"
    command -v git >/dev/null 2>&1 || error "git 未安装，无法校验源码引用"
    git_validate_ref "$_GIT_REF"
}

# 把远端引用映射到本仓库缓存，分支与标签使用独立命名空间。
git_source_cache_ref() {
    case "$1" in
        refs/heads/*) printf '%s\n' "refs/remotes/origin/${1#refs/heads/}" ;;
        refs/tags/*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "refs/cross-gcc/cache/$1" ;;
    esac
}

# 解析请求的引用。输出 _GIT_SOURCE_REF、_GIT_SOURCE_OID、_GIT_SOURCE_FETCH。
# 同一引用的冻结快照由 git_clone 的状态记录处理；切换引用时显式解析其身份。
git_resolve_source_ref() {
    local repo="$1" url="$2" requested="$3" update="$4"
    local cached_ref="" remote_lines oid name branch="" tag=""
    _GIT_SOURCE_REF="$requested"
    _GIT_SOURCE_OID=""
    _GIT_SOURCE_FETCH=true

    if [[ "$requested" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
        _GIT_SOURCE_REF="$(printf '%s' "$requested" | tr 'A-F' 'a-f')"
        if [[ -e "$repo/.git" ]] && \
            [[ "$(git -C "$repo" cat-file -t "$_GIT_SOURCE_REF" 2>/dev/null || true)" == commit ]]; then
            _GIT_SOURCE_OID="$_GIT_SOURCE_REF"
            _GIT_SOURCE_FETCH=false
        else
            _GIT_SOURCE_OID="$_GIT_SOURCE_REF"
        fi
        return 0
    fi

    # 显式引用可在离线状态下切回已缓存版本。
    if [[ "$update" == false && "$requested" == refs/* && -e "$repo/.git" ]]; then
        cached_ref="$(git_source_cache_ref "$requested")"
        if _GIT_SOURCE_OID="$(git -C "$repo" rev-parse --verify "${cached_ref}^{commit}" 2>/dev/null)"; then
            _GIT_SOURCE_FETCH=false
            return 0
        fi
    fi

    if [[ "$requested" == HEAD ]]; then
        remote_lines="$(git ls-remote --symref -- "$url" HEAD)" || error "无法查询远端默认分支"
        while IFS=$'\t' read -r oid name; do
            [[ "$name" == HEAD ]] || continue
            if [[ "$oid" == 'ref: '* ]]; then
                _GIT_SOURCE_REF="${oid#ref: }"
            else
                _GIT_SOURCE_OID="$oid"
            fi
        done <<< "$remote_lines"
    else
        if [[ "$requested" == refs/* ]]; then
            remote_lines="$(git ls-remote --refs -- "$url" "$requested")" || error "无法查询 Git 引用: $requested"
        else
            remote_lines="$(git ls-remote --refs -- "$url" "refs/heads/$requested" "refs/tags/$requested")" \
                || error "无法查询 Git 引用: $requested"
        fi
        while IFS=$'\t' read -r oid name; do
            if [[ "$requested" == refs/* ]]; then
                if [[ "$name" == "$requested" ]]; then _GIT_SOURCE_OID="$oid"; fi
            elif [[ "$name" == "refs/heads/$requested" ]]; then
                branch="$oid"
            elif [[ "$name" == "refs/tags/$requested" ]]; then
                tag="$oid"
            fi
        done <<< "$remote_lines"
        if [[ "$requested" != refs/* ]]; then
            [[ -z "$branch" || -z "$tag" ]] \
                || error "分支和标签同名: $requested，请使用 refs/heads/$requested 或 refs/tags/$requested"
            if [[ -n "$branch" ]]; then
                _GIT_SOURCE_REF="refs/heads/$requested"
                _GIT_SOURCE_OID="$branch"
            elif [[ -n "$tag" ]]; then
                _GIT_SOURCE_REF="refs/tags/$requested"
                _GIT_SOURCE_OID="$tag"
            fi
        fi
    fi
    [[ "$_GIT_SOURCE_OID" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
        || error "远端 Git 引用不存在或仓库为空: $requested"
    git_validate_ref "$_GIT_SOURCE_REF"

    # 不要求更新时，已有的命名引用保持冻结；缺失的引用才抓取。
    if [[ "$update" == false && -e "$repo/.git" ]]; then
        cached_ref="$(git_source_cache_ref "$_GIT_SOURCE_REF")"
        if _GIT_SOURCE_OID="$(git -C "$repo" rev-parse --verify "${cached_ref}^{commit}" 2>/dev/null)"; then
            _GIT_SOURCE_FETCH=false
            return 0
        fi
        # 抓取前仍需远端 OID 来确定对象格式。
        _GIT_SOURCE_OID="$(printf '%s\n' "$remote_lines" | awk '$1 !~ /^ref:/ && $2 != "" {print $1; exit}')"
    fi
}

# 获取 Git 源码并检验缓存身份；以 detached HEAD 构建可复现快照。
# 参数: url dest [depth] [update] [ref] [recursive]
# 子 shell 隔离 Git 环境和清理 trap，避免影响调用方。
git_clone() (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    local url="${1:-}" dest="${2:-}" depth="${3:-1}" update="${4:-false}" ref="${5:-}" recursive="${6:-false}"
    [[ -n "$url" && "$url" != -* && -n "$dest" && "$dest" != -* ]] || error "Git 地址和源码目录不能为空或以选项开头"
    [[ "$depth" =~ ^[1-9][0-9]*$ ]] || error "Git 浅克隆深度必须为正整数: $depth"
    [[ "$update" == true || "$update" == false ]] || error "无效的 Git update 参数: $update"
    [[ "$recursive" == true || "$recursive" == false ]] || error "无效的 Git recursive 参数: $recursive"
    command -v git >/dev/null 2>&1 || error "git 未安装，无法获取源码"
    git_validate_ref "$ref"

    local parent base lock_dir temp_repo="" temp_state="" work_repo current="" commit="" state_file
    local requested="${ref:-HEAD}" recorded_ref="" recorded_commit="" new_repo=false cached=false
    parent="$(dirname "$dest")"
    base="$(basename "$dest")"
    mkdir -p "$parent" || error "无法创建源码父目录: $parent"
    parent="$(cd "$parent" && pwd -P)" || error "无法解析源码父目录"
    dest="$parent/$base"
    # 符号链接别名也使用实际工作树路径的同一把锁。
    if [[ -d "$dest" ]]; then
        dest="$(cd "$dest" && pwd -P)" || error "无法解析源码目录: $dest"
        parent="$(dirname "$dest")"
        base="$(basename "$dest")"
    fi
    lock_dir="${dest}.git-lock"
    mkdir "$lock_dir" 2>/dev/null \
        || error "源码目录正在使用或遗留锁尚未清理: $lock_dir"
    git_source_cleanup() {
        [[ -z "$temp_state" ]] || rm -f -- "$temp_state"
        if [[ -n "$temp_repo" ]]; then
            assert_safe_to_delete "$temp_repo"
            rm -rf -- "$temp_repo"
        fi
        rmdir "$lock_dir" 2>/dev/null || true
    }
    trap git_source_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    if [[ -e "$dest" || -L "$dest" ]]; then
        [[ -d "$dest" && -e "$dest/.git" ]] || error "源码缓存不是 Git 工作树: $dest"
        local top origin
        top="$(git -C "$dest" rev-parse --show-toplevel 2>/dev/null)" || error "无效的 Git 源码缓存: $dest"
        [[ "$(cd "$dest" && pwd -P)" == "$(cd "$top" && pwd -P)" ]] || error "源码目录必须是 Git 工作树根目录: $dest"
        origin="$(git -C "$dest" config --get remote.origin.url)" || error "源码缓存缺少 origin: $dest"
        [[ "$origin" == "$url" ]] || error "源码缓存的 origin 与请求地址不一致: $dest，请使用独立源码目录"
        work_repo="$dest"
        current="$(git -C "$work_repo" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
            || error "源码缓存没有有效提交: $dest"
        state_file="$(git -C "$work_repo" rev-parse --absolute-git-dir)/cross-gcc-source"
        [[ ! -e "$state_file" || -f "$state_file" ]] || error "源码缓存记录不是普通文件: $state_file"
        if [[ "$update" == false && -f "$state_file" ]]; then
            { IFS= read -r recorded_ref && IFS= read -r recorded_commit; } < "$state_file" \
                || error "源码缓存记录损坏: $dest，请使用更新模式重新获取"
            [[ "$recorded_commit" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] \
                || error "源码缓存提交记录无效: $dest"
            [[ -n "$recorded_ref" ]] || error "源码缓存引用记录为空: $dest"
            git_validate_ref "$recorded_ref"
            if [[ "$recorded_ref" == "$requested" ]]; then
                [[ "$current" == "$recorded_commit" ]] || error "源码 HEAD 与缓存记录不一致: $dest，请显式更新或使用独立源码目录"
                cached=true
                commit="$current"
            fi
        fi
    else
        new_repo=true
        temp_repo="$(mktemp -d "$parent/.${base}.git.XXXXXX")" || error "无法创建 Git 源码临时目录"
        work_repo="$temp_repo"
    fi

    if [[ "$cached" != true ]]; then
        git_resolve_source_ref "$work_repo" "$url" "$requested" "$update"
        if [[ "$new_repo" == true ]]; then
            local object_format=sha1
            [[ ${#_GIT_SOURCE_OID} -eq 64 ]] && object_format=sha256
            git init --quiet --object-format="$object_format" "$work_repo" || error "初始化源码缓存失败"
            git -C "$work_repo" remote add origin "$url" || error "设置源码 origin 失败"
        fi
        local cache_ref
        cache_ref="$(git_source_cache_ref "$_GIT_SOURCE_REF")"
        if [[ "$_GIT_SOURCE_FETCH" == true ]]; then
            info "获取 Git 引用: $requested ($dest)"
            git -C "$work_repo" fetch --depth "$depth" --no-tags -- origin "+${_GIT_SOURCE_REF}:${cache_ref}" \
                || error "获取 Git 引用失败: $requested（完整 SHA 需由远端允许抓取）"
        fi
        if [[ "$requested" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
            commit="$(git -C "$work_repo" rev-parse --verify "${_GIT_SOURCE_REF}^{commit}" 2>/dev/null)" || error "SHA 不是有效提交: $requested"
            [[ "$commit" == "$_GIT_SOURCE_REF" ]] || error "完整 SHA 必须直接指向提交: $requested"
        else
            commit="$(git -C "$work_repo" rev-parse --verify "${cache_ref}^{commit}" 2>/dev/null)" || error "Git 引用没有指向提交: $requested"
        fi
        if [[ "$current" != "$commit" ]]; then
            git -C "$work_repo" diff --quiet --ignore-submodules=untracked && \
                git -C "$work_repo" diff --cached --quiet --ignore-submodules=untracked \
                || error "源码有已跟踪的本地修改，拒绝切换提交: $dest"
            git -C "$work_repo" checkout --detach "$commit" || error "切换源码提交失败: $dest（请检查未跟踪文件冲突）"
        fi
        if [[ "$requested" == HEAD && "$_GIT_SOURCE_REF" == refs/heads/* ]]; then
            git -C "$work_repo" symbolic-ref refs/remotes/origin/HEAD "$cache_ref" || error "更新远端默认分支记录失败"
        fi
    fi

    if [[ "$recursive" == true ]]; then
        git -C "$work_repo" submodule sync --recursive && \
            git -C "$work_repo" submodule update --init --recursive --checkout --depth "$depth" \
            || error "同步 Git 子模块失败: $dest"
    fi
    if [[ "$cached" != true ]]; then
        state_file="$(git -C "$work_repo" rev-parse --absolute-git-dir)/cross-gcc-source"
        temp_state="$(mktemp "${state_file}.XXXXXX")" || error "无法记录源码提交"
        printf '%s\n%s\n' "$requested" "$commit" > "$temp_state" || error "写入源码提交记录失败"
        mv -f -- "$temp_state" "$state_file" || error "保存源码提交记录失败"
        temp_state=""
    fi
    if [[ "$new_repo" == true ]]; then
        [[ ! -e "$dest" && ! -L "$dest" ]] || error "源码目标目录已被创建: $dest"
        mv -- "$temp_repo" "$dest" || error "保存 Git 源码缓存失败: $dest"
        temp_repo=""
    fi
    info "Git 源码: $requested -> $commit ($dest)"
)

# 获取源码：git 版本克隆，release 版本追加到全局 dl_files 下载列表
# 参数: ver src_dir git_url tar_url
fetch_source() {
    local ver=$1
    local src_dir=$2
    local git_url=$3
    local tar_url=$4

    if [[ "$ver" == git* ]]; then
        parse_git_ver "$ver"
        git_clone "$git_url" "$src_dir" 1 "$_GIT_UPDATE" "$_GIT_REF"
    else
        dl_files+=("$tar_url")
    fi
}

# 下载 dl_files 中的所有归档
# 参数: download_dir
download_dl_files() {
    local download_dir="$1"
    local url filename
    for url in "${dl_files[@]}"; do
        filename=$(basename "${url}")
        download "$url" "$download_dir/$filename"
    done
}

# 解压 dl_files 中的所有归档 (解压目录名为去掉 .tar.* 后缀的文件名)
# 参数: download_dir src_dir
extract_dl_files() {
    local download_dir="$1"
    local src_dir="$2"
    local url filename srcdir
    for url in "${dl_files[@]}"; do
        filename=$(basename "${url}")
        info "解压: ${filename}"
        srcdir="$src_dir/${filename%.tar*}"
        if [[ -d "$srcdir" ]]; then
            info "$srcdir 已解压"
        else
            tar -xf "$download_dir/$filename" -C "$src_dir" || error "解压失败"
        fi
    done
}

# 将目录变量规范化为绝对路径并创建 (先 mkdir 保证 realpath 不会因路径不存在而失败)
# 参数: 目录变量名列表 (通过间接引用读写调用方变量)
canonicalize_dirs() {
    local var
    for var in "$@"; do
        mkdir -p "${!var}"
        printf -v "$var" '%s' "$(realpath "${!var}")"
    done
}

# 打印构建日志中的错误上下文
print_build_error_context() {
    local log_file="$1"
    local error_lines
    # 未匹配或 head 截断导致的 SIGPIPE 不应中断后续错误报告。
    error_lines=$(grep -n -C2 -E "fatal error|: error:|undefined reference to|ld: error:|collect2: error:|CMake Error|Traceback \(most recent call last\):|ModuleNotFoundError|No such file or directory" "$log_file" | head -50) || true
    if [[ -n "$error_lines" ]]; then
        warn "--- 关键错误行 ---"
        echo "$error_lines" >&2
    fi
    warn "--- 日志末尾 ---"
    tail -20 "$log_file" >&2 || true
    warn "---"
}

# 将命令渲染为可直接粘贴到终端复现的一行
# 只给确实需要的参数加引号 (含空格/引号/通配符等), 否则原样输出以保持可读
format_cmd() {
    local out="" a
    for a in "$@"; do
        if [[ -n "$a" && "$a" != *[!A-Za-z0-9_./=:,+-]* ]]; then
            out+="$a "
        else
            out+="$(printf '%q' "$a") "
        fi
    done
    printf '%s' "${out% }"
}

# 构建函数
build_step() {
    local name=$1
    local log_dir=$2
    mkdir -p "$log_dir"
    shift 2

    local log_file="${log_dir}/${name}.log"
    # 打印成可直接粘贴复现的形式。cwd 必须带上: 多数调用方会先 cd 到构建目录,
    # 而 cmake/configure 就地生成产物, 少了 cwd 这条命令没法复现。
    local repro="(cd $(format_cmd "$PWD") && $(format_cmd "$@"))"
    step "执行: $repro"
    if "$@" 2>&1 | cat > "$log_file"; then
        ok "${name} 成功"
    else
        print_build_error_context "$log_file"
        # 失败点距离上面那行"执行:"可能隔着上千行输出, 这里再打印一次
        warn "复现: $repro"
        error "${name} 失败，详见 $log_file"
    fi
}

# 危险路径护栏：校验目标目录可安全执行 rm -rf
# 拒绝空值、根目录、家目录及常见共享/系统目录，避免 --fresh 误删无关文件
# 用法: assert_safe_to_delete "$dir"
assert_safe_to_delete() {
    local target="$1"
    if [[ -z "$target" ]]; then
        error "拒绝删除空路径"
    fi

    local abs
    if command -v realpath >/dev/null 2>&1; then
        abs="$(realpath -m "$target")"
    else
        abs="$target"
    fi
    # 去除末尾斜杠（根目录 / 除外）
    [[ "$abs" != "/" ]] && abs="${abs%/}"

    local danger
    for danger in "/" "/usr" "/usr/local" "/bin" "/sbin" "/lib" "/lib64" "/etc" "/var" "/opt" "/boot" "/root" "${HOME%/}" "${HOME%/}/.local" "${HOME%/}/.config" "${HOME%/}/.cache"; do
        if [[ "$abs" == "$danger" ]]; then
            error "拒绝删除敏感/共享目录: $abs（--fresh 应指向独立的构建/安装目录，请为其指定专用子目录）"
        fi
    done
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
            assert_safe_to_delete "$build_dir"
            assert_safe_to_delete "$log_dir"
            rm -rf "$build_dir"
            rm -rf "$log_dir"
            ok "构建目录和日志目录清理完成"
        else
            warn "构建目录和日志目录不存在，跳过清理"
        fi
    fi
}

# --fresh 构建前清理：带危险路径护栏
# 参数: fresh_flag dir...
fresh_clean_dirs() {
    local fresh_flag="$1"
    shift
    if [[ "$fresh_flag" == true ]]; then
        step "=== 清理已有的 build/log/install 目录 ==="
        local d
        for d in "$@"; do
            assert_safe_to_delete "$d"
        done
        rm -rf "$@"
        mkdir -p "$@"
    fi
}

# 检测 host 是否提供某个静态库 (如 libgmp.a / libc.a)
# gcc -print-file-name 找不到时会原样回显文件名，因此只有绝对路径才算存在
# (避免当前目录下的同名文件造成误判)。
host_has_static_lib() {
    local path
    path="$(gcc -print-file-name="$1" 2>/dev/null || true)"
    [[ "$path" == /* && -f "$path" ]]
}

# 静态构建 gdb 的前置检查: gdb 14+ 依赖 GMP/MPFR，全静态链接需要它们的静态库。
# 缺失时直接失败 (而不是静默降级或自行编译)，由使用者决定如何补齐。
require_static_gdb_libs() {
    local missing=()
    host_has_static_lib libgmp.a  || missing+=(libgmp.a)
    host_has_static_lib libmpfr.a || missing+=(libmpfr.a)
    [[ ${#missing[@]} -eq 0 ]] && return 0
    error "静态构建 gdb 需要 host 提供静态库，缺失: ${missing[*]}
  DEB: 运行 ./install-prerequisites.sh (libgmp-dev/libmpfr-dev 已含静态库)
  RPM: 另需安装 gmp-static / mpfr-static
  源码方式: ./install-flex-bison.sh --with-gmp-mpfr，再按其提示导出
            LIBRARY_PATH (给 gcc 找 .a) 与 C_INCLUDE_PATH (给 gdb configure 找头文件)
  也可改用 --disable-gdb 或去掉 --static"
}

# 校验可执行文件是否为静态链接
# 静态 PIE 在 file 输出中显示为 "static-pie linked"，同样属于静态链接。
# 用法: verify_static_binaries [--require] <可执行文件路径>...
#   默认跳过不存在的路径 (便于传入 gdb/flang 等可选组件)；
#   --require 时缺失即视为失败，适合发布流程校验必备产物。
# 返回: 全部通过返回 0；存在动态链接、缺失(--require)或无任何可校验文件时返回 1。
# 构建脚本通常以 `|| true` 忽略返回值 (产物本身仍可用，只是不可跨机器拷贝)，
# 发布流程 (CI) 应把非零返回视为致命错误。
verify_static_binaries() {
    local require=false
    if [[ "${1:-}" == "--require" ]]; then
        require=true
        shift
    fi

    step "=== 校验静态链接 ==="
    local failed=0 checked=0 exe
    for exe in "$@"; do
        if [[ ! -f "$exe" ]]; then
            if [[ "$require" == true ]]; then
                warn "缺失: $exe"
                failed=$((failed + 1))
            fi
            continue
        fi
        checked=$((checked + 1))
        if file -L "$exe" 2>/dev/null | grep -qE "statically linked|static-pie linked"; then
            ok "静态: $(basename "$exe")"
        else
            warn "仍为动态链接: $exe"
            failed=$((failed + 1))
        fi
    done

    if [[ $checked -eq 0 ]]; then
        warn "未找到任何可校验的可执行文件，静态校验无效"
        return 1
    fi
    if [[ $failed -gt 0 ]]; then
        warn "共 ${failed} 项未通过静态校验，拷贝到其他机器时可能无法运行"
        return 1
    fi
    ok "已校验 ${checked} 个可执行文件，均为静态链接"
    return 0
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
                assert_safe_to_delete "$prefix_dir"
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
