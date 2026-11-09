#!/usr/bin/env python3
"""无需下载或安装依赖的 macOS/Linux 分支回归检查。

运行: ./env-macos.sh python3 test/test-macos-compat.py
"""
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("build_packages", ROOT / "build-packages.py")
build_packages = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = build_packages
spec.loader.exec_module(build_packages)


class MacOSCompatibility(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cross-gcc-compat-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.trace = self.work / "trace"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TRACE=str(self.trace), JOBS="2", TEST_OS="Darwin")
        for key in ("CC", "CXX", "HOSTCC", "HOSTCXX", "BUILD_CC", "GCC_MAJOR", "CHOST"):
            self.env.pop(key, None)
        self.script(self.bin / "uname", 'printf "%s\\n" "$TEST_OS"')
        for name in ("make", "brew"):
            self.script(self.bin / name, 'printf "%s\\n" "$0 $*" >> "$TRACE"')
        self.script(self.bin / "python3", "exit 0")
        self.src = self.work / "qemu"
        self.src.mkdir()
        self.script(self.src / "configure", 'printf "%s\\n" "$*" >> "$TRACE"')

    @staticmethod
    def script(path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def run_script(self, name, *args):
        return subprocess.run([BASH, str(ROOT / name), *map(str, args)],
                              cwd=self.work, env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def qemu(self, *args):
        return self.run_script("build-qemu.sh", "--src-dir", self.src,
                               "--build-dir", self.work / "build",
                               "--install-dir", self.work / "install", "--no-install", *args)

    def test_qemu_targets(self):
        cases = [
            ("Darwin", [], "riscv64-softmmu"),
            ("Linux", [], "riscv64-softmmu,riscv64-linux-user"),
            ("Darwin", ["--arch", "i686,aarch64"], "i386-softmmu,aarch64-softmmu"),
            ("Linux", ["--arch", "i686"], "i386-softmmu,i386-linux-user"),
            ("Linux", ["--static"], "riscv64-softmmu,riscv64-linux-user"),
            ("Darwin", ["--arch", "i686", "--targets", "aarch64-softmmu"], "aarch64-softmmu"),
        ]
        for host, args, targets in cases:
            with self.subTest(host=host, args=args):
                self.env["TEST_OS"] = host
                self.trace.write_text("")
                result = self.qemu(*args)
                self.assertEqual(result.returncode, 0, result.stdout)
                configure_args = shlex.split(self.trace.read_text().splitlines()[0])
                self.assertIn(f"--target-list={targets}", configure_args)
                self.assertEqual("--static" in configure_args, "--static" in args)

    def test_qemu_unsupported_options_fail_before_build(self):
        for args in (["--targets", "riscv64-linux-user"],
                     ["--targets", "aarch64-softmmu,riscv64-linux-user"], ["--static"]):
            with self.subTest(args=args):
                result = self.qemu("--deps", *args)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(self.trace.exists(), "不应安装依赖或调用 configure/make")

    def test_homebrew_dependencies(self):
        result = self.run_script("install-prerequisites.sh")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("brew install bash gcc make", self.trace.read_text())
        self.trace.write_text("")
        result = self.qemu("--deps")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("brew install python ninja meson pkgconf glib pixman libslirp", self.trace.read_text())

    def test_compiler_overrides_and_exit_status(self):
        # 只选择 Clang 时无需安装 Homebrew GCC。
        prefix = self.work / "brew"
        (prefix / "bin").mkdir(parents=True)
        (prefix / "bin/bash").symlink_to(BASH)
        self.script(prefix / "opt/make/libexec/gnubin/make", "exit 0")
        self.env.update(HOMEBREW_PREFIX=str(prefix), CC="clang", CXX="clang++")
        result = self.run_script("env-macos.sh", BASH, "-c",
                                 'printf "compilers=%s,%s,%s,%s,%s\\n" "$CC" "$CXX" "$BUILD_CC" "$HOSTCC" "$HOSTCXX"; exit 42')
        self.assertEqual(result.returncode, 42, result.stdout)
        self.assertIn("compilers=clang,clang++,clang,clang,clang++", result.stdout)
        self.env.update(BUILD_CC="build-cc", HOSTCC="host-cc", HOSTCXX="host-cxx")
        result = self.run_script("env-macos.sh", BASH, "-c", 'echo "$BUILD_CC,$HOSTCC,$HOSTCXX"')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("build-cc,host-cc,host-cxx", result.stdout)

    def test_linux_dependencies_include_cmake(self):
        self.env["TEST_OS"] = "Linux"
        self.script(self.bin / "sudo", 'exec "$@"')
        self.script(self.bin / "apt-get", 'printf "%s\\n" "$*" >> "$TRACE"')
        result = self.run_script("install-prerequisites.sh")
        self.assertEqual(result.returncode, 0, result.stdout)
        packages = shlex.split(self.trace.read_text())
        self.assertIn("cmake", packages)
        self.assertIn("build-essential", packages)
        self.assertNotIn("brew", packages)

    def test_llvm_linux_runtimes_keep_host_configuration_separate(self):
        self.script(self.bin / "cmake", 'printf "%s\\n" "$@" >> "$TRACE"')
        self.script(self.bin / "ninja", "exit 0")
        toolchain = self.work / "cross-gcc"
        sysroot = toolchain / "riscv64-linux-gnu"
        sysroot.mkdir(parents=True)
        for host, with_sysroot in (("Darwin", True), ("Linux", True), ("Linux", False)):
            with self.subTest(host=host, with_sysroot=with_sysroot):
                self.env["TEST_OS"] = host
                self.trace.write_text("")
                args = ["--arch", "riscv64", "--src-dir", self.src,
                        "--work-dir", self.work]
                if with_sysroot:
                    args += ["--toolchain-dir", toolchain,
                             "--target-sysroot", sysroot]
                result = self.run_script("build-toolchain-llvm.sh", *args)
                self.assertEqual(result.returncode, 0, result.stdout)
                configure = self.trace.read_text().splitlines()
                # 主机构建保持 native；只有两套目标运行库子构建使用 Linux。
                self.assertNotIn("-DCMAKE_SYSTEM_NAME=Linux", configure)
                for kind in ("BUILTINS", "RUNTIMES"):
                    prefix = f"-D{kind}_CMAKE_ARGS="
                    runtime = next(arg[len(prefix):] for arg in configure
                                   if arg.startswith(prefix)).split(";")
                    self.assertIn("-DCMAKE_SYSTEM_NAME=Linux", runtime)
                    if with_sysroot:
                        self.assertIn(f"-DCMAKE_SYSROOT={sysroot.resolve()}", runtime)
                        for lang in ("C", "CXX"):
                            self.assertIn(f"-DCMAKE_{lang}_FLAGS=--gcc-toolchain={toolchain.resolve()}", runtime)
                    else:
                        self.assertFalse(any(arg.startswith("-DCMAKE_SYSROOT=") for arg in runtime))

    def test_native_llvm_sdk_default_and_override(self):
        self.script(self.bin / "cmake", 'printf "%s\\n" "$@" >> "$TRACE"')
        self.script(self.bin / "ninja", "exit 0")
        sdk = self.work / "MacOSX.sdk"
        custom_sdk = self.work / "custom SDK"
        sdk.mkdir()
        custom_sdk.mkdir()
        self.env["TEST_SDK"] = str(sdk)
        for host, override in (("Darwin", ""), ("Darwin", str(custom_sdk)),
                               ("Linux", "")):
            with self.subTest(host=host, override=override):
                self.env.update(TEST_OS=host, SDKROOT=override)
                self.trace.write_text("")
                # SDKROOT 已提供或 Linux 主机时，不应调用 xcrun。
                self.script(self.bin / "xcrun", 'printf "%s\\n" "$TEST_SDK"'
                            if host == "Darwin" and not override else "exit 99")
                result = self.run_script("build-native-llvm.sh", "--src-dir", self.src,
                                         "--work-dir", self.work)
                self.assertEqual(result.returncode, 0, result.stdout)
                configure = self.trace.read_text().splitlines()
                if host == "Darwin":
                    self.assertIn(f"-DDEFAULT_SYSROOT={override or sdk}", configure)
                else:
                    self.assertFalse(any(arg.startswith("-DDEFAULT_SYSROOT=") for arg in configure))
        self.env.update(TEST_OS="Darwin", SDKROOT=str(self.work / "missing-sdk"))
        self.trace.write_text("")
        result = self.run_script("build-native-llvm.sh", "--src-dir", self.src,
                                 "--work-dir", self.work)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.trace.read_text(), "")

    def test_cross_libraries_keep_target_rules_during_install(self):
        for native, target in ((False, "riscv64-linux-gnu"), (False, "x86_64-w64-mingw32"), (True, "")):
            for static in (False, True):
                args = SimpleNamespace(target=target, native=native, static=static,
                                       no_install=False, jobs=2, work_dir=str(self.work),
                                       install_dir="", toolchain_dir="", cc="", cxx="")
                engine = build_packages.BuildEngine(args)
                zlib_env = engine._link_env(build_packages.PACKAGES["zlib"])
                if native:
                    self.assertEqual(zlib_env.get("CHOST"), engine.env.get("CHOST"))
                else:
                    self.assertEqual(zlib_env["CHOST"], target)
                with self.subTest(native=native, target=target, static=static, package="lz4"):
                    with patch.object(build_packages, "run_cmd", return_value=SimpleNamespace(returncode=0)) as run:
                        with patch.object(engine, "_collect_outputs"):
                            engine._build_make(build_packages.PACKAGES["lz4"], self.src,
                                               self.work / "lib-build", self.work / "install",
                                               SimpleNamespace(commands=[]))
                    self.assertEqual(run.call_count, 2)
                    for call in run.call_args_list:
                        self.assertEqual("TARGET_OS=Linux" in call.args[0], not native and "-linux-" in target)

    def test_zstd_static_build_disables_shared_library(self):
        for static in (False, True):
            with self.subTest(static=static):
                args = SimpleNamespace(target="riscv64-linux-gnu", native=False,
                                       static=static, no_install=False, jobs=2,
                                       work_dir=str(self.work), install_dir="",
                                       toolchain_dir="", cc="", cxx="")
                engine = build_packages.BuildEngine(args)
                package = build_packages.PACKAGES["zstd"]
                self.assertEqual(package.build_system, "cmake")
                with patch.object(build_packages, "run_cmd", return_value=SimpleNamespace(returncode=0)) as run:
                    with patch.object(engine, "_collect_outputs"):
                        engine._build_cmake(package, self.src, self.work / "lib-build",
                                            self.work / "install", SimpleNamespace(commands=[]))
                configure = run.call_args_list[0].args[0]
                self.assertIn("-DCMAKE_SYSTEM_NAME=Linux", configure)
                self.assertEqual("-DZSTD_BUILD_SHARED=OFF" in configure, static)
                self.assertEqual("-DCMAKE_EXE_LINKER_FLAGS=-static" in configure, static)


if __name__ == "__main__":
    unittest.main()
