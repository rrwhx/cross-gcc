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
| `build-toolchain-generic.sh` | 核心脚本：构建 GCC + binutils + glibc/musl 工具链 |
| `build-toolchain-elf.sh` | 构建 GCC + binutils + newlib（bare-metal ELF）工具链 |
| `build-toolchain-llvm.sh` | 构建 LLVM/Clang 交叉编译器（支持自动下载源码） |
| `build-target-libs.sh` | 交叉编译目标平台第三方库（zlib, zstd, lz4, snappy, jemalloc 等） |
| `build-busybox.sh` | 交叉编译 BusyBox 并生成 initramfs |
| `build-kernel.sh` | 交叉编译 Linux 内核 |
| `build-all.sh` | 批量构建多架构 × 多 libc 组合 |
| `lib.sh` | 公共函数库（下载、git 克隆、日志、构建辅助） |
| `install-prerequisites.sh` | 安装系统级构建依赖（apt/dnf/pacman） |
| `install-flex-bison.sh` | 从源码编译安装 flex + bison + texinfo |
| `prepare-gcc.sh` | GCC 源码预处理（下载 gmp/mpfr/mpc/isl 等依赖） |
| `get-latest-versions.sh` | 获取各组件最新发布版本号 |
| `env-macos.sh` | macOS 环境适配封装（自动设置 GNU 工具路径） |
| `build-all-llvm.sh` | 批量构建多版本 × 多架构 LLVM 工具链 |
| `run-build-all.sh` | 批量构建多版本 GCC 的配方脚本 |
| `test-toolchain.sh` | 工具链冒烟测试：编译 C/C++/Fortran 并经 qemu-user 运行 |
| `test/test-qemu-run.sh` | QEMU 系统模拟冒烟测试：启动内核 + initramfs |
| `build-qemu.sh` | 从源码构建 QEMU（系统模拟 + 用户态模拟），供测试脚本使用 |

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
./build-toolchain-generic.sh --arch aarch64 --libc glibc

# musl 工具链
./build-toolchain-generic.sh --arch riscv64 --libc musl

# bare-metal ELF 工具链 (newlib)
./build-toolchain-elf.sh --arch riscv64

# 使用 git 最新开发版 + 拉取更新
./build-toolchain-generic.sh --arch riscv64 --libc glibc --gcc-ver git:update

# 同时编译 gdb (默认不编译, 需 binutils 使用 git 源)
./build-toolchain-generic.sh --arch riscv64 --libc glibc --binutils-ver git --enable-gdb

# 全新构建（清除旧 build/log/install 目录）
./build-toolchain-generic.sh --arch aarch64 --libc glibc --fresh

# 批量构建
./build-all.sh --arch aarch64,riscv64,x86_64 --libc glibc
```

#### 3. 构建 LLVM/Clang

```bash
# 自动下载 LLVM 22.1.8 并构建（需先有 GCC 工具链）
./build-toolchain-llvm.sh \
    --arch aarch64 \
    --target-sysroot ./cross-aarch64-linux-gnu/aarch64-linux-gnu \
    --target-gcc-toolchain ./cross-aarch64-linux-gnu

# 指定 LLVM 版本
./build-toolchain-llvm.sh --arch riscv64 --llvm-ver 21.1.8 \
    --target-sysroot ./cross-riscv64-linux-gnu/riscv64-linux-gnu \
    --target-gcc-toolchain ./cross-riscv64-linux-gnu

# 使用 git 最新版
./build-toolchain-llvm.sh --arch riscv64 --llvm-ver git:update \
    --target-sysroot ./cross-riscv64-linux-gnu/riscv64-linux-gnu \
    --target-gcc-toolchain ./cross-riscv64-linux-gnu

# 批量构建多版本 × 多架构（--version 和 --gcc-dir 必填）
./build-all-llvm.sh -v 22.1.8,21.1.8 -a riscv64,aarch64 \
    --gcc-dir ./cross-{ARCH}-linux-gnu

# 指定工作目录
./build-all-llvm.sh -v 22.1.8 -a riscv64,aarch64 \
    --gcc-dir ./gcc_161/cross-{ARCH}-linux-gnu --work-dir ./llvm_2218
```

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
| `--threads` / `-j` | 并行编译线程数 |
| `--mirror` | 下载镜像源（默认清华） |
| `--fresh` | 构建前清除已有 build/log/install 目录 |
| `--clean` | 构建后删除构建目录和日志 |
| `--archive` | 构建后打包为 tar.xz 并删除原目录 |
| `--static` | 静态链接工具链自身的可执行文件，可拷贝到同架构其他机器执行 |

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

版本参数（如 `--gcc-ver`、`--llvm-ver`）支持 `git[:REF][:update]` 格式：

| 格式 | 行为 |
|------|------|
| `git` | 克隆默认分支 HEAD，已存在则跳过 |
| `git:update` | 克隆 HEAD，已存在则拉取最新 |
| `git:TAG` | 克隆指定 tag/branch，已存在则跳过 |
| `git:TAG:update` | 克隆指定 ref，已存在则更新到该 ref |

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
brew install bash gnu-sed gawk make bison rsync grep coreutils gcc
./env-macos.sh ./build-all.sh --arch aarch64,riscv64 --libc glibc
```

---

### 测试

构建产物可通过 QEMU 做冒烟测试：

```bash
# 1) 编译器冒烟测试：编译 C/C++/Fortran 并在 qemu-user 下运行
#    需要 qemu-<arch>（系统包 qemu-user，或用 build-qemu.sh 构建）
./test-toolchain.sh --toolchain-dir ./cross-riscv64-linux-gnu --target riscv64-linux-gnu

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
