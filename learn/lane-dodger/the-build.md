# Vendor raylib

> How to add raylib to a Zig project, why this project uses the C source, and how the game gets to a browser canvas.

raylib is a C library for windows, drawing and sound. This chapter connects
raylib to a Zig project.

## The one line version, and why it fails

raylib has a `build.zig`. With that file, the dependency should be one line:

```zig
const raylib = b.dependency("raylib", .{ .target = target, .optimize = optimize });
```

On Zig master today, that line itself does not compile. The failure occurs
before the build compiles any of the C of raylib.

```
raylib/build.zig:95:10: error: member function expected 1 argument(s), found 2
raylib/build.zig:762:23: error: no field named 'build_root' in struct 'Build'
```

When you name a package in `build.zig.zon`, the build runner imports the
`build.zig` of that package. The build compiles the build script of each
dependency before it compiles any of your code. Thus, if the build script of a
dependency does not support Zig master yet, your build fails before it gets to
your code.

Both errors are in the Wayland detection of raylib, and this project does not use
Wayland. That fact does not help. The full build script must type-check before
the build gets to your code.

`raylib-zig`, the usual binding, is more out of date. It pins raylib 5.5, and it
calls three standard library functions that do not exist on master now.

Neither project does something wrong. Both projects track releases. This guide
tracks master. The breakage comes from that difference. Thus it is better to
know about the breakage before you add the dependency.

## Depend on the C instead

The C of raylib changes much more slowly than the build API of Zig. Thus this
project depends on the C.

### 1. Fetch the source

Clone raylib at a pinned commit into a directory that the build can read. Pin the
commit, because a dependency without a pin can change without your knowledge.

```bash
git init vendor/raylib
git -C vendor/raylib remote add origin https://github.com/raysan5/raylib.git
git -C vendor/raylib fetch --depth 1 origin <commit>
git -C vendor/raylib checkout FETCH_HEAD
```

Keep `src/` and the licence. Delete all other files. The `examples/` directory of
raylib is 72 MB by itself, and the build compiles none of it. In this project,
`fetch-raylib.sh` does these steps and records the commit that it fetched.

Add `vendor/` to `.gitignore`. The script is the record. The vendored copy is
not the record.

### 2. Do not declare it in `build.zig.zon`

`vendor/raylib` stays a plain directory of C files. The build runner imports the
build script of each declared package, and it never looks at a plain directory.
Thus nothing reads the `build.zig` of raylib.

### 3. Compile the C

```zig
const mod = b.createModule(.{
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
const lib = b.addLibrary(.{ .name = "raylib", .linkage = .static, .root_module = mod });

mod.addCMacro("PLATFORM_DESKTOP_GLFW", "");
mod.addCMacro("GRAPHICS_API_OPENGL_33", "");
mod.addCMacro("_GLFW_X11", "");

mod.addIncludePath(b.path("vendor/raylib/src/platforms"));
mod.addIncludePath(b.path("vendor/raylib/src/external/glfw/include"));
mod.addCSourceFiles(.{
    .root = b.path("vendor/raylib/src"),
    .files = &.{ "rcore.c", "rshapes.c", "rtextures.c", "rtext.c", "raudio.c", "rglfw.c" },
    .flags = &.{"-std=gnu99"},
});

for ([_][]const u8{ "GL", "X11", "Xrandr", "Xinerama", "Xi", "Xcursor" }) |name| {
    mod.linkSystemLibrary(name, .{});
}
```

The build compiles six C files. `rglfw.c` is the copy of GLFW that raylib
includes, and GLFW is the layer that makes the windows. The other files are the modules of
raylib. The `SUPPORT_MODULE_*` macros turn these modules on and off.

On Debian or Ubuntu, these packages supply the system libraries:

```bash
sudo apt-get install libx11-dev libxrandr-dev libxinerama-dev \
                     libxi-dev libxcursor-dev libgl1-mesa-dev
```

You do not need an ALSA package. The audio backend of raylib loads libasound at
runtime, and does not include its header. Thus the game compiles without
libasound, and it is silent when no device exists.

### 4. Change `raylib.h` into a Zig module

The language does not have `@cImport` now. C headers now come through a build
step.

```zig
const translated = b.addTranslateC(.{
    .root_source_file = b.path("vendor/raylib/src/raylib.h"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
const rl = translated.createModule();
rl.linkLibrary(lib);

exe_mod.addImport("rl", rl);
```

### 5. Use it

```zig
const rl = @import("rl");

pub fn main() void {
    rl.InitWindow(540, 960, "Lane Dodger");
    defer rl.CloseWindow();

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();
        rl.ClearBackground(rl.RAYWHITE);
        rl.DrawText("hello", 20, 20, 24, rl.BLACK);
        rl.EndDrawing();
    }
}
```

translate-c does not change the names. Thus the documentation of raylib applies
directly.

