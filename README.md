## Cross GCC / LLVM 交叉编译工具链构建套件

从源码构建完整的交叉编译工具链，支持多架构、多 C 库组合。

### 支持的目标

- **架构**：`aarch64` · `loongarch64` · `riscv32` · `riscv64` · `i686` · `x86_64` · `mips` · `mipsel` · `mips64` · `mips64el` · `arm`
- **C 库**：**glibc** · **musl** · **newlib**（bare-metal ELF）
- **LLVM/Clang**：支持自动下载或 git 最新版

---

### 文件说明

| 文件 | 用途 |
|------|------|
| `build-toolchain-gcc.sh` | 核心脚本：构建 GCC + binutils + glibc/musl 工具链 |
| `build-toolchain-elf.sh` | 构建 GCC + binutils + newlib（bare-metal ELF）工具链 |
| `build-toolchain-llvm.sh` | 构建 LLVM/Clang 交叉编译器（支持自动下载源码） |
| `build-target-libs.sh` | 交叉编译目标平台第三方库（zlib, zstd, lz4, snappy, jemalloc 等） |
| `build-packages.py` | 按包配方构建目标平台或本机的第三方库和程序 |
| `build-busybox.sh` | 交叉编译 BusyBox 并生成 initramfs |
| `build-kernel.sh` | 交叉编译 Linux 内核 |
| `build-mini-kernel.sh` | 生成最小内核配置并构建，支持仅生成配置 |
| `build-toolchain-gcc-batch.sh` | 批量构建多架构 × 多 libc 组合 |
| `lib.sh` | 公共函数库（下载、git 克隆、日志、构建辅助） |
| `install-prerequisites.sh` | 安装系统级构建依赖（Homebrew/apt/dnf/pacman） |
| `install-flex-bison.sh` | 从源码编译安装 flex + bison + texinfo |
| `prepare-gcc.sh` | GCC 源码预处理（下载 gmp/mpfr/mpc/isl 等依赖） |
| `get-latest-versions.sh` | 获取各组件最新发布版本号 |
| `env-macos.sh` | macOS 环境适配封装（自动设置 GNU 工具路径） |
| `build-toolchain-llvm-batch.sh` | 批量构建单版本 × 多架构 LLVM 工具链 |
| `run-build-presets.sh` | 执行预设的多版本 GCC/LLVM 构建配方 |
| `test-toolchain.sh` | 工具链冒烟测试：编译 C/C++/Fortran 并经 qemu-user 运行 |
| `test/test-qemu-run.sh` | QEMU 系统模拟冒烟测试：启动内核 + initramfs |
| `build-qemu.sh` | 从源码构建 QEMU（系统模拟 + 用户态模拟），供测试脚本使用 |

`run-build-presets.sh` 为 LLVM 配方自动设置默认并发：编译按 4 GiB/任务、链接按 10 GiB/任务估算，向下取整后限制在 1 到 CPU 逻辑核数之间。
手动设置优先于自动值，且不受内存或 CPU 上限截断：编译读取 `JOBS`，命令行 `-j/--jobs` 优先；链接读取 `LLVM_LINK_JOBS`，配方中的 `--link-jobs` 优先。
runtimes 子构建默认取编译和链接并发的较小值，可用 `CMAKE_BUILD_PARALLEL_LEVEL` 覆盖；安装阶段也遵循编译并发设置。

---

### 快速开始

#### 1. 安装系统依赖

```bash
./install-prerequisites.sh

# 无 root 权限时，从源码编译 flex/bison/texinfo 到 $HOME/.local
./install-flex-bison.sh
```

#### 2. 构建 GCC 工具链

