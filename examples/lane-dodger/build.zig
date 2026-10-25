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
