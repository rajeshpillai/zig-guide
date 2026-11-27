# Cross-compilation

> All targets are available when you install Zig.

In Zig, cross-compilation is not a special mode. Cross-compilation is a flag:

```bash
zig build-exe main.zig -target x86_64-linux-gnu
zig build-exe main.zig -target aarch64-macos
zig build-exe main.zig -target x86_64-windows-gnu
zig build-exe main.zig -target wasm32-wasi
```

You do not install a cross toolchain, and you do not make a sysroot. Zig includes the libc sources for the targets that it supports. Zig builds the parts that it needs when it needs them.

```bash
zig targets       # everything available
```

## One source file, three platforms

The source does not change. Only the flag changes:

```
                 hello.zig
                     │
   ┌─────────────────┼─────────────────┐
   │                 │                 │
   ▼                 ▼                 ▼
x86_64-linux-gnu  x86_64-windows-gnu  aarch64-linux-musl
   │                 │                 │
   ▼                 ▼                 ▼
 hello            hello.exe          hello
```

Run this command on a Linux computer:

```bash
zig build-exe hello.zig -target x86_64-windows-gnu
file hello.exe
```

```
hello.exe: PE32+ executable (console) x86-64, for MS Windows
```

`file` reads the container format, and the container format is Windows. The compiler that made `hello.exe` is the same binary that you use for a native build. The Linux computer has no Windows SDK, no MinGW and no Wine.

Change the triple to `aarch64-linux-musl`. Then `file` reports a statically linked ARM64 ELF.

## The triple

`<arch>-<os>-<abi>`, with `native` allowed in any position:

```
x86_64-linux-gnu
x86_64-linux-musl      # static linking without glibc's version requirements
aarch64-macos-none
wasm32-wasi
native-native-musl
```

Each of the three fields answers a question, and each question is more specific than the last:

- The **architecture** tells which instructions the CPU understands.
- The **OS** tells what the binary asks the system for, and the container format of the binary.
- The **ABI** tells which C library and which calling conventions the binary expects when it runs.

Be careful with the ABI field. `musl` makes a fully static binary. `gnu` links against glibc and gets the version compatibility rules of glibc. Thus the two `x86_64-linux` lines above are two different builds.

## Build for a specific CPU

```bash
zig build-exe main.zig -target x86_64-linux -mcpu=znver3
zig build-exe main.zig -mcpu=baseline        # maximum portability
```

`baseline` is the safe choice. It assumes only the minimum features of the architecture. When you give the name of a specific CPU, the optimiser can use the instructions of that CPU. The cost is that the binary does not run on older CPUs.

## In `build.zig`

```zig
const target = b.standardTargetOptions(.{});
```

This line gives `-Dtarget=` to each person who runs your build. Thus users can cross-compile your project, and you do not have to do more work.

## Why this is unusual

If you cross-compiled C before, you know the usual steps. Many of those steps are not necessary here.

The usual method needs three things:

- A cross toolchain for each target.
- A sysroot that contains the headers and libraries of that platform.
- A build system that can find the toolchain and the sysroot.

To prepare one of these takes a day. To keep several of them up to date is work that does not stop. Because of that cost, many teams decide to build only on Linux. Also, CI matrices use most of their time to install compilers.

Zig includes the libc sources for the targets that it supports, and it compiles the parts that it needs when it needs them. Thus the toolchain and the system headers are already in the single binary that you downloaded. To build a Windows executable on a Mac, use the same command as a native build, with one more flag: `-target x86_64-windows`.

## What still needs care

Cross-compilation gives you a binary. You must still test the binary.

Cross-compilation also does not remove the platform differences that the code must handle. Examples are path separators, line endings, and the size of `usize`: 4 bytes on wasm and 8 bytes on your laptop.

A successful build shows that the code compiles for that target. That is most of the value. But code that compiles is not always code that works.

The second limit is a system library that the target has and your computer does not have. To link against that library, you need the real headers. Then cross-compilation needs more preparation.

## Compile C too

`zig cc` is a C compiler that can replace your current C compiler, and it has the same cross-compilation support. Thus some projects use Zig only as a build tool for their C code.

`zig cc` accepts the flags that a C compiler accepts. Thus you can put it into a `Makefile` or a `configure` command as `CC=zig cc`, and you get the cross-compilation support with it. Some C projects build only on the type of computer that their authors used. After that change, such a project can usually build for four platforms. The source of the project does not change. `zig c++` does the same for C++.
