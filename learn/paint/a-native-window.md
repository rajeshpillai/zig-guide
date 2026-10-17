# A Native Window

> The same engine in a desktop window with raylib. Windows builds from Linux with one flag. macOS does not, and the reason is a licence, not the compiler.

The studio on the first page is the engine in a browser.

The same engine also runs in a desktop window. The window is drawn by **raylib**, a small C library for windows, graphics and input.

The front end is one file, `native.zig`. Like the browser front end, it reads input, calls the engine, and copies the changed rectangle to the screen.

```
cd examples/paint
./fetch-raylib.sh      # once: download raylib's C at a pinned commit
zig build run          # open the window
```

## raylib as C, not as a package

raylib is used as a folder of C files, compiled by our own `build.zig`.

`fetch-raylib.sh` downloads them at a fixed commit, the same one the [Lane Dodger](https://www.ziglang.in/learn/lane-dodger/the-build/) game uses. That chapter explains why the C is vendored rather than used as a Zig package: a package's build script must keep up with Zig master, and raylib's often does not.

Here is the whole raylib build:

<PaintSource file="build.zig" decl="raylibModule" />

`addTranslateC` reads `raylib.h` and turns it into a Zig module. The front end then calls `rl.InitWindow`, `rl.DrawTexture` and the rest as if they were Zig functions.

A paint program makes no sound and loads no 3D models, so the audio and model modules are switched off with two macros. That leaves five C files.

## The front end

The window shows a texture the size of the document. Each frame, the loop reads the mouse, calls the engine, and uploads only the rectangle `render` says changed:

<PaintSource file="src/native.zig" decl="main" />

raylib's texture update wants the rectangle's pixels next to each other in memory. In `display` they are not: each row of the rectangle is one row of a 640-pixel image. So the rows are copied into `scratch` first.

A mouse has no pressure, so every point gets 0.5, the value browsers report for a mouse. The window and the studio draw the same stroke for the same movement.

## Cross-compiling

Zig compiles for other operating systems with one flag:

```
zig build native -Dtarget=x86_64-windows
```

On Linux, that builds a working `paint.exe` of about 1.3 MB, and nothing needs to be installed first.

It works because of what raylib needs from Windows: `opengl32`, `gdi32`, `winmm`, `user32` and `shell32`. Zig ships the import libraries for these, from the MinGW project, inside the compiler. The `build.zig` above only has to choose `_GLFW_WIN32` instead of `_GLFW_X11` and name those libraries.

One more line matters on Windows:

```zig
if (target.result.os.tag == .windows) exe.subsystem = .windows;
```

A Windows program is either a console program or a window program. A console program opens a terminal window when you double-click it, behind the paint window. `.windows` asks for a window program.

CI builds the Windows `.exe` on every run, from a Linux machine, so a change in Zig or raylib that breaks it fails the nightly build. CI does not run it, because it has no Windows machine to run it on.

## Where cross-compiling stops

The other direction is harder for Linux and simply blocked for macOS.

Building **for Linux on another CPU**, such as a 64-bit ARM board, needs the X11 header files for that system. Zig does not ship them, so they have to come from that system. They are only headers, so it can be done, but it is not one flag.

Building **for macOS** from Linux needs Apple's SDK: the headers and libraries for Cocoa, IOKit and OpenGL that raylib uses on a Mac. Zig does not ship them, and Apple's licence does not allow anyone else to ship them either. The compiler could do the job. The files it would need are not allowed to be copied.

So the macOS build is made on a Mac, where the SDK is already installed. GitHub provides Mac machines for CI, so this is a cost, not a dead end.

## A smoke test without a screen

CI has no screen. It runs the window inside **Xvfb**, a virtual display that draws into memory.

`-Dframes=30` makes the program draw the engine's demo picture, show it for 30 frames and exit. `-Dshot` saves the last frame:

```
zig build native -Dframes=30 -Dshot=demo-native.png
xvfb-run ./zig-out/bin/paint
```

Compiling proves the raylib calls still match the headers. Running proves the window opens and the texture is drawn.

## Explain before reading the answer

The browser studio and the native window both send the engine the same points for the same movement.

Will they draw exactly the same pixels?

The engine will. Given the same calls, it computes the same picture on any machine. The first chapter's demo check proves this for the browser and native builds.

What can differ is the calls. A browser can report more samples per second than one per frame, and the studio passes all of them on. raylib reads the mouse once per frame. So a fast stroke gets more points in the browser. The spacing from the [Strokes](https://www.ziglang.in/learn/paint/strokes/) chapter keeps the dabs evenly spaced either way, but where the path bends between samples, the two paths are not quite the same.