```bash
# glibc 工具链
./build-toolchain-gcc.sh --arch aarch64 --libc glibc

# musl 工具链
./build-toolchain-gcc.sh --arch riscv64 --libc musl

# bare-metal ELF 工具链 (newlib)
./build-toolchain-elf.sh --arch riscv64

# 使用 git 最新开发版，每次构建同步远端
./build-toolchain-gcc.sh --arch riscv64 --libc glibc --gcc-ver git

# 同时编译 gdb (默认不编译, 需 binutils 使用 git 源)
./build-toolchain-gcc.sh --arch riscv64 --libc glibc --binutils-ver git --enable-gdb

# 全新构建（清除旧 build/log/install 目录）
./build-toolchain-gcc.sh --arch aarch64 --libc glibc --fresh

# 批量构建
./build-toolchain-gcc-batch.sh --arch aarch64,riscv64,x86_64 --libc glibc
```

#### 3. 构建 LLVM/Clang

```bash
# 自动下载 LLVM 22.1.8 并构建（需先有 GCC 工具链）
./build-toolchain-llvm.sh \
    --arch aarch64 \
    --target-sysroot ./cross-aarch64-linux-gnu/aarch64-linux-gnu \
    --toolchain-dir ./cross-aarch64-linux-gnu

# 指定 LLVM 版本
./build-toolchain-llvm.sh --arch riscv64 --llvm-ver 21.1.8 \
    --target-sysroot ./cross-riscv64-linux-gnu/riscv64-linux-gnu \
    --toolchain-dir ./cross-riscv64-linux-gnu

# 使用 git 最新版
./build-toolchain-llvm.sh --arch riscv64 --llvm-ver git \
    --target-sysroot ./cross-riscv64-linux-gnu/riscv64-linux-gnu \
    --toolchain-dir ./cross-riscv64-linux-gnu

# 批量构建单版本 × 多架构（--llvm-ver 和 --toolchain-dir 必填）
./build-toolchain-llvm-batch.sh --llvm-ver 22.1.8 -a riscv64,aarch64 \
    --toolchain-dir ./cross-{ARCH}-linux-gnu

# 指定工作目录
./build-toolchain-llvm-batch.sh --llvm-ver 22.1.8 -a riscv64,aarch64 \
    --toolchain-dir ./gcc_161/cross-{ARCH}-linux-gnu --work-dir ./llvm_2218
```

LLVM 批量入口每次只接受一个版本，可同时构建多个架构。构建不同版本时，分别调用并使用不同的
`--work-dir`；`run-build-presets.sh` 已按此方式组织配方。

#### 4. 交叉编译 BusyBox 与 Linux 内核

```bash
# BusyBox (生成 initramfs)
./build-busybox.sh --arch riscv64 \
    --cross-compile ./cross-riscv64-linux-gnu/bin/riscv64-linux-gnu-

# BusyBox 使用 git 源码
./build-busybox.sh --arch riscv64 --busybox-ver git:1_37_0 \
    --cross-compile ./cross-riscv64-linux-gnu/bin/riscv64-linux-gnu-

# 同时编译 CoreMark 性能测试程序 (git master, 自带 Makefile, 静态链接)
# 打包为 initramfs 内 /root/coremark, 并输出 coremark-<arch> 独立产物
./build-busybox.sh --arch riscv64 --coremark \
    --cross-compile ./cross-riscv64-linux-gnu/bin/riscv64-linux-gnu-

# 打包额外文件/目录到 initramfs (可多次指定, 默认放入 /root/)
./build-busybox.sh --arch riscv64 --coremark \
    --cross-compile ./cross-riscv64-linux-gnu/bin/riscv64-linux-gnu- \
    --add-file ./my-bench:/root/my-bench

# Linux 内核
./build-kernel.sh --arch riscv64 \
    --cross-compile ./cross-riscv64-linux-gnu/bin/riscv64-linux-gnu-

# Linux 内核使用 git 源码
./build-kernel.sh --arch riscv64 --linux-ver git:v6.12 \
    --cross-compile ./cross-riscv64-linux-gnu/bin/riscv64-linux-gnu-

# Linux 内核使用自定义最小配置 (configs/kernel/ 内置各架构 qemu-virt 最小 config，默认不使用)
./build-kernel.sh --arch riscv64 \
    --cross-compile ./cross-riscv64-linux-gnu/bin/riscv64-linux-gnu- \
    --defconfig configs/kernel/riscv64_qemu_virt_min_defconfig
```

