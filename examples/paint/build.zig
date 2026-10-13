//! The paint program.
//!
//!   zig build test     run the engine's tests (no window needed)
//!   zig build demo     draw the demo picture into zig-out/demo.png
//!   zig build web      build the browser front end: zig-out/web/paint.wasm
//!
//! The engine is plain Zig with no dependencies, so the browser build needs no
//! Emscripten and no SDK: it is `wasm32-freestanding`, built by the same
//! compiler as everything else. The guide's own build.zig builds it too, into
//! web/public/paint/, so the page runs exactly what CI built.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const web_step = b.step("web", "Build the browser front end into zig-out/web");
    const web = addWeb(b, b.path("src"), if (optimize == .debug) .small else optimize);
    web_step.dependOn(&b.addInstallArtifact(web, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
}

/// The browser build. Public so the guide's build.zig can call it with its own
/// path to `src/`, and both builds stay one definition.
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
    // A library of exported functions, not a program with a main: the page
    // calls into it.
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
}
