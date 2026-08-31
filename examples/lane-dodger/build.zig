const std = @import("std");

/// raylib's C sources, vendored by `fetch-raylib.sh` at a pinned commit.
const raylib_root = "vendor/raylib/src";

/// Which screen a headless `-Dframes` run should end up on. Being able to
/// photograph the title and the game over screen without a human at the
/// keyboard is what makes a visual check something CI can do.
pub const Demo = enum { title, play, crash };

/// raylib is built differently for a desktop window and for a canvas: a
/// different platform backend, a different GL, and on the web no bundled GLFW
/// at all, because Emscripten supplies its own.
const Platform = enum { desktop, web };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // A headless smoke run, for CI and for checking the game still draws after
    // a change without sitting in front of it. `-Dframes=N` plays N frames with
    // the bot at the controls and exits; `-Dshot=path` saves the last one.
    // Build options rather than environment variables, so they show up in
    // `zig build --help` and are comptime-known.
    const options = b.addOptions();
    const frames = b.option(
        usize,
        "frames",
        "Play this many frames with the bot, then exit (headless smoke test)",
    );
    options.addOption(?usize, "auto_frames", frames);
    // Sound is off by default in a headless run: nobody is listening, and
    // opening a device a CI container does not have only fills the log with
    // driver warnings. `-Daudio=true` forces it back on, which is how the
    // no-sound-card path gets tested.
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

/// The simulation is a module on its own, and it imports nothing. No raylib, no
/// window, no clock. That is what lets `zig build test` run the whole game
/// headless, and what keeps the rules of the game in one place rather than
/// smeared through a draw loop.
fn simModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
    optimize: std.builtin.OptimizeMode,
) void {
    const sim = simModule(b, target, optimize);
    const sim_tests = b.addTest(.{ .root_module = sim });

    // Particles are presentation, but they hold no raylib types, so they get
    // tested headlessly too.
    const particles = b.createModule(.{
        .root_source_file = b.path("src/render/particles.zig"),
        .target = target,
        .optimize = optimize,
    });
    particles.addImport("sim", sim);
    const particle_tests = b.addTest(.{ .root_module = particles });

    // The synthesiser holds no raylib types either: it fills a buffer with
    // samples. So the waveforms are checked without an audio device, which is
    // just as well, because CI has no speakers.
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

/// `zig build sounds` writes the sound effects to `zig-out/sounds` as `.wav`,
/// so they can be listened to and tuned without playing the game up to the
/// point that triggers each one.
fn addSoundDump(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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

/// The game's root module, wired to a raylib built for `platform`.
const Game = struct {
    module: *std.Build.Module,
    raylib: *std.Build.Step.Compile,
};

fn gameModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
    optimize: std.builtin.OptimizeMode,
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
/// Zig compiles our code and raylib's to a static library for
/// `wasm32-emscripten`, and `emcc` does the link, because the JavaScript glue,
/// the GL context and the canvas plumbing are all things only Emscripten knows
/// how to emit. That split is also why `main.zig` has a `Game.frame`: emcc
/// hands the loop to the browser and never returns.
fn addWeb(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
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
        // Emscripten supplies GLFW 3 against the canvas; raylib's own bundled
        // GLFW is a desktop windowing library and is not built here.
        "-sUSE_GLFW=3",
        // The canvas can be any size, and the page decides. Growth costs a
        // little speed and saves reserving worst-case memory up front.
        "-sALLOW_MEMORY_GROWTH=1",
        // A factory function instead of a global `Module`, so the page can
        // start the game when it wants and hand it its own canvas.
        //
        // Deliberately not an ES6 module. The guide embeds this in a page built
        // by Vite, and Vite rewrites `import()` even for a file it is only
        // serving from `public/`, appending `?import` and then failing to
        // transform a 190 KB Emscripten bundle. A classic script that defines
        // one global is loaded by a plain `<script>` tag, which no bundler
        // touches.
        "-sMODULARIZE=1",
        "-sEXPORT_NAME=createLaneDodger",
        // The loop is driven by emscripten_set_main_loop, so none of the
        // stack-unwinding machinery is needed.
        "-sASYNCIFY=0",
        "-sSTACK_SIZE=1048576",
        // raylib is built here against GLES 3, which emits `#version 300 es`
        // shaders. Those need a WebGL 2 context, and Emscripten creates a
        // WebGL 1 one unless told otherwise: the symptom is a game that loads,
        // runs, and fails to compile a single shader.
        "-sMIN_WEBGL_VERSION=2",
        "-sMAX_WEBGL_VERSION=2",
    });
    if (optimize != .debug) emcc.addArgs(&.{ "-O3", "--closure", "0" });
    emcc.addArg("-o");
    const out = emcc.addOutputFileArg("lane-dodger.js");

    // emcc writes the wasm next to the js, under the same basename.
    const install_js = b.addInstallFileWithDir(out, .{ .custom = "web" }, "lane-dodger.js");
    const install_wasm = b.addInstallFileWithDir(
        out.dirname().path(b, "lane-dodger.wasm"),
        .{ .custom = "web" },
        "lane-dodger.wasm",
    );
    // The page that hosts the canvas. Shipped alongside the two artefacts so
    // `zig build web` produces a directory that is playable as it stands,
    // rather than two files and instructions.
    const install_page = b.addInstallFileWithDir(
        b.path("web-shell/index.html"),
        .{ .custom = "web" },
        "index.html",
    );
    step.dependOn(&install_js.step);
    step.dependOn(&install_wasm.step);
    step.dependOn(&install_page.step);
}

/// Compile raylib from its C sources and hand back a Zig module for `raylib.h`.
///
/// raylib ships a perfectly good build.zig, and we deliberately do not use it.
/// Naming a package in build.zig.zon makes the build runner import that
/// package's build.zig, so a dependency whose build script has not yet caught
/// up with Zig master fails our build before a line of our code is compiled.
/// raylib's had exactly that problem, and so did raylib-zig. Its C, on the
/// other hand, does not move.
///
/// The macros below are copied from what raylib's own build.zig sets for each
/// of these targets.
const Raylib = struct {
    /// `@import("rl")`: raylib.h, run through translate-c.
    module: *std.Build.Module,
    /// The compiled archive. Zig links this into an executable on its own, but
    /// a static library records the dependency without absorbing it, so the
    /// web build has to hand this to emcc itself.
    lib: *std.Build.Step.Compile,
};

fn raylibModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform: Platform,
    emsdk: ?[]const u8,
) Raylib {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Zig instruments C with UBSan by default in the debug modes and links
        // its own runtime to catch the reports. That runtime comes with a Zig
        // link, and the web build is linked by emcc, so the instrumentation
        // would leave a few dozen undefined `__ubsan_*` symbols behind. Nothing
        // here is our C anyway: it is a pinned upstream release.
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
        // 3D model loading pulls in cgltf, m3d and par_shapes for a game that
        // draws rectangles. Off.
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
            // WebGL 2. ES2 also works and reaches older phones; ES3 is what
            // every browser this game would be played in supports today.
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

    // rglfw.c is raylib's bundled desktop GLFW. On the web Emscripten provides
    // GLFW against the canvas instead, so it is not compiled.
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
