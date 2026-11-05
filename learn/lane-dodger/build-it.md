# Build It From Scratch

> The order in which to write the files, the two points where you can stop and check, and what to do when the build fails.

The other chapters explain what each part does. This chapter gives the order in
which to write the parts.

You can stop and check your work at two points. The first point comes before you
draw anything, and it runs the full game.

## What you need

You need Zig master, and not 0.16. The game uses `std.process.Init`,
`std.Io.Dir`, `std.mem.printSentinel` and `@splat` on arrays. All of these came
after 0.16. `build.zig.zon` gives the exact minimum version.

```bash
zig version    # 0.17.0-dev.1676 or newer
```

You also need Git and a C compiler. On Debian or Ubuntu, the game also needs the
X development headers:

```bash
sudo apt-get install libx11-dev libxrandr-dev libxinerama-dev \
                     libxi-dev libxcursor-dev libgl1-mesa-dev
```

You do not need an ALSA package. The audio backend of raylib loads libasound at
runtime, and does not include its header.

## Part one: the project structure

**1. Make the directory tree.**

```bash
mkdir -p lane-dodger/src/{sim,render,audio,platform,tools}
cd lane-dodger
```

**2. Tell Git to ignore the raylib copy.** Add one line to `.gitignore`:

```
vendor/
```

The fetch script below records which raylib commit the game uses. The copy that
the script downloads is 13 MB, thus the copy stays out of Git.

**3. Write the package file.**

```zig
.{
    .name = .lane_dodger,
    .version = "0.1.0",
    .fingerprint = 0x10128392faa1179,
    .minimum_zig_version = "0.17.0-dev.1676",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

*Quoted from the source: `examples/lane-dodger/build.zig.zon`.*

`zig build` does not accept the fingerprint, and prints the correct value. Paste
that value into the file.

raylib is *not* in `.dependencies`. This is intentional, and
[Vendor raylib](https://www.ziglang.in/learn/lane-dodger/the-build/) gives the reason.

**4. Write the fetch script.**

```bash
#!/usr/bin/env bash
# Vendor raylib's C sources at a pinned commit.
#
# raylib is used as a plain directory of C files, not as a Zig package. That is
# deliberate: the build runner imports the build.zig of every package named in
# build.zig.zon, and raylib's own build.zig chases Zig master a few weeks behind
# it. Pulling raylib in as a package therefore breaks whenever Zig moves and
# raylib has not caught up, which for a repo that tracks master is most weeks.
# The C sources have no such problem, so we compile them ourselves.
set -euo pipefail

REPO="https://github.com/raysan5/raylib.git"
# raylib 6.0.0-dev. Bump deliberately, then re-run `zig build test`.
COMMIT="9f3cadf1e618f125bd9b282c7759f8cb26ce17fc"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="$here/vendor/raylib"

if [ -f "$dest/.commit" ] && [ "$(cat "$dest/.commit")" = "$COMMIT" ]; then
  echo "raylib already at $COMMIT"
  exit 0
fi

rm -rf "$dest"
mkdir -p "$dest"
git -C "$dest" init -q
git -C "$dest" remote add origin "$REPO"
git -C "$dest" fetch -q --depth 1 origin "$COMMIT"
git -C "$dest" checkout -q FETCH_HEAD
rm -rf "$dest/.git"

# Keep only what we compile. raylib's examples/ alone is 72 MB and none of it
# is built here.
find "$dest" -mindepth 1 -maxdepth 1 ! -name src ! -name LICENSE -exec rm -rf {} +
rm -rf "$dest/src/external/RGFW"

echo "$COMMIT" > "$dest/.commit"
echo "raylib vendored at $COMMIT"
```

*Quoted from the source: `examples/lane-dodger/fetch-raylib.sh`.*

```bash
chmod +x fetch-raylib.sh && ./fetch-raylib.sh
```

**5. Write the build script.**

```zig
const std = @import("std");

/// The C sources of raylib. `fetch-raylib.sh` vendors them at a pinned commit.
const raylib_root = "vendor/raylib/src";

