//! Build every tutorial snippet to `wasm32-wasi` and verify it behaves.
//!
//! The same artifact serves two purposes:
//!   1. CI proof that the snippet compiles & runs against current Zig master.
//!   2. The `.wasm` shipped to the browser so readers can run it client-side.
//!
//! A snippet containing `pub fn main` is built as an executable; otherwise it
//! is built as a test binary. Both are executed through a WASI shim under Node,
//! which is the same interface the browser playground implements.

const std = @import("std");

const snippets_root = "snippets";
const docs_root = "web/src/content/docs";
const wasm_out_dir = "../web/public/wasm";

pub fn build(b: *std.Build) void {
    // Default to .small (the mode formerly spelled ReleaseSmall) rather than
    // `standardOptimizeOption`, which yields .debug unless `-Drelease` is
    // passed — a ~30x size difference in the wasm every reader downloads
    // (1.4 MB vs ~46 KB). Master lowercased these enum tags; the `-Doptimize=`
    // CLI still accepts the old ReleaseSmall/Debug spellings.
    const optimize = b.option(
        std.lang.Optimize,
        "optimize",
        "Optimization mode for snippets (default: small)",
    ) orelse .small;
    // simd128 is opt-in for wasm32, and without it `std.simd.suggestVectorLength`
    // returns null, which would compile the SIMD path *out* of any snippet that
    // guards on it: the reader's browser would silently run scalar code under a
    // page claiming otherwise. So the snippets that teach vectors ask for it by
    // name with `//! simd`, and only those get it.
    //
    // It used to be on for every snippet, which was a mistake. LLVM
    // auto-vectorizes std's memcpy and formatting paths, so hello-world shipped
    // 159 v128 opcodes it never asked for, and any engine without SIMD rejected
    // *every* snippet on the site at validation time rather than the four that
    // are actually about SIMD. That is a real population: SpiderMonkey turns
    // wasm SIMD off on x86 CPUs without SSE4.1, whatever the Firefox version.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const simd_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
    });

    const verify_step = b.step("verify", "Compile and run every snippet (CI gate)");
    const manifest_step = b.step("manifest", "Emit snippets.json for the web build");
    const deprecations_step = b.step(
        "deprecations",
        "Fail on any std symbol the installed compiler marks deprecated",
    );

    var snippets: std.ArrayList(Snippet) = .empty;
    collect(b, snippets_root, &snippets) catch |err| {
        std.debug.panic("failed to scan {s}: {t}", .{ snippets_root, err });
    };

    // A rename that leaves the old name behind as a working alias is invisible
    // to every other gate here: the snippet compiles, the test passes, the
    // nightly stays green, and the guide teaches a name upstream has moved on
    // from. This step reads the deprecation list out of the std source that
    // shipped with the compiler in use, so there is nothing to maintain.
    {
        const check = b.addSystemCommand(&.{ "node", "tools/check-deprecations.mjs" });
        check.addArg(b.graph.zig_exe);
        // The std source is an input the build cache cannot see. Naming the
        // compiler version on the command line is what re-runs this after a
        // toolchain bump, which is exactly when a rename shows up.
        check.addArg(b.fmt("{f}", .{@import("builtin").zig_version}));
        // Every scanned file as a tracked file argument, for the same reason
        // the `.expected` files are: editing one has to invalidate the run.
        for (snippets.items) |snippet| check.addFileArg(b.path(snippet.path));
        var docs: std.ArrayList([]const u8) = .empty;
        collectDocs(b, docs_root, &docs) catch |err| {
            std.debug.panic("failed to scan {s}: {t}", .{ docs_root, err });
        };
        for (docs.items) |doc| check.addFileArg(b.path(doc));
        check.addFileArg(b.path("build.zig"));
        check.expectExitCode(0);

        deprecations_step.dependOn(&check.step);
        verify_step.dependOn(&check.step);
    }

    for (snippets.items) |snippet| {
        const module = b.createModule(.{
            .root_source_file = b.path(snippet.path),
            .target = if (snippet.native)
                b.graph.host
            else if (snippet.simd)
                simd_target
            else
                target,
            .optimize = optimize,
            // A `//! link:`/`//! cinclude:` snippet needs libc plus the named
            // system libraries. wasm32-wasi cannot resolve those, so these are
            // always host builds (see `native` below).
            .link_libc = if (snippet.link_libs.len > 0 or snippet.c_includes.len > 0) true else null,
        });
        if (snippet.link_libs.len > 0 or snippet.c_includes.len > 0) {
            // @cImport was removed from the language on Zig master; C headers
            // now come through a build-system translate-c step. We synthesize a
            // header that includes the requested C headers, translate it, and
            // hand the snippet the result as `@import("c")`.
            const translate = b.addTranslateC(.{
                .root_source_file = cImportHeader(b, snippet.link_libs, snippet.c_includes),
                .target = b.graph.host,
                .optimize = optimize,
                .link_libc = true,
            });
            for (snippet.link_libs) |lib| translate.linkSystemLibrary(lib, .{});
            module.addImport("c", translate.createModule());
        }

        const compile = if (snippet.kind == .exe)
            b.addExecutable(.{ .name = snippet.name, .root_module = module })
        else
            b.addTest(.{ .name = snippet.name, .root_module = module });

        if (snippet.native) {
            // `//! norun` on a host build: compile and link it, but do not run
            // it. The X11 snippet opens a window and waits for a keypress,
            // which no CI step can sit through — but linking it against the
            // real libX11 still gates translate-c against header drift, which
            // is the whole reason it is here.
            if (snippet.norun) {
                verify_step.dependOn(&compile.step);
                continue;
            }

            // Host binary: run it through the same runner shape as the wasm
            // path, so a sibling `.expected` file is diffed here too rather
            // than silently ignored. Nothing to ship to the browser, so the
            // site renders this snippet without a Run button.
            const run = b.addSystemCommand(&.{ "node", "tools/run-native.mjs" });
            run.addArtifactArg2(compile, .{});
            run.expectExitCode(0);

            // Tracked as a file argument for the same reason as below:
            // editing the expectation must invalidate the cached run.
            if (snippet.expected) |expected_path| {
                run.addFileArg(b.path(expected_path));
            }

            verify_step.dependOn(&run.step);
            continue;
        }

        // Ship the wasm to the site's public dir, keyed by chapter/name.
        const install = b.addInstallFileWithDir(
            compile.getEmittedBin(),
            .{ .custom = wasm_out_dir },
            b.fmt("{s}.wasm", .{snippet.name}),
        );
        b.getInstallStep().dependOn(&install.step);

        if (snippet.runnable) {
            // Execute it through the WASI shim, exactly as the browser will.
            // `--no-warnings` keeps Node's WASI ExperimentalWarning off stderr,
            // which the Run step would otherwise treat as a failure.
            const run = b.addSystemCommand(&.{ "node", "--no-warnings", "tools/run-wasi.mjs" });
            run.addFileArg(compile.getEmittedBin());
            run.expectExitCode(0);

            // Passed as a *file argument* rather than compared via
            // `expectStdOutEqual`, so the build system tracks it as an input
            // and editing it actually invalidates the cache.
            if (snippet.expected) |expected_path| {
                run.addFileArg(b.path(expected_path));
            }

            verify_step.dependOn(&run.step);
        } else {
            // `//! norun`: compile-only, but still a real gate against API drift.
            verify_step.dependOn(&compile.step);
        }
    }

    // The interactive example under `examples/` is not a snippet: it takes
    // commands rather than producing one diffable output, so it is not scanned
    // above. Its unit tests still gate against API drift, run through the same
    // native runner as the threaded and socket snippets.
    {
        const example = b.addTest(.{
            .name = "example-todo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/todo/todo.zig"),
                .target = b.graph.host,
                .optimize = optimize,
            }),
        });
        const run = b.addSystemCommand(&.{ "node", "tools/run-native.mjs" });
        run.addArtifactArg2(example, .{});
        run.expectExitCode(0);
        verify_step.dependOn(&run.step);
    }

    // Record the exact compiler that verified these snippets, so the site can
    // state it rather than claiming a version nobody checked.
    const build_info = b.addWriteFiles().add("build-info.json", b.fmt(
        \\{{"zigVersion":"{f}","snippetCount":{d}}}
        \\
    , .{ @import("builtin").zig_version, snippets.items.len }));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        build_info,
        .{ .custom = wasm_out_dir },
        "build-info.json",
    ).step);

    const manifest = writeManifest(b, snippets.items);
    const install_manifest = b.addInstallFileWithDir(
        manifest,
        .{ .custom = wasm_out_dir },
        "snippets.json",
    );
    manifest_step.dependOn(&install_manifest.step);
    b.getInstallStep().dependOn(&install_manifest.step);
}