#### 5. 交叉编译第三方库

```bash
./build-target-libs.sh \
    --target aarch64-linux-gnu \
    --toolchain-dir ./cross-aarch64-linux-gnu

# 仅编译 / 跳过指定库
./build-target-libs.sh --target riscv64-linux-gnu \
    --toolchain-dir ./cross-riscv64-linux-gnu \
    --only zlib --only zstd
```

---

### 通用选项

以下选项在所有 `build-toolchain-*.sh` 脚本中通用：

| 选项 | 说明 |
|------|------|
| `--work-dir` | 工作目录前缀 |
| `--jobs` / `-j` | 并行编译线程数 |
| `--mirror` | 下载镜像源（默认 `mirrors.bfsu.edu.cn`） |
| `--fresh` | 构建前清除已有 build/log/install 目录 |
| `--clean` | 构建后删除构建目录和日志 |
| `--archive` | 构建后打包为 tar.xz 并删除原目录 |
| `--static` | 静态链接工具链自身的可执行文件，可拷贝到同架构其他机器执行 |

编译并发统一按命令行 `-j/--jobs` > `JOBS` 环境变量 > 自动检测的优先级设置。
参数使用 `-j/--jobs` 指定编译并发、`--组件-ver` 指定组件版本，源码、构建、安装等目录使用 `--xxx-dir`。
LLVM 批量入口使用 `--llvm-ver`，工具链目录使用 `--toolchain-dir`（批量入口允许 `{ARCH}` 模板）。
QEMU 使用 `--src-dir`、`--build-dir`、`--install-dir`；flex/bison 安装脚本同样使用 `--install-dir`。
`--src-dir` 在 GCC 构建入口中指多组件源码的存放目录，在 LLVM/QEMU/内核入口中指具体源码树。
最小内核辅助脚本的 `--toolchains-dir` 指含多套 `cross-<triple>/` 的父目录。
该辅助入口需要显式指定源码目录，以及工具链父目录或交叉编译前缀；工作目录默认当前目录，
并发沿用公共 `JOBS` 设置。路径可由 `SRC_DIR`、`TOOLCHAINS_DIR`、`CROSS_COMPILE`、`WORK_DIR`、`BUILD_DIR` 环境变量提供。
脚本中的安装根目录统一使用 `INSTALL_DIR`，组件版本使用 `*_VER`，输出路径区分
`OUTPUT_FILE` 与 `OUTPUT_DIR`；上游构建工具的 `--prefix`、`PREFIX` 和 `DESTDIR` 按各自接口传递。

`--static` 只影响工具链自身的 host 可执行文件（`gcc`/`as`/`ld`/`clang`/`lld` 等），
目标侧库（glibc/musl/newlib/libgcc/compiler-rt）仍按原方式构建，不受影响。
构建/日志/安装目录会自动追加 `-static` 后缀，与动态构建互不干扰。
需要 host 提供 `libc.a`、`libstdc++.a`（LLVM 另需 `libz.a`）。
`build-native-gcc.sh`、`build-native-llvm.sh` 与 `build-qemu.sh` 同样支持该选项。

静态构建换取可移植性，代价是失去依赖动态加载的能力：

| 能力 | 动态构建 | `--static` |
|------|----------|-----------|
| `-flto` | 可用 | 可用（走 `lto-wrapper`，不经 ld 插件） |
| `-fuse-linker-plugin` | 可用 | 报错，`liblto_plugin.so` 不生成 |
| GCC 插件 `-fplugin` | 可用 | 报错 `plugin support is disabled` |
| gdb Python 脚本 / TUI | 可用 | 不可用（`--without-python --disable-tui`） |
| LLVM `libclang.so` / `libclang-cpp.so` | 生成 | 不生成（`LLVM_ENABLE_PIC=OFF`），依赖 C API 的工具无法链接 |