/// The screen that a headless `-Dframes` run shows at its end. Thus CI can take
/// a screenshot of the title and of the game over screen with nobody at the
/// keyboard. With these screenshots, CI checks what the game draws.
pub const Demo = enum { title, play, crash };

/// The raylib build for a desktop window is different from the build for a
/// canvas. It has a different platform backend and a different GL. On the web
/// it does not use the GLFW that raylib includes, because Emscripten supplies
/// its own GLFW.
const Platform = enum { desktop, web };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // A headless smoke run. CI uses it, and you can use it after a change to
    // check that the game still draws, without a person who watches.
    // `-Dframes=N` plays N frames with the bot at the controls, then exits.
    // `-Dshot=path` saves the last frame. These are build options and not
    // environment variables. Thus `zig build --help` shows them, and their
    // values are comptime-known.
    const options = b.addOptions();
    const frames = b.option(
        usize,
        "frames",
        "Play this many frames with the bot, then exit (headless smoke test)",
    );
    options.addOption(?usize, "auto_frames", frames);
    // By default, a headless run has no sound, because nobody listens. A CI
    // container has no audio device, and an attempt to open one only puts
    // driver warnings in the log. `-Daudio=true` turns the sound on again.
    // That option lets you test the path for a machine with no sound card.
    options.addOption(bool, "audio", b.option(
        bool,
        "audio",
        "Enable sound (default: on, except in a -Dframes run)",
    ) orelse (frames == null));
    options.addOption(?[]const u8, "screenshot", b.option(
        []const u8,
        "shot",
        "Write a screenshot to this path before exiting",
    ));
    options.addOption(Demo, "demo", b.option(
        Demo,
        "demo",
        "What the headless run should show: title, play (bot drives) or crash",
    ) orelse .play);

    addTests(b, target, optimize);
    addSoundDump(b, target, optimize);
    addDesktop(b, target, optimize, options);
    addWeb(b, optimize, options);
}

/// The simulation is a separate module, and it imports nothing: not raylib, a
/// window or a clock. Thus `zig build test` can run the full game headless.
/// Also, the rules of the game stay in one place, and not in parts of a draw
/// loop.
fn simModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/sim/sim.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    const sim = simModule(b, target, optimize);
    const sim_tests = b.addTest(.{ .root_module = sim });

    // The particles are presentation. But they contain no raylib types, thus
    // the tests can also check them headlessly.
    const particles = b.createModule(.{
        .root_source_file = b.path("src/render/particles.zig"),
        .target = target,
        .optimize = optimize,
    });
    particles.addImport("sim", sim);
    const particle_tests = b.addTest(.{ .root_module = particles });

    // The synthesiser also contains no raylib types. It fills a buffer with
    // samples. Thus the tests check the waveforms without an audio device. CI
    // has no speakers.
    const synth = b.createModule(.{
        .root_source_file = b.path("src/audio/synth.zig"),
        .target = target,
        .optimize = optimize,
    });
    synth.addImport("sim", sim);
    const synth_tests = b.addTest(.{ .root_module = synth });

    const step = b.step("test", "Run the headless simulation tests");
    step.dependOn(&b.addRunArtifact(sim_tests).step);
    step.dependOn(&b.addRunArtifact(particle_tests).step);
    step.dependOn(&b.addRunArtifact(synth_tests).step);
}