const Snippet = struct {
    /// Unique slug, e.g. `02-language.optionals`.
    name: []const u8,
    /// Path to the `.zig` source, relative to the build root.
    path: []const u8,
    /// Chapter directory the snippet lives in.
    chapter: []const u8,
    kind: Kind,
    /// Optional sibling `.expected` file holding exact stdout.
    expected: ?[]const u8,
    /// False for snippets marked `//! norun`: still compiled (so the API gate
    /// still applies) but never executed, because they need capabilities the
    /// browser sandbox lacks — a real filesystem, sockets.
    runnable: bool,
    /// The `//! norun` marker itself, kept separate from `runnable` because
    /// `runnable` is already false for every native snippet. A native snippet
    /// is normally still executed on the host; this one says don't.
    norun: bool,
    /// True for snippets marked `//! native`: built and run for the host
    /// instead of wasm32-wasi, because they do not compile for wasm at all
    /// (threads are the main case — wasm32-wasi is single-threaded). Also true
    /// whenever `link_libs` is non-empty, since linking a system C library is a
    /// host-only affair. Still fully gated by CI, just not shipped to the
    /// browser.
    native: bool,
    /// True for snippets marked `//! simd`: built with the wasm `simd128`
    /// feature, so `std.simd.suggestVectorLength` answers and the artifact
    /// really does contain vector instructions. Only the chapters that teach
    /// vectors ask for this; everything else stays baseline wasm so it runs on
    /// engines without SIMD.
    simd: bool,
    /// System libraries named by `//! link:` header lines, e.g. `sqlite3`.
    /// Each pulls in libc and is linked into the host binary. Empty for the
    /// pure-Zig snippets that are the common case.
    link_libs: []const []const u8,
    /// C headers named by `//! cinclude:` lines, e.g. `zlib.h`. These are what
    /// translate-c includes. When absent, the header defaults to `<lib>.h` for
    /// each linked library, which holds when a library's header matches its
    /// name (sqlite3) but not when it does not (lib `z` ships `zlib.h`).
    c_includes: []const []const u8,

    const Kind = enum { exe, @"test" };
};

