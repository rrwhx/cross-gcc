#!/usr/bin/env python3
"""
cross-build.py — 跨平台构建系统

声明式包定义 + 命令式构建后端，支持库/可执行程序的交叉编译与本地编译。
静态/动态链接为一等公民。产物包含源码位置、执行命令、版本等完整元数据。

用法:
  ./cross-build.py --list                           # 列出所有可用包
  ./cross-build.py x264 x265 --target riscv64-linux-gnu --static
  ./cross-build.py zlib zstd --target aarch64-linux-gnu --toolchain-dir ./cross-aarch64-linux-gnu
  ./cross-build.py champsim --native                # 本地构建
  ./cross-build.py x264 --target riscv64-linux-gnu --no-install --static
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import textwrap
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional

# ============================================================================
# 构建结果 / 元数据
# ============================================================================

@dataclass
class BuildResult:
    package: str
    version: str
    target: str
    link_type: str  # "static" | "shared"
    source_dir: str
    build_dir: str
    install_dir: str
    inputs: dict = field(default_factory=dict)   # 源码 URL / ref / 编译器 / 依赖
    commands: list = field(default_factory=list)
    outputs: list = field(default_factory=list)  # [{path, size, sha256}]
    duration_seconds: float = 0.0
    success: bool = False
    error: str = ""


# ============================================================================
# 包定义 — 声明式 + 钩子
# ============================================================================

@dataclass
class PackageDef:
    """声明式包定义"""
    name: str
    version: str
    description: str = ""
    # 源码获取
    source_url: str = ""          # tar 下载
    git_url: str = ""             # git clone
    git_ref: str = ""             # branch/tag
    git_recursive: bool = False
    # 构建系统
    build_system: str = ""        # autotools | cmake | make | meson | custom
    # 源码内的子目录 (cmake source path 等)
    source_subdir: str = ""
    # 静态/动态支持
    supports_static: bool = True
    supports_shared: bool = True
    # 类型
    pkg_type: str = "library"     # library | executable | framework
    # 依赖 (其他包名)
    dependencies: list = field(default_factory=list)
    # 构建参数 (通用)
    configure_args: list = field(default_factory=list)
    cmake_args: list = field(default_factory=list)
    make_args: list = field(default_factory=list)
    env_extra: dict = field(default_factory=dict)
    # 链接方式参数: 引擎默认注入 static/shared 标志; 置 link_args_auto=False 可完全接管
    # (zlib 等手写 configure 不认 --disable-shared, 需用 static_args 显式覆盖)
    # static_args/shared_args 语义: 追加到该后端的主配置命令
    # (cmake/autotools/meson → configure阶段; make → build 阶段)
    link_args_auto: bool = True
    static_args: list = field(default_factory=list)
    shared_args: list = field(default_factory=list)
    # 需走环境变量而非 argv 的链接标志 (跨所有阶段生效)
    # 例: {"LDFLAGS": "-static"} —— 许多 make 项目只认 env 不认命令行传参
    static_env: dict = field(default_factory=dict)
    shared_env: dict = field(default_factory=dict)
    # 是否强制最终可执行文件静态链接 (与"产出 .a 而非 .so"是两个独立含义)。
    # None = 按 pkg_type 推断; 同时产出库与 CLI 的包 (lz4/zstd 等) 应显式置 True
    static_link_exe: Optional[bool] = None

    # ---- configure 方言 (手写 configure 的项目标志名各异, 不应为此写 custom_builder) ----
    # 模板可用占位符: {target} {cc} {cxx} {prefix}
    # host_arg: 交叉编译时声明目标三元组的写法; "" = 不传 (zlib/fio 等不认 --host)
    host_arg: str = "--host={target}"
    # cc_arg: 通过命令行而非 CC 环境变量指定编译器 (例: fio 的 --cc={cc})
    cc_arg: str = ""
    # cross_prefix_arg: 工具链前缀写法 (例: x264 的 --cross-prefix={target}-)
    cross_prefix_arg: str = ""
    # 项目是否有 make install 目标; 无则靠 install_files 手动安装
    has_install_target: bool = True
    # 声明式产物安装: {构建目录内相对路径: 安装根内绝对路径}
    # 给那些没有 install 目标的小项目用 (例: coremark)
    install_files: dict = field(default_factory=dict)
    # 自定义构建函数名 (注册到 CUSTOM_BUILDERS)
    custom_builder: str = ""
    # 安装前缀
    install_prefix: str = "/usr"
    # 是否属于默认发布集 (--release): 选几个典型且构建简单的包,
    # 供 CI 开箱即用地发布; 重型/依赖多的包保留为手动指定
    release_default: bool = False


# ---------------------------------------------------------------------------
# 包注册表
# ---------------------------------------------------------------------------
PACKAGES: dict[str, PackageDef] = {}


def register(pkg: PackageDef):
    PACKAGES[pkg.name] = pkg
    return pkg


def load_recipes(path: Path):
    """从 JSON 加载包定义 (配置式层): 新增或覆盖内置包

    格式: {"packages": [{"name": "foo", "version": "1.0", ...}, ...]}
    字段名与 PackageDef 一致; 未知字段直接报错, 避免静默失效。
    """
    if not path.is_file():
        error(f"recipes 文件不存在: {path}")
        sys.exit(1)
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        error(f"recipes JSON 解析失败 ({path}): {e}")
        sys.exit(1)

    valid = {f.name for f in PackageDef.__dataclass_fields__.values()}
    for entry in data.get("packages", []):
        unknown = set(entry) - valid
        if unknown:
            error(f"recipes {path}: 包 '{entry.get('name', '?')}' 含未知字段 {sorted(unknown)}")
            sys.exit(1)
        if "name" not in entry:
            error(f"recipes {path}: 包定义缺少 name 字段")
            sys.exit(1)
        register(PackageDef(**entry))
        info(f"已加载包定义: {entry['name']} (来自 {path})")


# ======================== 库 ========================

register(PackageDef(
    name="zlib",
    version="1.3.2",
    description="通用压缩库",
    source_url="https://github.com/madler/zlib/releases/download/v{ver}/zlib-{ver}.tar.gz",
    build_system="autotools",
    pkg_type="library",
    # zlib 为手写 configure: 遇到不认识的选项会直接报错退出,
    # 既不认 --host 也不认 --enable-static/--disable-shared; 交叉靠 CC 环境变量
    host_arg="",
    link_args_auto=False,
    static_args=["--static"],
    release_default=True,
))

register(PackageDef(
    name="zlib-ng",
    version="2.3.3",
    description="zlib 高性能替代 (SIMD 优化)",
    source_url="https://github.com/zlib-ng/zlib-ng/archive/refs/tags/{ver}.tar.gz",
    build_system="cmake",
    cmake_args=["-DZLIB_COMPAT=OFF", "-DZLIB_ENABLE_TESTS=OFF"],
    pkg_type="library",
))

register(PackageDef(
    name="lz4",
    version="1.10.0",
    description="极快无损压缩 (库 + CLI)",
    source_url="https://github.com/lz4/lz4/archive/refs/tags/v{ver}.tar.gz",
    build_system="make",
    pkg_type="library",
    # 同时产出 liblz4.a 与 lz4 CLI, CLI 必须静态否则进不了 initramfs
    static_link_exe=True,
    release_default=True,
))

register(PackageDef(
    name="zstd",
    version="1.5.7",
    description="Zstandard 压缩 (库 + CLI)",
    source_url="https://github.com/facebook/zstd/releases/download/v{ver}/zstd-{ver}.tar.gz",
    build_system="make",
    pkg_type="library",
    # 同时产出 libzstd.a 与 zstd CLI
    static_link_exe=True,
))

register(PackageDef(
    name="snappy",
    version="1.2.2",
    description="Google 快速压缩",
    source_url="https://github.com/google/snappy/archive/refs/tags/{ver}.tar.gz",
    build_system="cmake",
    cmake_args=["-DSNAPPY_BUILD_TESTS=OFF", "-DSNAPPY_BUILD_BENCHMARKS=OFF"],
    pkg_type="library",
))

register(PackageDef(
    name="jemalloc",
    version="5.3.1",
    description="高性能内存分配器",
    source_url="https://github.com/jemalloc/jemalloc/releases/download/{ver}/jemalloc-{ver}.tar.bz2",
    build_system="autotools",
    configure_args=["EXTRA_CXXFLAGS=-include stdexcept"],
    pkg_type="library",
))

# ======================== 可执行程序 (编解码/性能) ========================

register(PackageDef(
    name="x264",
    version="master",
    description="H.264/AVC 编码器",
    git_url="https://code.videolan.org/videolan/x264.git",
    git_ref="stable",
    build_system="autotools",
    pkg_type="executable",
    # x264 手写 configure: 认 --host, 但工具链靠 --cross-prefix;
    # 静态可执行文件需 --extra-ldflags=-static (--enable-static 仅管库)
    cross_prefix_arg="--cross-prefix={target}-",
    link_args_auto=False,
    static_args=["--enable-static", "--extra-ldflags=-static"],
    shared_args=["--enable-shared"],
    static_link_exe=False,  # 已由 --extra-ldflags 处理, 无需重复注入
))

register(PackageDef(
    name="x265",
    version="master",
    description="H.265/HEVC 编码器",
    git_url="https://bitbucket.org/multicoreware/x265_git.git",
    build_system="cmake",
    source_subdir="source",
    cmake_args=["-DENABLE_SHARED=OFF", "-DSTATIC_LINK_CRT=ON"],
    supports_shared=True,
    pkg_type="executable",
))

register(PackageDef(
    name="coremark",
    version="main",
    description="EEMBC CoreMark CPU 基准测试",
    git_url="https://github.com/eembc/coremark.git",
    build_system="make",
    pkg_type="executable",
    # PORT_DIR=posix: 默认按宿主 uname 检测, 交叉编译语义不符
    # compile 目标: 默认 run 目标会执行二进制, 交叉下不可运行
    make_args=["PORT_DIR=posix", "compile", "OPATH=out/"],
    # XCFLAGS 是 coremark 自己的追加标志入口; PERFORMANCE_RUN=1 为标准测试种子
    link_args_auto=False,
    static_args=["XCFLAGS=-static -DPERFORMANCE_RUN=1"],
    supports_shared=False,
    # coremark 无 install 目标, 产物名为 coremark.exe, 靠声明式安装重命名
    # 装到 usr/bin 以保持发布树的 FHS 层次一致
    # (initramfs 内放 /root/coremark 是 build-busybox.sh 的职责, 与此无关)
    has_install_target=False,
    install_files={"out/coremark.exe": "/usr/bin/coremark"},
    release_default=True,
))

register(PackageDef(
    name="fio",
    version="master",
    description="灵活的 I/O 压测工具",
    git_url="https://github.com/axboe/fio.git",
    build_system="autotools",
    pkg_type="executable",
    # fio 手写 configure: 不认 --host, 交叉靠 --cc=<triple>-gcc;
    # 静态链接靠它自己的 --build-static, 无需再注入 -static LDFLAGS
    host_arg="",
    cc_arg="--cc={cc}",
    link_args_auto=False,
    static_args=["--build-static"],
    static_link_exe=False,
    supports_shared=False,
    # 交叉环境下这两个依赖基本不可能满足
    configure_args=["--disable-tcmalloc", "--disable-rdma"],
    release_default=True,
))

# ======================== 复杂框架 ========================

register(PackageDef(
    name="champsim",
    version="master",
    description="ChampSim 缓存模拟器",
    git_url="https://github.com/ChampSim/ChampSim.git",
    git_recursive=True,
    build_system="custom",
    custom_builder="build_champsim",
    supports_static=False,
    supports_shared=False,
    pkg_type="framework",
))

register(PackageDef(
    name="sparta",
    version="map_v2",
    description="MAP/Sparta 建模框架",
    git_url="https://github.com/sparcians/map.git",
    git_ref="map_v2",
    git_recursive=True,
    build_system="cmake",
    source_subdir="sparta",
    cmake_args=["-DCMAKE_BUILD_TYPE=Release"],
    pkg_type="framework",
    dependencies=[],  # system deps: libhdf5-dev libsqlite3-dev ...
))

register(PackageDef(
    name="riscv-perf-model",
    version="master",
    description="RISC-V 性能模型 (基于 Sparta)",
    git_url="https://github.com/riscv-software-src/riscv-perf-model.git",
    git_recursive=True,
    build_system="cmake",
    cmake_args=["-DCMAKE_BUILD_TYPE=Release"],
    dependencies=["sparta"],
    pkg_type="framework",
))


# ============================================================================
# 工具函数
# ============================================================================

class Colors:
    RESET = "\033[0m"
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    CYAN = "\033[0;36m"
    YELLOW = "\033[0;33m"
    BOLD = "\033[1m"


def info(msg):
    print(f"{Colors.CYAN}[INFO]{Colors.RESET} {msg}")


def step(msg):
    print(f"{Colors.GREEN}[STEP]{Colors.RESET} {msg}")


def error(msg):
    print(f"{Colors.RED}[ERROR]{Colors.RESET} {msg}", file=sys.stderr)


def ok(msg):
    print(f"{Colors.GREEN}[OK]{Colors.RESET} {msg}")


def run_cmd(cmd: list[str], cwd=None, env=None, log_file=None) -> subprocess.CompletedProcess:
    """执行命令并记录，失败时打印尾部日志"""
    cmd_str = " ".join(cmd)
    info(f"  $ {cmd_str}")

    if log_file:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        with open(log_file, "w") as f:
            result = subprocess.run(cmd, cwd=cwd, env=env,
                                    stdout=f, stderr=subprocess.STDOUT)
        if result.returncode != 0:
            # 打印日志最后 30 行
            lines = log_file.read_text().splitlines()
            error(f"命令失败 (exit {result.returncode})，日志尾部:")
            for line in lines[-30:]:
                print(f"    {line}", file=sys.stderr)
        return result
    else:
        return subprocess.run(cmd, cwd=cwd, env=env)


def detect_cpu_count() -> int:
    return os.cpu_count() or 4


# ============================================================================
# 构建引擎
# ============================================================================

class BuildEngine:
    """构建引擎：管理源码获取、编译、安装"""

    def __init__(self, args):
        self.args = args
        self.target = args.target
        self.native = args.native
        self.static = args.static
        self.install = not args.no_install
        self.jobs = args.jobs or detect_cpu_count()
        self.work_dir = Path(args.work_dir).resolve()
        self.download_dir = self.work_dir / "downloads"
        self.src_dir = self.work_dir / f"src-{self.target or 'native'}"
        self.build_base = self.work_dir / f"build-{self.target or 'native'}"
        self.log_dir = self.work_dir / f"logs-{self.target or 'native'}"
        self.install_dir = Path(args.install_dir).resolve() if args.install_dir else None
        self.results: list[BuildResult] = []

        # 编译器设置
        self.env = os.environ.copy()
        if not self.native and self.target:
            toolchain_dir = Path(args.toolchain_dir).resolve() if args.toolchain_dir else None
            if toolchain_dir:
                self.env["PATH"] = f"{toolchain_dir / 'bin'}:{self.env['PATH']}"
            prefix = f"{self.target}-"
            self.env["CC"] = args.cc or f"{prefix}gcc"
            self.env["CXX"] = args.cxx or f"{prefix}g++"
            self.env["AR"] = f"{prefix}ar"
            self.env["RANLIB"] = f"{prefix}ranlib"
            self.env["STRIP"] = f"{prefix}strip"
            self.env["NM"] = f"{prefix}nm"
            self.sysroot = toolchain_dir / self.target if toolchain_dir else None
        else:
            self.env["CC"] = args.cc or "gcc"
            self.env["CXX"] = args.cxx or "g++"
            self.sysroot = None

        # 创建目录
        for d in [self.download_dir, self.src_dir, self.build_base, self.log_dir]:
            d.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # 源码获取
    # ------------------------------------------------------------------

    def fetch_source(self, pkg: PackageDef) -> Path:
        """获取源码，返回源码目录"""
        if pkg.git_url:
            return self._git_clone(pkg)
        elif pkg.source_url:
            return self._download_tar(pkg)
        else:
            error(f"{pkg.name}: 未指定源码来源")
            sys.exit(1)

    def _git_clone(self, pkg: PackageDef) -> Path:
        dest = self.src_dir / pkg.name
        if dest.exists():
            info(f"源码已存在: {dest}")
            return dest
        cmd = ["git", "clone", "--depth", "1"]
        if pkg.git_ref:
            cmd += ["--branch", pkg.git_ref]
        if pkg.git_recursive:
            cmd.append("--recursive")
        cmd += [pkg.git_url, str(dest)]
        step(f"克隆 {pkg.name} ({pkg.git_url})")
        r = run_cmd(cmd, log_file=self.log_dir / f"{pkg.name}_clone.log")
        if r.returncode != 0:
            error(f"克隆失败: {pkg.name}")
            sys.exit(1)
        return dest

    def _download_tar(self, pkg: PackageDef) -> Path:
        url = pkg.source_url.replace("{ver}", pkg.version)
        # 提取文件名
        fname = url.split("/")[-1]
        archive = self.download_dir / fname
        # 猜测解压后目录名
        for ext in (".tar.gz", ".tar.bz2", ".tar.xz", ".tgz"):
            if fname.endswith(ext):
                dirname = fname[:-len(ext)]
                break
        else:
            dirname = fname.rsplit(".", 1)[0]
        src_path = self.src_dir / dirname

        if src_path.exists():
            info(f"源码已存在: {src_path}")
            return src_path

        # 下载
        if not archive.exists():
            step(f"下载 {pkg.name} ({url})")
            # --connect-timeout: 避免网络不通时白等两分钟 (默认无连接超时)
            r = run_cmd(["curl", "-fSL", "--insecure", "--progress-bar",
                         "--connect-timeout", "20", "--retry", "2",
                         "-o", str(archive), url])
            if r.returncode != 0:
                archive.unlink(missing_ok=True)  # 删除半成品, 下次不会误用
                error(f"下载失败: {url}")
                sys.exit(1)

        # 解压
        step(f"解压 {fname}")
        run_cmd(["tar", "-xf", str(archive), "-C", str(self.src_dir)])
        # 有时解压后的目录名与预期不同，尝试 glob
        if not src_path.exists():
            candidates = list(self.src_dir.glob(f"{pkg.name}*"))
            if candidates:
                src_path = candidates[0]
        return src_path

    # ------------------------------------------------------------------
    # 构建后端
    # ------------------------------------------------------------------

    def build_package(self, pkg: PackageDef) -> BuildResult:
        """构建单个包"""
        t0 = time.time()
        result = BuildResult(
            package=pkg.name,
            version=pkg.version,
            target=self.target or "native",
            link_type="static" if self.static else "shared",
            source_dir="",
            build_dir="",
            install_dir="",
        )

        try:
            # 获取源码
            src_path = self.fetch_source(pkg)
            result.source_dir = str(src_path)

            # 输入元数据 (可复现构建所需的全部输入)
            result.inputs = {
                "source_url": pkg.source_url.replace("{ver}", pkg.version) if pkg.source_url else "",
                "git_url": pkg.git_url,
                "git_ref": pkg.git_ref,
                "build_system": pkg.custom_builder or pkg.build_system,
                "cc": self.env.get("CC", ""),
                "cxx": self.env.get("CXX", ""),
                "sysroot": str(self.sysroot) if self.sysroot else "",
                "jobs": self.jobs,
                "dependencies": list(pkg.dependencies),
                "install_prefix": pkg.install_prefix,
                "installed": self.install,
            }

            # 构建目录
            build_dir = self.build_base / pkg.name
            if build_dir.exists():
                shutil.rmtree(build_dir)
            build_dir.mkdir(parents=True)
            result.build_dir = str(build_dir)

            # 安装目录
            if self.install and self.install_dir:
                inst_dir = self.install_dir
            elif self.install and self.sysroot:
                inst_dir = self.sysroot
            else:
                inst_dir = build_dir / "_install"
            inst_dir.mkdir(parents=True, exist_ok=True)
            result.install_dir = str(inst_dir)

            # 安装前快照: 用于事后判定本包新增了哪些文件
            # (多包共用 --install-dir 时避免产物归属错串)
            self._inst_pre_snapshot = self._snapshot_tree(inst_dir) if self.install else {}

            # 选择构建方法
            if pkg.custom_builder and pkg.custom_builder in CUSTOM_BUILDERS:
                CUSTOM_BUILDERS[pkg.custom_builder](self, pkg, src_path, build_dir, inst_dir, result)
            elif pkg.build_system == "cmake":
                self._build_cmake(pkg, src_path, build_dir, inst_dir, result)
            elif pkg.build_system == "autotools":
                self._build_autotools(pkg, src_path, build_dir, inst_dir, result)
            elif pkg.build_system == "make":
                self._build_make(pkg, src_path, build_dir, inst_dir, result)
            elif pkg.build_system == "meson":
                self._build_meson(pkg, src_path, build_dir, inst_dir, result)
            elif pkg.build_system == "custom":
                if pkg.custom_builder and pkg.custom_builder in CUSTOM_BUILDERS:
                    CUSTOM_BUILDERS[pkg.custom_builder](self, pkg, src_path, build_dir, inst_dir, result)
                else:
                    error(f"{pkg.name}: custom 构建系统但无自定义构建函数")
                    result.error = "missing custom_builder"
                    return result
            else:
                error(f"{pkg.name}: 未知构建系统 '{pkg.build_system}'")
                result.error = f"unknown build_system: {pkg.build_system}"
                return result

            result.success = True
            ok(f"{pkg.name} {pkg.version} 构建完成 ({self.target or 'native'}, {'static' if self.static else 'shared'})")

        except Exception as e:
            result.error = str(e)
            error(f"{pkg.name} 构建异常: {e}")

        result.duration_seconds = round(time.time() - t0, 2)
        self.results.append(result)
        return result

    # ------------------------------------------------------------------
    # 链接方式辅助 (静态链接为一等公民)
    # ------------------------------------------------------------------

    def _want_static_exe(self, pkg: PackageDef) -> bool:
        """是否需要强制最终可执行文件静态链接

        “产出 .a 而非 .so”与“可执行文件不动态链 libc”是两个独立决定:
        前者由 BUILD_SHARED_LIBS/--disable-shared 控制, 后者必须显式 -static。
        """
        if not self.static:
            return False
        if pkg.static_link_exe is not None:
            return pkg.static_link_exe
        return pkg.pkg_type in ("executable", "framework")

    def _link_env(self, pkg: PackageDef) -> dict:
        """将包级 static_env/shared_env 合入环境 (跨 configure/build/install 生效)"""
        extra = dict(pkg.env_extra)
        extra.update(pkg.static_env if self.static else pkg.shared_env)
        return dict(self.env, **{k: str(v) for k, v in extra.items()}) if extra else self.env

    def _render(self, tmpl: str, pkg: PackageDef) -> str:
        """渲染 configure 方言模板中的占位符"""
        return tmpl.format(target=self.target or "",
                           cc=self.env.get("CC", ""),
                           cxx=self.env.get("CXX", ""),
                           prefix=pkg.install_prefix)

    def _snapshot_tree(self, root: Path) -> dict:
        """快照安装树现有文件 (用于区分本包新增了哪些文件)

        多个包共用同一个 --install-dir 时, 不做快照就会把先前包的
        产物算成本包的 (CI 实测: coremark/fio 的产物列表里出现了 lz4)。
        """
        snap = {}
        if not Path(root).exists():
            return snap
        for p in Path(root).rglob("*"):
            if p.is_file() and not p.is_symlink():
                try:
                    st = p.stat()
                    snap[p] = (st.st_size, st.st_mtime_ns)
                except OSError:
                    continue
        return snap

    @staticmethod
    def _is_elf(p: Path) -> bool:
        """按 magic 判定 ELF, 用于排除 configure/*.py 等可执行的源码脚本"""
        try:
            with open(p, "rb") as f:
                return f.read(4) == b"\x7fELF"
        except OSError:
            return False

    def _install_declared_files(self, pkg: PackageDef, build_dir: Path, inst_dir: Path, result):
        """执行 install_files 声明的产物拷贝 (适用于无 install 目标的项目)"""
        for src_rel, dest_abs in pkg.install_files.items():
            src = build_dir / src_rel
            if not src.exists():
                raise RuntimeError(f"install_files 源不存在: {src}")
            dest = inst_dir / dest_abs.lstrip("/")
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
            dest.chmod(0o755)
            result.commands.append(f"install -D -m755 {src_rel} {dest_abs}")
            info(f"  安装 {src_rel} -> {dest_abs}")

    def _build_cmake(self, pkg, src_path, build_dir, inst_dir, result):
        cmake_src = src_path / pkg.source_subdir if pkg.source_subdir else src_path
        cmake_args = [
            "cmake", str(cmake_src),
            f"-DCMAKE_INSTALL_PREFIX={pkg.install_prefix}",
            "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
        ]

        # 静态/动态 (一等公民): link_args_auto=False 时完全由包定义接管
        if pkg.link_args_auto:
            cmake_args += ["-DBUILD_SHARED_LIBS=" + ("OFF" if self.static else "ON")]
            if self._want_static_exe(pkg):
                cmake_args += ["-DCMAKE_EXE_LINKER_FLAGS=-static"]
        cmake_args += pkg.static_args if self.static else pkg.shared_args
        env = self._link_env(pkg)

        # 交叉编译
        if not self.native and self.target:
            target_cpu = self.target.split("-")[0]
            cmake_args += [
                "-DCMAKE_SYSTEM_NAME=Linux",
                f"-DCMAKE_SYSTEM_PROCESSOR={target_cpu}",
                f"-DCMAKE_C_COMPILER={self.env['CC']}",
                f"-DCMAKE_CXX_COMPILER={self.env['CXX']}",
            ]
            if self.sysroot:
                cmake_args += [
                    f"-DCMAKE_SYSROOT={self.sysroot}",
                    f"-DCMAKE_FIND_ROOT_PATH={self.sysroot}",
                    "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY",
                    "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY",
                    "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY",
                ]

        cmake_args += pkg.cmake_args
        result.commands.append(" ".join(cmake_args))

        r = run_cmd(cmake_args, cwd=build_dir, env=env,
                    log_file=self.log_dir / f"{pkg.name}_configure.log")
        if r.returncode != 0:
            raise RuntimeError(f"cmake configure 失败")

        # Build
        build_cmd = ["cmake", "--build", ".", f"-j{self.jobs}"]
        result.commands.append(" ".join(build_cmd))
        r = run_cmd(build_cmd, cwd=build_dir, env=env,
                    log_file=self.log_dir / f"{pkg.name}_build.log")
        if r.returncode != 0:
            raise RuntimeError("cmake build 失败")

        # Install (cmake --install 尊重 DESTDIR 环境变量, 与 autotools/make 语义一致)
        if self.install:
            install_cmd = ["cmake", "--install", "."]
            result.commands.append(f"DESTDIR={inst_dir} " + " ".join(install_cmd))
            inst_env = dict(env, DESTDIR=str(inst_dir))
            r = run_cmd(install_cmd, cwd=build_dir, env=inst_env,
                        log_file=self.log_dir / f"{pkg.name}_install.log")
            if r.returncode != 0:
                raise RuntimeError("cmake install 失败")

        # 收集产物
        self._collect_outputs(build_dir, inst_dir, result)

    def _build_autotools(self, pkg, src_path, build_dir, inst_dir, result):
        """configure + make + make install

        兼容 autoconf 与手写 configure: 目标/编译器/静态标志的具体写法
        全部由包定义的 configure 方言字段描述, 无需为此写 custom_builder。
        """
        # 多数 configure 项目需在源码目录内构建
        shutil.copytree(src_path, build_dir, dirs_exist_ok=True)

        configure_args = ["./configure", f"--prefix={pkg.install_prefix}"]
        # 交叉编译相关方言 (空模板 = 该项目不认这个标志)
        if not self.native and self.target:
            for tmpl in (pkg.host_arg, pkg.cross_prefix_arg):
                if tmpl:
                    configure_args.append(self._render(tmpl, pkg))
        if pkg.cc_arg:
            configure_args.append(self._render(pkg.cc_arg, pkg))
        # 链接方式: link_args_auto=False 时完全由 static_args/shared_args 接管
        if pkg.link_args_auto:
            if self.static:
                configure_args += ["--enable-static", "--disable-shared"]
            else:
                configure_args += ["--enable-shared", "--disable-static"]
        configure_args += pkg.static_args if self.static else pkg.shared_args
        configure_args += pkg.configure_args
        result.commands.append(" ".join(configure_args))

        # 可执行文件静态链接靠 LDFLAGS (configure 阶段就要就位, 否则链接检测会不一致)
        env = self._link_env(pkg)
        if self._want_static_exe(pkg):
            env = dict(env, LDFLAGS=(env.get("LDFLAGS", "") + " -static").strip())

        r = run_cmd(configure_args, cwd=build_dir, env=env,
                    log_file=self.log_dir / f"{pkg.name}_configure.log")
        if r.returncode != 0:
            raise RuntimeError("configure 失败")

        make_cmd = ["make", f"-j{self.jobs}"] + pkg.make_args
        result.commands.append(" ".join(make_cmd))
        r = run_cmd(make_cmd, cwd=build_dir, env=env,
                    log_file=self.log_dir / f"{pkg.name}_build.log")
        if r.returncode != 0:
            raise RuntimeError("make 失败")

        if self.install:
            if pkg.has_install_target:
                install_cmd = ["make", "install", f"DESTDIR={inst_dir}"]
                result.commands.append(" ".join(install_cmd))
                r = run_cmd(install_cmd, cwd=build_dir, env=env,
                            log_file=self.log_dir / f"{pkg.name}_install.log")
                if r.returncode != 0:
                    raise RuntimeError("make install 失败")
            self._install_declared_files(pkg, build_dir, inst_dir, result)

        self._collect_outputs(build_dir, inst_dir, result)

    def _build_make(self, pkg, src_path, build_dir, inst_dir, result):
        shutil.copytree(src_path, build_dir, dirs_exist_ok=True)

        # 工具链与链接方式赋值: build 与 install 必须收到同一套。
        # lz4/zstd 的 install 目标会按变量重新判定该构建什么, 只给 build 传
        # BUILD_SHARED=no 时, install 阶段会去编译 .so (CI 实测: 报
        # "compiling dynamic library" 并因 -static 导致 crtbeginT.o 重定位冲突)
        assigns = [f"CC={self.env['CC']}", f"CXX={self.env['CXX']}",
                   f"AR={self.env.get('AR', 'ar')}",
                   f"PREFIX={pkg.install_prefix}"]
        if pkg.link_args_auto and self.static:
            assigns.append("BUILD_SHARED=no")
        assigns += pkg.static_args if self.static else pkg.shared_args

        env = self._link_env(pkg)
        make_cmd = ["make", f"-j{self.jobs}"] + assigns
        # BUILD_SHARED=no 只决定库形态, 不影响 libc 链接方式;
        # 同时产出 CLI 的包 (lz4/zstd) 需额外用 LDFLAGS 强制静态可执行文件。
        # 仅作为命令行赋值传入 (优先级高于 Makefile 内赋值), 不放进 env,
        # 避免项目内部链接 .so 时误用 -static
        if self._want_static_exe(pkg):
            ldflags = (env.get("LDFLAGS", "") + " -static").strip()
            make_cmd.append(f"LDFLAGS={ldflags}")
        make_cmd += pkg.make_args
        result.commands.append(" ".join(make_cmd))

        r = run_cmd(make_cmd, cwd=build_dir, env=env,
                    log_file=self.log_dir / f"{pkg.name}_build.log")
        if r.returncode != 0:
            raise RuntimeError("make 失败")

        if self.install:
            if pkg.has_install_target:
                # 同样的 assigns (含 BUILD_SHARED=no), 但不带 LDFLAGS=-static:
                # install 不应再编译东西, 带上只会在链 .so 时出错
                install_cmd = ["make", "install", f"DESTDIR={inst_dir}"] + assigns
                result.commands.append(" ".join(install_cmd))
                r = run_cmd(install_cmd, cwd=build_dir, env=env,
                            log_file=self.log_dir / f"{pkg.name}_install.log")
                if r.returncode != 0:
                    raise RuntimeError("make install 失败")
            self._install_declared_files(pkg, build_dir, inst_dir, result)

        self._collect_outputs(build_dir, inst_dir, result)

    def _build_meson(self, pkg, src_path, build_dir, inst_dir, result):
        setup_cmd = ["meson", "setup", str(build_dir), str(src_path),
                     f"--prefix={pkg.install_prefix}"]
        if pkg.link_args_auto:
            setup_cmd.append("--default-library=" + ("static" if self.static else "shared"))
            # --default-library 只管库形态; 可执行文件静态链接需 c_link_args
            if self._want_static_exe(pkg):
                setup_cmd += ["-Dc_link_args=-static", "-Dcpp_link_args=-static"]
        setup_cmd += pkg.static_args if self.static else pkg.shared_args
        env = self._link_env(pkg)
        if not self.native and self.target:
            # 需要 meson cross file — 可由用户通过 static_args 传入 --cross-file
            pass
        result.commands.append(" ".join(setup_cmd))
        r = run_cmd(setup_cmd, env=env,
                    log_file=self.log_dir / f"{pkg.name}_setup.log")
        if r.returncode != 0:
            raise RuntimeError("meson setup 失败")

        compile_cmd = ["meson", "compile", "-C", str(build_dir), f"-j{self.jobs}"]
        result.commands.append(" ".join(compile_cmd))
        r = run_cmd(compile_cmd, env=env,
                    log_file=self.log_dir / f"{pkg.name}_build.log")
        if r.returncode != 0:
            raise RuntimeError("meson compile 失败")

        if self.install:
            install_cmd = ["meson", "install", "-C", str(build_dir),
                           "--destdir", str(inst_dir)]
            result.commands.append(" ".join(install_cmd))
            r = run_cmd(install_cmd, env=env,
                        log_file=self.log_dir / f"{pkg.name}_install.log")
            if r.returncode != 0:
                raise RuntimeError("meson install 失败")

        self._collect_outputs(build_dir, inst_dir, result)

    def _collect_outputs(self, build_dir, inst_dir, result):
        """收集产物, 记录路径/大小/sha256 (CI 发布可直接消费)

        安装模式: 产物 = 本包新增到安装树的文件 (快照差异)。
        不能直接扫 build_dir 找"看上去像可执行文件的东西": 会捐到
        configure 等源码脚本, 以及 zlib 的 example/minigzip 等未安装的
        测试程序 (CI 实测: 它们是动态链接的, 直接卡死静态校验)。
        未安装模式: 取 build_dir 内的库与 ELF 可执行文件 (按 magic 判定)。
        """
        paths: set = set()
        if self.install:
            pre = getattr(self, "_inst_pre_snapshot", {})
            for p in Path(inst_dir).rglob("*"):
                if not p.is_file() or p.is_symlink():
                    continue
                try:
                    st = p.stat()
                except OSError:
                    continue
                if pre.get(p) != (st.st_size, st.st_mtime_ns):
                    paths.add(p)
        else:
            for pat in ("*.a", "*.so", "*.so.*", "*.dylib"):
                paths.update(Path(build_dir).rglob(pat))
            for p in Path(build_dir).iterdir():
                if p.is_file() and os.access(p, os.X_OK) and self._is_elf(p):
                    paths.add(p)

        entries = []
        for p in sorted(paths):
            try:
                if p.is_symlink() or not p.is_file():
                    continue
                data = p.read_bytes()
                entries.append({
                    "path": str(p),
                    "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                })
            except OSError:
                continue
        result.outputs = entries


# ============================================================================
# 自定义构建函数
# ============================================================================

CUSTOM_BUILDERS: dict = {}


def custom_builder(name):
    def decorator(fn):
        CUSTOM_BUILDERS[name] = fn
        return fn
    return decorator


@custom_builder("build_champsim")
def _build_champsim(engine: BuildEngine, pkg, src_path, build_dir, inst_dir, result):
    """ChampSim: vcpkg + config.sh + make"""
    # 初始化 vcpkg
    vcpkg_sh = src_path / "vcpkg" / "bootstrap-vcpkg.sh"
    if vcpkg_sh.exists():
        step("初始化 vcpkg")
        run_cmd(["bash", str(vcpkg_sh)], cwd=src_path)
        run_cmd([str(src_path / "vcpkg" / "vcpkg"), "install"], cwd=src_path)

    # 配置
    config_json = src_path / "champsim_config.json"
    if not config_json.exists():
        config_json = src_path / "config.json"
    if config_json.exists():
        step("ChampSim 配置")
        r = run_cmd(["./config.sh", str(config_json)], cwd=src_path, env=engine.env,
                    log_file=engine.log_dir / f"{pkg.name}_config.log")
        if r.returncode != 0:
            raise RuntimeError("ChampSim config.sh 失败")

    make_cmd = ["make", f"-j{engine.jobs}"]
    result.commands.append(" ".join(make_cmd))
    r = run_cmd(make_cmd, cwd=src_path, env=engine.env,
                log_file=engine.log_dir / f"{pkg.name}_build.log")
    if r.returncode != 0:
        raise RuntimeError("ChampSim make 失败")

    engine._collect_outputs(src_path, inst_dir, result)


# ============================================================================
# 依赖解析
# ============================================================================

def release_set() -> list[str]:
    """默认发布集: 标记了 release_default 的包 (保持注册顺序)"""
    return [n for n, p in PACKAGES.items() if p.release_default]


def resolve_build_order(names: list[str]) -> list[str]:
    """拓扑排序，确保依赖先构建"""
    visited = set()
    order = []

    def visit(name):
        if name in visited:
            return
        visited.add(name)
        pkg = PACKAGES.get(name)
        if pkg:
            for dep in pkg.dependencies:
                visit(dep)
        order.append(name)

    for n in names:
        visit(n)
    return order


# ============================================================================
# 报告
# ============================================================================

def print_summary(results: list[BuildResult]):
    print(f"\n{'='*78}")
    print(f"{'包':<16} {'版本':<10} {'目标':<22} {'链接':<7} {'产物':<5} {'耗时':<8} {'状态'}")
    print(f"{'-'*78}")
    for r in results:
        status = f"{Colors.GREEN}OK{Colors.RESET}" if r.success else f"{Colors.RED}FAIL{Colors.RESET}"
        print(f"{r.package:<16} {r.version:<10} {r.target:<22} {r.link_type:<7} "
              f"{len(r.outputs):<5} {r.duration_seconds:<8.1f} {status}")
    print(f"{'='*78}")


def save_manifest(results: list[BuildResult], path: Path):
    """保存构建清单 JSON (CI 可解析)"""
    manifest = {
        "build_time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "packages": [asdict(r) for r in results],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    info(f"构建清单已保存: {path}")


# ============================================================================
# CLI
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="跨平台构建系统 — 库/程序的交叉编译与本地编译",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
        示例:
          %(prog)s --list
          %(prog)s --release --target riscv64-linux-gnu --toolchain-dir ./cross-riscv64-linux-gnu --static
          %(prog)s zlib zstd --target riscv64-linux-gnu --toolchain-dir ./cross-riscv64-linux-gnu --static
          %(prog)s x264 x265 --target riscv64-linux-gnu --toolchain-dir ./cross-riscv64-linux-gnu --static --no-install
          %(prog)s coremark --native --static
          %(prog)s champsim --native
          %(prog)s sparta riscv-perf-model --native
          %(prog)s myprog --native --recipes my-recipes.json    # 配置式扩展
        """),
    )

    parser.add_argument("packages", nargs="*", help="要构建的包名 (可多个)")
    parser.add_argument("--list", action="store_true", help="列出所有可用包")
    parser.add_argument("--target", default="", help="目标三元组 (例: riscv64-linux-gnu)")
    parser.add_argument("--native", action="store_true", help="本地构建 (忽略 --target)")
    parser.add_argument("--toolchain-dir", default="", help="工具链根目录")
    parser.add_argument("--static", action="store_true", help="静态链接 (一等公民)")
    parser.add_argument("--shared", action="store_true", help="动态链接 (默认)")
    parser.add_argument("--no-install", action="store_true", help="仅构建不安装")
    parser.add_argument("--install-dir", default="", help="安装目录 (默认: sysroot 或 build/_install)")
    parser.add_argument("--work-dir", default=".", help="工作目录 (默认: 当前目录)")
    parser.add_argument("-j", "--jobs", type=int, default=0, help="并行编译线程数")
    parser.add_argument("--cc", default="", help="C 编译器 (覆盖自动推导)")
    parser.add_argument("--cxx", default="", help="C++ 编译器 (覆盖自动推导)")
    parser.add_argument("--manifest", default="", help="输出构建清单 JSON 路径")
    parser.add_argument("--recipes", action="append", default=[],
                        help="加载额外的包定义 JSON (配置式扩展, 可多次指定)")
    parser.add_argument("--all", action="store_true", help="构建所有库类型的包")
    parser.add_argument("--release", action="store_true",
                        help="构建默认发布集 (几个典型且简单的包, 见 --list 的发布列)")
    parser.add_argument("--dry-run", action="store_true",
                        help="只打印构建计划 (顺序/源码/链接方式), 不下载不构建")

    args = parser.parse_args()

    # 配置式扩展: 从 JSON 加载/覆盖包定义 (无需修改本脚本即可新增构建)
    for recipe in args.recipes:
        load_recipes(Path(recipe))

    # --list
    if args.list:
        print(f"\n{'包名':<18} {'类型':<12} {'版本':<12} {'构建系统':<12} {'静态':<5} {'发布':<5} {'说明'}")
        print("-" * 96)
        for name, pkg in sorted(PACKAGES.items()):
            static_mark = "✓" if pkg.supports_static else "✗"
            rel_mark = "✓" if pkg.release_default else ""
            print(f"{name:<18} {pkg.pkg_type:<12} {pkg.version:<12} {pkg.build_system:<12} "
                  f"{static_mark:<5} {rel_mark:<5} {pkg.description}")
        print(f"\n发布集 (--release): {' '.join(release_set()) or '无'}\n")
        return

    # 确定要构建的包
    if args.release:
        names = release_set()
        if not names:
            error("发布集为空 (无包标记 release_default)")
            sys.exit(1)
    elif args.all:
        names = [n for n, p in PACKAGES.items() if p.pkg_type == "library"]
    elif not args.packages:
        parser.print_help()
        sys.exit(1)
    else:
        names = args.packages

    # 验证包名
    for n in names:
        if n not in PACKAGES:
            error(f"未知包: {n}  (用 --list 查看所有可用包)")
            sys.exit(1)

    # 验证目标
    if not args.native and not args.target:
        error("需要指定 --target 或 --native")
        sys.exit(1)

    # 依赖解析
    names = resolve_build_order(names)
    info(f"构建顺序: {' -> '.join(names)}")
    info(f"目标: {args.target or 'native'}, 链接: {'static' if args.static else 'shared'}")

    # --dry-run: 只展示计划
    if args.dry_run:
        print(f"\n{'包':<18} {'类型':<12} {'构建':<12} {'链接':<8} {'源码'}")
        print("-" * 96)
        for name in names:
            pkg = PACKAGES[name]
            src = pkg.git_url or pkg.source_url.replace("{ver}", pkg.version)
            if args.static and not pkg.supports_static:
                link = "SKIP"
            else:
                link = "static" if args.static else "shared"
            print(f"{name:<18} {pkg.pkg_type:<12} "
                  f"{(pkg.custom_builder or pkg.build_system):<12} {link:<8} {src}")
        print(f"\n安装: {'是' if not args.no_install else '否'}"
              f"  并行: {args.jobs or detect_cpu_count()}"
              f"  工作目录: {Path(args.work_dir).resolve()}\n")
        return

    # 构建
    engine = BuildEngine(args)
    for name in names:
        pkg = PACKAGES[name]
        # 检查静态支持
        if args.static and not pkg.supports_static:
            info(f"跳过 {name} (不支持静态链接)")
            continue
        engine.build_package(pkg)

    # 报告
    print_summary(engine.results)

    # 保存清单
    manifest_path = Path(args.manifest) if args.manifest else engine.log_dir / "build-manifest.json"
    save_manifest(engine.results, manifest_path)

    # 退出码
    if any(not r.success for r in engine.results):
        sys.exit(1)


if __name__ == "__main__":
    main()