/// `zig build sounds` writes the sound effects to `zig-out/sounds` as `.wav`
/// files. Thus you can listen to each effect and adjust it. You do not have to
/// play the game until the effect occurs.
fn addSoundDump(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    const synth = b.createModule(.{
        .root_source_file = b.path("src/audio/synth.zig"),
        .target = target,
        .optimize = optimize,
    });
    synth.addImport("sim", simModule(b, target, optimize));

    const module = b.createModule(.{
        .root_source_file = b.path("src/tools/dump_sounds.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("synth", synth);

    const exe = b.addExecutable(.{ .name = "dump-sounds", .root_module = module });
    const run = b.addRunArtifact(exe);
    const wavs = run.addOutputDirectoryArg("sounds");

    const install = b.addInstallDirectory(.{
        .source_dir = wavs,
        .install_dir = .{ .custom = "sounds" },
        .install_subdir = ".",
    });
    b.step("sounds", "Write the sound effects to zig-out/sounds as .wav").dependOn(&install.step);
}

/// The root module of the game, connected to a raylib build for `platform`.
const Game = struct {
    module: *std.Build.Module,
    raylib: *std.Build.Step.Compile,
};

fn gameModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    options: *std.Build.Step.Options,
    platform: Platform,
    emsdk: ?[]const u8,
) Game {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylibModule(b, target, optimize, platform, emsdk);
    module.addImport("sim", simModule(b, target, optimize));
    module.addImport("rl", raylib.module);
    module.addOptions("build_options", options);
    return .{ .module = module, .raylib = raylib.lib };
}

fn addDesktop(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    options: *std.Build.Step.Options,
) void {
    const game = gameModule(b, target, optimize, options, .desktop, null);
    const exe = b.addExecutable(.{ .name = "lane-dodger", .root_module = game.module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Build and play the game").dependOn(&run.step);
}

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

/// Compile raylib from its C sources, and return a Zig module for `raylib.h`.
///
/// raylib has its own build.zig, and this project does not use it on purpose.
/// When you name a package in build.zig.zon, the build runner imports the
/// build.zig of that package. If the build script of a dependency does not
/// support Zig master yet, your build fails before it compiles one line of
/// your code. The build script of raylib had that problem, and the build
/// script of raylib-zig also had it. The C of raylib changes much more slowly.
///
/// The macros below are a copy of the macros that the build.zig of raylib
/// sets for each of these targets.
const Raylib = struct {
    /// `@import("rl")`: raylib.h, run through translate-c.
    module: *std.Build.Module,
    /// The compiled archive. Zig links the archive into an executable
    /// automatically. But a static library records the dependency and does
    /// not include the archive. Thus the web build must give the archive to
    /// emcc.
    lib: *std.Build.Step.Compile,
};

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

*Quoted from the source: `examples/lane-dodger/build.zig`.*

Nothing compiles yet. `build.zig` names files that do not exist, and that is
correct. Zig reads a source file only when a step that needs the file runs.

## Part two: the simulation

Write these nine files in this order. Each file uses only the files above it.

- `examples/lane-dodger/src/sim/config.zig`: Every tunable number, and the field geometry. [The World](https://www.ziglang.in/learn/lane-dodger/the-world/).
- `examples/lane-dodger/src/sim/rng.zig`: PCG32, so a seed replays exactly. [The World](https://www.ziglang.in/learn/lane-dodger/the-world/).
- `examples/lane-dodger/src/sim/pool.zig`: Fixed-capacity storage with generational handles. [Handles, Not Pointers](https://www.ziglang.in/learn/lane-dodger/entities/).
- `examples/lane-dodger/src/sim/sim.zig`: The world, the tick, collision and spawning. [The World](https://www.ziglang.in/learn/lane-dodger/the-world/).
- `examples/lane-dodger/src/sim/bot.zig`: A policy that plays the game. [Difficulty You Can Prove](https://www.ziglang.in/learn/lane-dodger/fair-by-design/).
- `examples/lane-dodger/src/sim/tests.zig`: The tests that play the game. [Difficulty You Can Prove](https://www.ziglang.in/learn/lane-dodger/fair-by-design/).
- `examples/lane-dodger/src/render/palette.zig`: Colours as plain data, no raylib. [Draw It](https://www.ziglang.in/learn/lane-dodger/drawing/).
- `examples/lane-dodger/src/render/particles.zig`: Sparks and debris, using the same pool. [Draw It](https://www.ziglang.in/learn/lane-dodger/drawing/).
- `examples/lane-dodger/src/audio/synth.zig`: Five sound effects, generated. [Sound Without Sound Files](https://www.ziglang.in/learn/lane-dodger/sound/).

### The first checkpoint

```bash
zig build test
```

The command runs fifty-five tests:

- A bot plays four minutes of the game at each seed.
- A second bot plays the game with a human reaction time.
- Two worlds replay from one seed, and the test compares them on each tick.

You did not write drawing code, input code or `main.zig` yet. You do not need a
window or an audio device. But the game is already sufficiently complete to play
and to check. The design has this arrangement so that this checkpoint exists.

If the tests pass, the rules are correct. The other files draw the game,
read the input and play the sound.

## Part three: the game you can see

Write four more files.

- `examples/lane-dodger/src/render/draw.zig`: The view transform and every raylib call. [Draw It](https://www.ziglang.in/learn/lane-dodger/drawing/).
- `examples/lane-dodger/src/platform/input.zig`: Keys and taps, read one time in each frame. [Input](https://www.ziglang.in/learn/lane-dodger/input/).
- `examples/lane-dodger/src/platform/audio.zig`: The audio device, and the sounds on it. [Sound Without Sound Files](https://www.ziglang.in/learn/lane-dodger/sound/).
- `examples/lane-dodger/src/main.zig`: The window and the fixed timestep loop. [The Loop Takes No dt](https://www.ziglang.in/learn/lane-dodger/the-loop/).

```bash
zig build run -Doptimize=ReleaseFast
```

To change lane, use `A` and `D` or the arrow keys. Space starts a run. `M` stops
the sound.

## Optional

One more file writes the sound effects to `.wav` files. Then you can listen to
each effect, and you do not have to play the game until the effect occurs.

- `examples/lane-dodger/src/tools/dump_sounds.zig`: Renders the five clips to a directory. [Sound Without Sound Files](https://www.ziglang.in/learn/lane-dodger/sound/).

```bash
zig build sounds && ls zig-out/sounds
```

## How one tap becomes a frame

```
you press D
   |
   v
Latch.poll()            once per rendered frame, sets latch.right
   |
   v
Game.frame()            adds real elapsed time to the accumulator
   |
   v
while accumulator >= 1/120:
     Input = latch.take()      first tick gets the press, the rest get nothing
     World.step(input)         steer, move, spawn, collide, score
     react(events)             particles, screen shake, a note
   |
   v
alpha = accumulator / (1/120)      what is left over, less than one tick
   |
   v
draw.frame(world, alpha)    draws between the last two ticks
```

The press gets to exactly one tick. If a frame needs no ticks, the frame keeps
the press for the next frame. If a frame needs three ticks, the frame gives the
press to the first tick.

## If the build fails

**`error: invalid fingerprint`.** This error is normal on the first run. Paste
the value that the compiler prints into `build.zig.zon`.

**`error: unable to find module 'rl'`**, or the compiler cannot find the raylib
headers.
`fetch-raylib.sh` did not run, or it ran in the wrong directory. Make sure that
`vendor/raylib/src/raylib.h` exists.

**`ld: cannot find -lX11`** and similar errors. The X development headers are not on
your system. Install the packages in the list above. The runtime libraries alone are
not sufficient. You need the `-dev` packages.

**`root source file struct 'std' has no member named ...`.** Your Zig is too old,
or too new. This game tracks master, thus both of these problems can occur.
Compare `zig version` with `minimum_zig_version`.

**The tests pass but the window is black.** You use Wayland without XWayland, or
a container with no display. To make sure that the program itself runs, try
`xvfb-run -a ./zig-out/bin/lane-dodger`.

**The game builds, but it plays badly.** All the numbers are in
[`src/sim/config.zig`](https://github.com/rajeshpillai/zig-guide/blob/main/examples/lane-dodger/src/sim/config.zig).
Change `lane_change_time` first. Do not make the row spacing smaller by hand.
`sim.zig` calculates a minimum from the other numbers, and
[the tests](https://www.ziglang.in/learn/lane-dodger/fair-by-design/) tell you when the spacing is
less than that minimum.