## The full function

```zig
fn raylibModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    platform: Platform,
    emsdk: ?[]const u8,
) Raylib {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // In the debug modes, Zig instruments C with UBSan by default and
        // links its own runtime to catch the reports. That runtime comes with
        // a Zig link. emcc does the link for the web build. Thus the
        // instrumentation would leave a few dozen undefined `__ubsan_*`
        // symbols. This project did not write this C. It is a pinned upstream
        // release.
        .sanitize_c = .off,
    });
    const lib = b.addLibrary(.{
        .name = "raylib",
        .linkage = .static,
        .root_module = mod,
    });

    inline for (.{
        .{ "_GNU_SOURCE", "" },
        .{ "GL_SILENCE_DEPRECATION", "199309L" },
        .{ "SUPPORT_MODULE_RSHAPES", "1" },
        .{ "SUPPORT_MODULE_RTEXTURES", "1" },
        .{ "SUPPORT_MODULE_RTEXT", "1" },
        .{ "SUPPORT_MODULE_RAUDIO", "1" },
        // The 3D model loader adds cgltf, m3d and par_shapes. This game draws
        // only rectangles, thus the build turns the module off.
        .{ "SUPPORT_MODULE_RMODELS", "0" },
    }) |macro| mod.addCMacro(macro[0], macro[1]);

    switch (platform) {
        .desktop => {
            mod.addCMacro("PLATFORM_DESKTOP_GLFW", "");
            mod.addCMacro("GRAPHICS_API_OPENGL_33", "");
            mod.addCMacro("_GLFW_X11", "");
        },
        .web => {
            mod.addCMacro("PLATFORM_WEB", "");
            // WebGL 2. ES2 also works, and it also works on older phones. All
            // browsers where a person would play this game support ES3 today.
            mod.addCMacro("GRAPHICS_API_OPENGL_ES3", "");
        },
    }

    mod.addIncludePath(b.path(raylib_root ++ "/platforms"));
    mod.addIncludePath(b.path(raylib_root ++ "/external/glfw/include"));
    if (emsdk) |sdk| {
        mod.addIncludePath(.{ .cwd_relative = b.pathJoin(
            &.{ sdk, "upstream", "emscripten", "cache", "sysroot", "include" },
        ) });
    }

    // rglfw.c is the desktop GLFW that raylib includes. On the web,
    // Emscripten supplies GLFW for the canvas. Thus the web build does not
    // compile rglfw.c.
    const sources: []const []const u8 = switch (platform) {
        .desktop => &.{
            "rcore.c", "rshapes.c", "rtextures.c", "rtext.c", "raudio.c", "rglfw.c",
        },
        .web => &.{
            "rcore.c", "rshapes.c", "rtextures.c", "rtext.c", "raudio.c",
        },
    };
    mod.addCSourceFiles(.{
        .root = b.path(raylib_root),
        .files = sources,
        .flags = &.{"-std=gnu99"},
    });

    if (platform == .desktop) {
        for ([_][]const u8{ "GL", "X11", "Xrandr", "Xinerama", "Xi", "Xcursor" }) |name| {
            mod.linkSystemLibrary(name, .{});
        }
    }

    const translated = b.addTranslateC(.{
        .root_source_file = b.path(raylib_root ++ "/raylib.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (emsdk) |sdk| {
        translated.addIncludePath(.{ .cwd_relative = b.pathJoin(
            &.{ sdk, "upstream", "emscripten", "cache", "sysroot", "include" },
        ) });
    }
    const rl = translated.createModule();
    rl.linkLibrary(lib);
    return .{ .module = rl, .lib = lib };
}
```

*Quoted from the source: `raylibModule` from `examples/lane-dodger/build.zig`.*

The macros are a copy of the macros in the build script of raylib. That is the
cost of this method. When raylib changes its configuration, this function must
change too. The list of macros is a dozen lines. A mismatch fails at compile
time. A mismatch does not silently make a different library.

## The same source, on a canvas

The platform choice has an effect in two places: the raylib module above, and a
separate `addWeb` step that runs `emcc`.

The desktop build uses `PLATFORM_DESKTOP_GLFW` with OpenGL 3.3 and the copy of
GLFW that raylib includes. The web build uses `PLATFORM_WEB` with GLES 3, and it
does not compile `rglfw.c`. Emscripten supplies its own GLFW, which it connects
to the canvas.

Zig compiles the game and raylib to a static library for `wasm32-emscripten`.
`emcc` does the link. Emscripten supplies the JavaScript glue, the GL context and
the canvas configuration.