`--static` 可与 `--enable-gdb` 同用，但要求 host 提供 `libgmp.a`/`libmpfr.a`（gdb 14+ 依赖 GMP/MPFR）：
DEB 系由 `install-prerequisites.sh` 安装的 `libgmp-dev`/`libmpfr-dev` 本身就含静态库，
RPM 系可能需额外安装 `gmp-static`/`mpfr-static`；缺失时构建会直接报错而不是静默降级。
静态 gdb 会关闭 python/TUI/gdbserver 以保证全静态链接。

发行版不提供静态库时，可用 `./install-flex-bison.sh --with-gmp-mpfr` 从源码编译到 `~/.local`，
之后导出两个变量（缺一不可）：

```bash
export LIBRARY_PATH="$HOME/.local/lib:$LIBRARY_PATH"        # gcc 找 libgmp.a/libmpfr.a
export C_INCLUDE_PATH="$HOME/.local/include:$C_INCLUDE_PATH" # gdb configure 找 gmp.h/mpfr.h
```

此外静态可执行文件中的 `dlopen` 需要运行时存在与链接时同版本的 glibc 共享库，
拷贝到其他机器后不可靠，因此任何插件机制都不应依赖。
需要插件、`libclang` 或链接期 LTO 插件时，请使用动态构建。

### 版本参数 git 格式

版本参数（如 `--gcc-ver`、`--llvm-ver`）支持 `git[:REF]` 格式：

| 格式 | 行为 |
|------|------|
| `git` | 每次获取远端当前默认分支，支持默认分支改名或切换 |
| `git:REF` | 每次获取远端指定分支、标签或完整 `refs/...` 当前指向的提交 |
| `git:SHA` | 使用完整提交 SHA 固定版本，本地已有对象时直接复用 |

已移除更新开关及旧的 `:update` 后缀。原 `git:update` 改为 `git`，
原 `git:REF:update` 改为 `git:REF`；`git:update` 现在按普通引用解析，表示名为 `update` 的分支或标签。

分支与标签同名时，使用 `git:refs/heads/NAME` 或 `git:refs/tags/NAME` 明确选择。
也支持远端公布的其他完整 `refs/...` 引用。提交使用完整的 40 位或 64 位 SHA，
远端必须允许抓取该对象；不支持 `HEAD~1` 等修订表达式。

Git 源码以 detached HEAD 保存，并记录实际提交。缓存用于减少对象传输，命名引用仍每次查询并抓取远端；
联网或抓取失败会报错，不会静默使用旧源码。需要可复现构建或离线复用时，使用本地已有的完整提交 SHA。
旧缓存会校验 Git 工作树和 origin，拒绝冒用其他仓库或不完整的克隆。
切换提交时若有已跟踪的本地修改，构建会停止；未跟踪文件由 Git 的 checkout 冲突保护处理。
同一提交的缓存复用会保留源码补丁。切换版本时请配合 `--fresh` 重建工具链。

同一源码目录的获取操作使用独占锁；异常退出遗留的 `<源码目录>.git-lock`，
应确认没有任务仍在使用后再手动删除。不同 REF 的并行构建请使用独立的源码目录。

`build-qemu.sh` 的 `--ref` 使用相同的引用规则，命名引用默认同步远端；
本地非 Git 源码目录仍可直接使用。
`build-packages.py` 的 recipe 使用 `git_ref`，默认同步命名引用，不再提供额外更新开关；
子模块会按父仓库记录的提交同步，构建清单记录实际 `git_commit`。

源码归档沿用原有下载与源码目录。首次解压到同级临时目录，`tar` 成功后才原子移动到最终目录；
失败会清理临时目录，已有源码目录直接复用，不额外记录来源或计算哈希。

---

### 构建产物

工具链默认安装在 `cross-<TARGET>/` 目录下：

```
cross-aarch64-linux-gnu/
├── bin/                    # 交叉编译工具（gcc, g++, ld, as, ...）
├── lib/                    # 编译器运行时库
├── libexec/                # 编译器内部工具
├── aarch64-linux-gnu/      # 目标 sysroot
│   ├── include/
│   └── lib/
└── share/
```