/// Walk `root` and classify every `.zig` file found.
fn collect(b: *std.Build, root: []const u8, out: *std.ArrayList(Snippet)) !void {
    const io = b.graph.io;
    const build_root = b.root.root_dir.handle;

    // Discovering snippets by directory listing is exactly the kind of side
    // effect the configuration cache cannot track: without this, adding or
    // deleting a snippet is silently ignored (and a deleted one keeps failing
    // the build from a stale graph) until build.zig itself changes.
    b.graph.poisonCache();

    var dir = try build_root.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        // `_name.zig` is a helper module imported by a snippet, not a
        // snippet in its own right.
        if (std.mem.startsWith(u8, entry.basename, "_")) continue;

        const rel = b.pathJoin(&.{ root, entry.path });
        const source = try build_root.readFileAlloc(io, rel, b.allocator, .limited(1 << 20));

        const stem = entry.basename[0 .. entry.basename.len - ".zig".len];
        const chapter = std.Io.Dir.path.dirname(entry.path) orelse ".";

        // A sibling `.expected` file, if the author supplied one.
        const expected_rel = b.fmt("{s}/{s}.expected", .{ root, replaceExt(b, entry.path) });
        const expected: ?[]const u8 = if (fileExists(b, expected_rel)) expected_rel else null;

        const link_libs = parseDirectiveList(b, source, "//! link:");
        const c_includes = parseDirectiveList(b, source, "//! cinclude:");
        const norun = std.mem.find(u8, source, "//! norun") != null;
        const simd = std.mem.find(u8, source, "//! simd") != null;
        // A C-linked snippet is inherently a host build; treat it as native
        // even without an explicit `//! native` line.
        const native = std.mem.find(u8, source, "//! native") != null or
            link_libs.len > 0 or c_includes.len > 0;

        try out.append(b.allocator, .{
            .name = b.fmt("{s}.{s}", .{ chapter, stem }),
            .path = rel,
            .chapter = b.dupe(chapter),
            .kind = if (std.mem.find(u8, source, "pub fn main") != null) .exe else .@"test",
            .expected = expected,
            // `//! norun` and native builds are both unshippable to the browser.
            .runnable = !norun and !native,
            .norun = norun,
            .native = native,
            .simd = simd,
            .link_libs = link_libs,
            .c_includes = c_includes,
        });
    }

    // Deterministic ordering so builds are reproducible.
    std.mem.sort(Snippet, out.items, {}, struct {
        fn lessThan(_: void, a: Snippet, c: Snippet) bool {
            return std.mem.order(u8, a.name, c.name) == .lt;
        }
    }.lessThan);
}

