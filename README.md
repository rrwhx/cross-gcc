## Cross GCC / LLVM 交叉编译工具链构建套件

从源码构建完整的交叉编译工具链，支持多架构、多 C 库组合。

### 支持的目标

- **架构**：`aarch64` · `loongarch64` · `riscv32` · `riscv64` · `i686` · `x86_64` · `mips` · `mipsel` · `mips64` · `mips64el`
- **C 库**：**glibc** · **musl** · **newlib**（bare-metal ELF）

---

### 文件说明

| 文件 | 用途 |
|------|------|
| `build-toolchain-generic.sh` | 核心脚本：构建 GCC + binutils + glibc/musl 工具链 |
| `build-toolchain-elf.sh` | 构建 GCC + binutils + newlib（bare-metal ELF）工具链 |
| `build-cross-llvm.sh` | 基于已有 GCC 工具链构建 LLVM/Clang 交叉编译器 |
| `build-target-libs.sh` | 交叉编译目标平台第三方库（zlib, zstd, lz4, snappy 等） |
| `build_all.sh` | 批量构建多架构 × 多 libc 组合 |
| `lib.sh` | 公共函数库（下载、日志、构建辅助） |
| `install_prerequest.sh` | 安装系统级构建依赖（apt/dnf/pacman） |
| `install_flex_bison.sh` | 从源码编译安装 flex + bison + texinfo（无 root 权限时使用） |
| `prepare_gcc.sh` | GCC 源码预处理（下载 gmp/mpfr/mpc/isl 等依赖） |
| `run_macos.sh` | macOS 环境适配封装（自动设置 GNU 工具路径） |
| `.github/workflows/build.yml` | GitHub Actions CI 构建工作流 |

---

### 快速开始

#### 1. 安装系统依赖

```bash
./install_prerequest.sh

# 无 root 权限时，从源码编译 flex/bison/texinfo 到 $HOME/.local
./install_flex_bison.sh
```

#### 2. 构建工具链

```bash
# glibc 工具链
./build-toolchain-generic.sh --arch aarch64 --libc glibc

# musl 工具链
./build-toolchain-generic.sh --arch riscv64 --libc musl

# bare-metal ELF 工具链 (newlib)
./build-toolchain-elf.sh --arch riscv64

# 批量构建（默认 10 架构 × 2 libc = 20 组合）
./build_all.sh
./build_all.sh --arch aarch64,riscv64,x86_64 --libc glibc
```

#### 3. 构建 LLVM/Clang（需先有 GCC 工具链）

```bash
./build-cross-llvm.sh \
    --arch aarch64 \
    --src-dir ./llvm-project-llvmorg-22.1.1 \
    --target-sysroot ./cross-aarch64-linux-gnu/aarch64-linux-gnu \
    --target-gcc-toolchain ./cross-aarch64-linux-gnu
```

#### 4. 交叉编译第三方库

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

### `build-toolchain-generic.sh` 参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--arch` | 目标架构（必填） | — |
| `--libc` | C 库类型 glibc/musl（必填） | — |
| `--gcc-ver` | GCC 版本（支持 `git`） | `15.2.0` |
| `--binutils-ver` | binutils 版本 | `2.45` |
| `--glibc-ver` | glibc 版本 | `2.42` |
| `--musl-ver` | musl 版本 | `1.2.5` |
| `--linux-ver` | Linux 内核头文件版本 | `6.17.6` |
| `--work-dir` | 工作目录前缀 | 当前目录 |
| `--install-dir` | 工具链安装路径 | `WORK_DIR/cross-TARGET` |
| `--threads` | 并行编译线程数 | `nproc` |
| `--mirror` | 下载镜像源 | `mirrors.tuna.tsinghua.edu.cn` |
| `--clean` | 构建后删除构建目录 | 关闭 |
| `--archive` | 构建后打包为 tar.xz | 关闭 |
| `--enable-sanitizer` | 开启 GCC sanitizer | 关闭 |

### 版本定制与高级用法

```bash
# 指定版本
./build-toolchain-generic.sh --arch aarch64 --libc glibc \
    --gcc-ver 14.1.0 --glibc-ver 2.41

# 使用 GCC git 最新开发版 + 批量构建
./build_all.sh --arch aarch64,riscv64,x86_64 --libc glibc \
    --gcc-ver git --glibc-ver 2.43 --work-dir gcc_latest-glibc243

# 构建后自动打包并清理
./build-toolchain-generic.sh --arch riscv64 --libc musl --clean --archive

# macOS 构建（需先安装 GNU 工具）
brew install bash gnu-sed gawk make bison rsync grep coreutils gcc
./run_macos.sh ./build_all.sh --arch aarch64,riscv64 --libc glibc
```

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