```bash
export PATH="$(pwd)/cross-aarch64-linux-gnu/bin:$PATH"
aarch64-linux-gnu-gcc -o hello hello.c
```

---

### macOS 构建

```bash
./install-prerequisites.sh  # 已安装 Homebrew 和 Xcode Command Line Tools
./env-macos.sh ./build-toolchain-gcc.sh --arch riscv64 --libc glibc
./env-macos.sh ./build-toolchain-gcc-batch.sh --arch aarch64,riscv64 --libc glibc
```

`env-macos.sh` 默认使用 Homebrew GCC 编译主机工具，包括 Linux 头文件工具使用的
`HOSTCC`/`HOSTCXX` 和 glibc 使用的 `BUILD_CC`。macOS 的 `/usr/bin/gcc`
实际是 Apple Clang；仅设置 `CC` 不会覆盖 Kbuild 中的 `HOSTCC = gcc`。
`CC`/`CXX` 及上述变量都可通过环境变量覆盖；`BUILD_CC`/`HOSTCC` 默认跟随
`CC`，`HOSTCXX` 默认跟随 `CXX`。Homebrew GCC 版本可用 `GCC_MAJOR` 指定。
同时指定 `CC` 和 `CXX` 时不要求安装 Homebrew GCC。

其他脚本也应通过 `env-macos.sh` 执行，以使用 Homebrew Bash、Python 和 GNU 工具。
本次 macOS ARM64 检查的范围如下（Linux 目标为 `riscv64-linux-gnu`，newlib 目标为 `riscv64-unknown-elf`）：

| 脚本 | macOS 状态与范围 |
|------|-----------------|
| `build-toolchain-gcc.sh`、`test-toolchain.sh` | glibc 工具链已完成构建；C/C++/Fortran 编译链接测试已通过，使用 `--run-mode none` |
| `build-busybox.sh` | 已实测 BusyBox 1.38.0 静态编译和 cpio 打包；未测试内核启动 |
| `build-target-libs.sh`、`build-packages.py` | 修复 zlib、lz4、zstd 的 Linux 目标系统选择；这三个库已实测。Python 入口另验证静态构建，zstd 使用上游 CMake 的共享库开关；其他包未逐一验证 |
| `build-qemu.sh` | QEMU 11.0.0 的 riscv64 系统模拟已完整构建安装，并验证版本查询、TCG virt 机器初始化；本次未启用 libslirp，未启动 Linux 内核 |
| `install-prerequisites.sh` | 新增 Homebrew 分支，已用替身命令验证，测试不会实际安装软件 |
| `build-toolchain-gcc-batch.sh`、`run-build-presets.sh` | 沿用子脚本的兼容性，未跑完整架构/版本矩阵 |
| `prepare-gcc.sh`、`get-latest-versions.sh`、`install-flex-bison.sh` | GNU 工具由封装脚本提供，本次未做完整联网/构建验证 |
| `build-native-llvm.sh` | LLVM 22.1.8 默认项目、四个后端及运行库已完整构建安装，启用 sanitizer；修复默认 SDK 路径后，清空 SDK 环境的本机 C/C++/Fortran、ASan 编译运行通过，显式覆盖 sysroot 的 RISC-V Linux C/C++ 链接通过 |
| `build-toolchain-llvm.sh` | 修复 Linux 目标运行库的平台选择及 C 编译器工具链路径；LLVM 22.1.8 的 clang/lld/flang、RISC-V compiler-rt/flang-rt 已完整构建安装，C/C++/Fortran 静态和动态链接共 6 项通过，另验证 compiler-rt builtins 链接；未执行目标程序 |
| `build-toolchain-llvm-batch.sh` | 沿用子脚本的兼容性，未跑完整架构/版本矩阵 |
| `build-toolchain-elf.sh` | Binutils 2.47 + GCC 16.2.0 + newlib 4.6.0.20260123 完整构建安装通过；C/C++ 使用 `--specs=nosys.specs` 链接成 RISC-V ELF，未执行裸机程序 |
| `build-native-gcc.sh` | Apple Silicon 实测失败：GNU ar 生成的 Mach-O 静态库触发对齐错误；单独配置原版 GCC 16.2.0 也报不支持 `aarch64-apple-darwin`，需要 Darwin 源码补丁及工具链流程适配 |
| `build-kernel.sh`、`build-mini-kernel.sh` | 暂不适配：完整内核还需处理主机 ELF 头文件等依赖 |