/// Walk `root` for chapter pages, so the deprecation check can hold prose to
/// the same standard as code. A chapter that names an old symbol without
/// naming the current one is stale in exactly the way a snippet would be.
fn collectDocs(b: *std.Build, root: []const u8, out: *std.ArrayList([]const u8)) !void {
    const io = b.graph.io;
    const build_root = b.root.root_dir.handle;

    // Same reason as `collect`: a directory listing is a side effect the
    // configuration cache cannot track, so a new chapter would go unscanned.
    b.graph.poisonCache();

    var dir = try build_root.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".mdx")) continue;
        try out.append(b.allocator, b.pathJoin(&.{ root, entry.path }));
    }

    std.mem.sort([]const u8, out.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.order(u8, a, c) == .lt;
        }
    }.lessThan);
}

/// Serialize the snippet index the Astro build reads to render playgrounds.
fn writeManifest(b: *std.Build, snippets: []const Snippet) std.Build.LazyPath {
    var allocating: std.Io.Writer.Allocating = .init(b.allocator);
    const w = &allocating.writer;

    w.writeAll("[\n") catch @panic("OOM");
    for (snippets, 0..) |s, i| {
        w.print(
            \\  {{"name":"{s}","chapter":"{s}","kind":"{t}","source":"{s}","wasm":"{s}.wasm","runnable":{}}}
        , .{ s.name, s.chapter, s.kind, s.path, s.name, s.runnable }) catch @panic("OOM");
        w.writeAll(if (i + 1 == snippets.len) "\n" else ",\n") catch @panic("OOM");
    }
    w.writeAll("]\n") catch @panic("OOM");

    return b.addWriteFiles().add("snippets.json", allocating.written());
}

/// Build a C header for translate-c to consume: one `#include` per requested
/// header. When a snippet names no `//! cinclude:` headers, fall back to
/// `<lib>.h` for each linked library, which holds when a library's header
/// matches its name (sqlite3 -> sqlite3.h) but not otherwise (lib `z` ->
/// zlib.h), which is exactly why `//! cinclude:` exists.
fn cImportHeader(
    b: *std.Build,
    libs: []const []const u8,
    includes: []const []const u8,
) std.Build.LazyPath {
    var allocating: std.Io.Writer.Allocating = .init(b.allocator);
    if (includes.len > 0) {
        for (includes) |hdr| {
            allocating.writer.print("#include <{s}>\n", .{hdr}) catch @panic("OOM");
        }
    } else {
        for (libs) |lib| {
            allocating.writer.print("#include <{s}.h>\n", .{lib}) catch @panic("OOM");
        }
    }
    return b.addWriteFiles().add("c_imports.h", allocating.written());
}

/// Collect the values of a repeated `//! <prefix>` header directive. Each value
/// is a comma- or space-separated list, so both `//! link: sqlite3` and
/// `//! link: foo, bar` work, and the directive may repeat across lines.
fn parseDirectiveList(b: *std.Build, source: []const u8, prefix: []const u8) []const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        var toks = std.mem.tokenizeAny(u8, trimmed[prefix.len..], " \t,");
        while (toks.next()) |tok| items.append(b.allocator, b.dupe(tok)) catch @panic("OOM");
    }
    return items.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn replaceExt(b: *std.Build, path: []const u8) []const u8 {
    return b.dupe(path[0 .. path.len - ".zig".len]);
}

fn fileExists(b: *std.Build, rel: []const u8) bool {
    b.root.root_dir.handle.access(b.graph.io, rel, .{}) catch return false;
    return true;
}

fn readFile(b: *std.Build, rel: []const u8) []const u8 {
    return b.root.root_dir.handle.readFileAlloc(
        b.graph.io,
        rel,
        b.allocator,
        .limited(1 << 20),
    ) catch |err| {
        std.debug.panic("failed to read {s}: {t}", .{ rel, err });
    };
}