```zig
/// Build the game for a browser canvas.
///
/// Zig compiles the game code and the raylib code to a static library for
/// `wasm32-emscripten`. `emcc` does the link, because only Emscripten can emit
/// the JavaScript glue, the GL context and the canvas configuration. The same
/// split is the reason for `Game.frame` in `main.zig`. emcc gives the loop to
/// the browser and never returns.
fn addWeb(
    b: *std.Build,
    optimize: std.lang.Optimize,
    options: *std.Build.Step.Options,
) void {
    const step = b.step("web", "Build the browser version with Emscripten");

    const emsdk = b.option([]const u8, "emsdk", "Path to an activated emsdk") orelse
        b.graph.environ_map.get("EMSDK") orelse
    {
        step.dependOn(&b.addFail(
            "no Emscripten SDK found: pass -Demsdk=/path/to/emsdk, or source emsdk_env.sh",
        ).step);
        return;
    };

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .emscripten,
    });

    const game = gameModule(b, target, optimize, options, .web, emsdk);
    const lib = b.addLibrary(.{
        .name = "lane-dodger",
        .linkage = .static,
        .root_module = game.module,
    });

    const emcc = b.addSystemCommand(&.{b.pathJoin(&.{ emsdk, "upstream", "emscripten", "emcc" })});
    emcc.addArtifactArg(lib);
    emcc.addArtifactArg(game.raylib);
    emcc.addArgs(&.{
        // Emscripten supplies GLFW 3 for the canvas. The GLFW that raylib
        // includes is a desktop library for windows. This build does not
        // compile it.
        "-sUSE_GLFW=3",
        // The canvas can have any size, and the page selects the size. Growth
        // costs a small quantity of speed. Without growth, the program must
        // reserve memory for the worst case at the start.
        "-sALLOW_MEMORY_GROWTH=1",
        // A factory function, and not a global `Module`. Thus the page can
        // start the game at the time that it selects, and give the game its
        // own canvas.
        //
        // This output is not an ES6 module, and that is intentional. The guide
        // puts the game in a page that Vite builds. Vite rewrites `import()`
        // also for a file that it only serves from `public/`. It adds
        // `?import`, then it cannot transform a 190 KB Emscripten bundle. A
        // plain `<script>` tag loads a classic script that defines one global,
        // and no bundler changes that tag.
        "-sMODULARIZE=1",
        "-sEXPORT_NAME=createLaneDodger",
        // emscripten_set_main_loop controls the loop. Thus the build needs
        // none of the code that unwinds the stack.
        "-sASYNCIFY=0",
        "-sSTACK_SIZE=1048576",
        // Here the build compiles raylib against GLES 3, which emits
        // `#version 300 es` shaders. These shaders need a WebGL 2 context.
        // Emscripten creates a WebGL 1 context unless you tell it to do
        // otherwise. The symptom is a game that loads, runs, and compiles no
        // shader.
        "-sMIN_WEBGL_VERSION=2",
        "-sMAX_WEBGL_VERSION=2",
    });
    if (optimize != .debug) emcc.addArgs(&.{ "-O3", "--closure", "0" });
    emcc.addArg("-o");
    const out = emcc.addOutputFileArg("lane-dodger.js");

    // emcc writes the wasm next to the js, with the same basename.
    const install_js = b.addInstallFileWithDir(out, .{ .custom = "web" }, "lane-dodger.js");
    const install_wasm = b.addInstallFileWithDir(
        out.dirname().path(b, "lane-dodger.wasm"),
        .{ .custom = "web" },
        "lane-dodger.wasm",
    );
    // The page that holds the canvas. The page comes with the two artefacts.
    // Thus `zig build web` makes a directory that you can play with no other
    // configuration.
    const install_page = b.addInstallFileWithDir(
        b.path("web-shell/index.html"),
        .{ .custom = "web" },
        "index.html",
    );
    step.dependOn(&install_js.step);
    step.dependOn(&install_wasm.step);
    step.dependOn(&install_page.step);
}
```

*Quoted from the source: `addWeb` from `examples/lane-dodger/build.zig`.*

Two flags in that function prevent silent failures.

`-sMIN_WEBGL_VERSION=2`. GLES 3 emits `#version 300 es` shaders, and these
shaders need a WebGL 2 context. Emscripten creates a WebGL 1 context unless you
tell it to do otherwise. The symptom is a game that loads, runs, reports no
error, and compiles no shader.

`.sanitize_c = .off` on the raylib module. In the debug modes, Zig instruments C
with UBSan and links its own runtime to catch the reports. That runtime comes
with a Zig link. Here `emcc` does the link. Thus the instrumentation leaves
dozens of undefined `__ubsan_*` symbols.

## Run it

```bash
cd examples/lane-dodger
./fetch-raylib.sh
zig build run -Doptimize=ReleaseFast
```

The browser build is a `.wasm` file of 200 KB, and approximately the same
quantity of JavaScript. The browser build needs the Emscripten SDK:

```bash
zig build web -Doptimize=ReleaseFast
python3 -m http.server -d zig-out/web 8080
```