```bash
# 交叉构建 BusyBox + initramfs
./env-macos.sh ./build-busybox.sh --arch riscv64 \
    --cross-compile ./cross-riscv64-linux-gnu/bin/riscv64-linux-gnu-

# 交叉构建目标库
./env-macos.sh ./build-target-libs.sh --target riscv64-linux-gnu \
    --toolchain-dir ./cross-riscv64-linux-gnu --only zlib --only lz4 --only zstd

# 原生 LLVM：默认项目和后端，包含 Flang 与 sanitizer
CMAKE_BUILD_PARALLEL_LEVEL=3 CC=clang CXX=clang++ \
    ./env-macos.sh ./build-native-llvm.sh --link-jobs 1 -j 3

# 在 macOS 上运行、默认生成 RISC-V Linux 程序的 LLVM 工具链
CMAKE_BUILD_PARALLEL_LEVEL=3 CC=clang CXX=clang++ \
    ./env-macos.sh ./build-toolchain-llvm.sh --arch riscv64 \
    --toolchain-dir ./cross-riscv64-linux-gnu \
    --target-sysroot ./cross-riscv64-linux-gnu/riscv64-linux-gnu \
    --link-jobs 1 -j 3

# newlib 裸机工具链
./env-macos.sh ./build-toolchain-elf.sh --arch riscv64 -j 4

# QEMU 系统模拟；--deps 用 Homebrew 安装 QEMU 额外依赖
CC=clang CXX=clang++ ./env-macos.sh ./build-qemu.sh --arch riscv64 --deps

# 不联网、不安装软件的分支回归检查
./env-macos.sh python3 test/test-macos-compat.py
```

