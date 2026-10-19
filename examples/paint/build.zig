//! The paint program.
//!
//!   zig build test     run the engine's tests (no window needed)
//!   zig build demo     draw the demo picture into zig-out/demo.png
//!   zig build web      build the browser front end: zig-out/web/paint.wasm
//!   zig build run      open the native window (needs ./fetch-raylib.sh once)
//!   zig build native -Dtarget=x86_64-windows   a Windows .exe, from Linux
//!
//! The engine is plain Zig with no dependencies, so the browser build needs no
//! Emscripten and no SDK: it is `wasm32-freestanding`, built by the same
//! compiler as everything else. The guide's own build.zig builds it too, into
//! web/public/apps/paint/, so the page runs exactly what CI built.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Master returns null when no mode is given, meaning "the default".
    const optimize = b.standardOptimizeOption(.{}) orelse .debug;

    const engine = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = engine });
    const test_step = b.step("test", "Run the engine's tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const demo = b.addExecutable(.{
        .name = "paint-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "engine", .module = engine }},
        }),
    });
    const run_demo = b.addRunArtifact(demo);
    run_demo.setCwd(b.path("zig-out"));
    run_demo.step.dependOn(&b.addInstallArtifact(demo, .{}).step);
    const demo_step = b.step("demo", "Draw the demo picture into zig-out/demo.png");
    demo_step.dependOn(&run_demo.step);

    addNative(b, target, optimize, engine);

    const web_step = b.step("web", "Build the browser front end into zig-out/web");
    const web = addWeb(b, b.path("src"), if (optimize == .debug) .small else optimize);
    web_step.dependOn(&b.addInstallArtifact(web, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
}

/// The browser build. The function is public, thus the build.zig of the
/// guide can call it with its own path to `src/`. Both builds use one definition.
pub fn addWeb(b: *std.Build, src: std.Build.LazyPath, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const engine = b.createModule(.{
        .root_source_file = src.path(b, "engine.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "paint",
        .root_module = b.createModule(.{
            .root_source_file = src.path(b, "web.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "engine", .module = engine }},
        }),
    });
    // A library of exported functions, not a program with a main. The page
    // calls the functions.
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
}

/// raylib's C sources, vendored by `fetch-raylib.sh` at the same pinned commit
/// the game uses. Vendored as C, not as a Zig package, for the reason the
/// game's build.zig gives: a package's build script has to keep up with Zig
/// master, and raylib's C does not.
const raylib_root = "vendor/raylib/src";

/// The native window. Linux and Windows are supported, and Windows builds
/// from any OS because Zig ships the MinGW import libraries raylib needs.
/// macOS needs Apple's SDK, which cannot be redistributed, so it is built on
/// a Mac.
fn addNative(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    engine: *std.Build.Module,
) void {
    const options = b.addOptions();
    const frames = b.option(usize, "frames", "Draw the demo, show it for this many frames, then exit (headless smoke test)");
    options.addOption(?usize, "frames", frames);
    options.addOption(?[]const u8, "screenshot", b.option([]const u8, "shot", "Write a screenshot here before exiting"));

    const module = b.createModule(.{
        .root_source_file = b.path("src/native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine", .module = engine },
            .{ .name = "rl", .module = raylibModule(b, target, optimize) },
        },
    });
    module.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "paint", .root_module = module });
    // A window program on Windows, not a console one, or double-clicking the
    // .exe opens an empty terminal behind the picture.
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    const install = b.addInstallArtifact(exe, .{});
    b.step("native", "Build the native window").dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    b.step("run", "Open the native window").dependOn(&run.step);
}

fn raylibModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // This C does not come from this project. The UBSan runtime would only
        // report problems in a fixed upstream release.
        .sanitize_c = .off,
    });
    const lib = b.addLibrary(.{ .name = "raylib", .linkage = .static, .root_module = mod });

    inline for (.{
        .{ "_GNU_SOURCE", "" },
        .{ "GL_SILENCE_DEPRECATION", "199309L" },
        .{ "PLATFORM_DESKTOP_GLFW", "" },
        .{ "GRAPHICS_API_OPENGL_33", "" },
        .{ "SUPPORT_MODULE_RSHAPES", "1" },
        .{ "SUPPORT_MODULE_RTEXTURES", "1" },
        .{ "SUPPORT_MODULE_RTEXT", "1" },
        // A paint program makes no sound and loads no 3D models.
        .{ "SUPPORT_MODULE_RAUDIO", "0" },
        .{ "SUPPORT_MODULE_RMODELS", "0" },
    }) |macro| mod.addCMacro(macro[0], macro[1]);

    const windows = target.result.os.tag == .windows;
    mod.addCMacro(if (windows) "_GLFW_WIN32" else "_GLFW_X11", "");
    mod.addIncludePath(b.path(raylib_root ++ "/platforms"));
    mod.addIncludePath(b.path(raylib_root ++ "/external/glfw/include"));
    mod.addCSourceFiles(.{
        .root = b.path(raylib_root),
        .files = &.{ "rcore.c", "rshapes.c", "rtextures.c", "rtext.c", "rglfw.c" },
        .flags = &.{"-std=gnu99"},
    });
    const libs: []const []const u8 = if (windows)
        &.{ "opengl32", "gdi32", "winmm", "user32", "shell32" }
    else
        &.{ "GL", "X11", "Xrandr", "Xinerama", "Xi", "Xcursor" };
    for (libs) |name| mod.linkSystemLibrary(name, .{});

    const translated = b.addTranslateC(.{
        .root_source_file = b.path(raylib_root ++ "/raylib.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const rl = translated.createModule();
    rl.linkLibrary(lib);
    return rl;
}