QEMU 的 `*-linux-user` 目标需要 Linux 主机，参见
[上游 configure 的主机检查](https://github.com/qemu/qemu/blob/master/configure)。
macOS 可使用系统模拟；`test/test-qemu-run.sh` 需要另行准备 Linux 内核和 initramfs，
本次未验证启动流程。构建 macOS 主机可执行文件时不要使用 `--static`；
交叉编译给 Linux 使用的静态程序（如 BusyBox）不受此限制。
newlib 的 `nosys.specs` 仅提供空系统调用用于链接检查；板级 I/O 需要目标平台实现。

`build-native-llvm.sh` 在 macOS 上使用 `xcrun --sdk macosx --show-sdk-path` 获取
安装后 clang/flang 的默认 SDK，也可在构建时用绝对路径 `SDKROOT` 覆盖。
使用原生 LLVM 交叉编译时，可用 `--sysroot` 显式选择目标系统的 sysroot。
Flang 的部分源文件编译时占用数 GB 内存；16 GB 内存的机器建议从上述并发设置开始，
顺序构建两套 LLVM。`CMAKE_BUILD_PARALLEL_LEVEL` 同时限制运行库子构建的并发。

本机 Homebrew GCC 16.2.0 的配方会应用 Darwin 维护分支的 Apple Silicon 支持补丁，
所以 `brew install gcc` 可用并不意味着本脚本下载的原版 GCC 可以构建同一目标。
`build-native-gcc.sh` 还会优先使用刚安装的 GNU binutils；实测其中的 `ar` 生成的
静态库被 Apple 链接器拒绝（`64-bit mach-o member ... not 8-byte aligned`）。
这两项需要一起处理，超出了仅调整 shell 参数的范围，本次没有引入 GCC 源码补丁。

完整内核还需要在 macOS 上编译、运行 `modpost` 等主机工具。实测 Homebrew
`libelf 0.8.13_1` 的 `pkg-config --cflags libelf` 能提供 `libelf.h`，但没有内核
直接引用的 `elf.h` 和 `byteswap.h`。用临时包装头文件补齐后，`mk_elfconfig`
可以工作，`modpost` 仍缺少 `STT_SPARC_REGISTER`、`R_386_PC32` 和多项 ARM/MIPS
重定位常量。因此不能仅靠增加 include 路径支持完整内核；还需完整 ELF 定义和
主机兼容处理。启用 objtool、BTF 等配置后需要另外验证对应工具及依赖。

---

### 测试

构建产物可通过 QEMU 做冒烟测试：

```bash
# 1) 编译器冒烟测试：编译 C/C++/Fortran 并在 qemu-user 下运行
#    需要 qemu-<arch>（系统包 qemu-user，或用 build-qemu.sh 构建）
./test-toolchain.sh --toolchain-dir ./cross-riscv64-linux-gnu --target riscv64-linux-gnu

# CI 严格模式：缺少选定语言编译器或需要运行的 QEMU 时判定失败
./test-toolchain.sh --toolchain-dir ./cross-riscv64-linux-gnu \
    --target riscv64-linux-gnu --languages c,c++,fortran --strict

# 仅编译（无 qemu 环境）/ 额外测试动态链接与共享库加载
./test-toolchain.sh --toolchain-dir ./cross-aarch64-linux-gnu \
    --target aarch64-linux-gnu --run-mode none
./test-toolchain.sh --toolchain-dir ./cross-aarch64-linux-gnu \
    --target aarch64-linux-gnu --run-mode all --qemu-dir ./qemu-install/bin

# 2) 系统模拟冒烟测试：启动交叉编译的内核 + initramfs
./test/test-qemu-run.sh riscv64 aarch64 --qemu-dir ./qemu-install/bin

# 从源码构建 QEMU（当系统未提供所需版本/架构时）
# 默认不安装系统依赖；首次构建可加 --deps 自动装依赖（需 sudo）
./build-qemu.sh --arch aarch64,loongarch64,riscv64,x86_64 --deps
```

`--run-mode none` 或 static 模式中主动省略的动态运行不属于必需项缺失；
严格模式只对选定但无法执行的测试判定失败。系统模拟测试若全部跳过，也会返回失败。
批量构建会继续执行后续任务并汇总所有失败，最终只要有失败就返回非零退出码。
Python 构建清单会保留每个请求的成功或失败结果，包括源码获取失败和不支持的构建方式。

---

### CI/CD

项目包含三个 GitHub Actions 工作流：

- **`build.yml`**：构建 GCC 工具链，经 `test-toolchain.sh` 冒烟测试后发布到 GitHub Release
- **`build-images.yml`**：构建 BusyBox initramfs 和 Linux 内核，上传到 Release
- **`build-mini-kernel.yml`**：用系统交叉编译器构建 qemu-virt 最小内核（configs/kernel/），
  经系统 QEMU 启动+关机验证后发布到独立 Release（tag: latest-mini-kernels，提供 `<arch>-boot-min.tar.gz` 整包及 `<arch>-coremark` 分立文件）

产物包含：
- `cross-<arch>-linux-<libc>.tar.xz` — GCC 交叉编译工具链
- `busybox-<arch>` — BusyBox 静态链接二进制
- `coremark-<arch>` — CoreMark 静态链接二进制 (git master)
- `initrd-<arch>.cpio` — BusyBox initramfs (内置 /root/coremark)
- `<arch>-boot.tar.gz` — 标准内核整包（内核镜像 vmlinux/Image/bzImage + config + System.map + initrd.cpio + busybox + coremark，内核产物仅随整包发布）
- `<arch>-kernel.tar.gz` / `<arch>-kernel-min.tar.gz` — 内核单独包（内核镜像 + config + System.map，不含 initrd/busybox）
- `<arch>-boot-min.tar.gz` — qemu-virt 最小内核整包（解压出 `<arch>-boot-min/` 目录: 内核镜像 + config + System.map + initrd.cpio + busybox + coremark）
