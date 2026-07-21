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
const wasm_out_dir = "../web/public/wasm";

pub fn build(b: *std.Build) void {
    // Default to ReleaseSmall rather than `standardOptimizeOption`, which
    // yields Debug unless `-Drelease` is passed — a ~30x size difference in
    // the wasm every reader downloads (1.4 MB vs ~46 KB).
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode for snippets (default: ReleaseSmall)",
    ) orelse .ReleaseSmall;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const verify_step = b.step("verify", "Compile and run every snippet (CI gate)");
    const manifest_step = b.step("manifest", "Emit snippets.json for the web build");

    var snippets: std.ArrayList(Snippet) = .empty;
    collect(b, snippets_root, &snippets) catch |err| {
        std.debug.panic("failed to scan {s}: {t}", .{ snippets_root, err });
    };

    for (snippets.items) |snippet| {
        const module = b.createModule(.{
            .root_source_file = b.path(snippet.path),
            .target = target,
            .optimize = optimize,
        });

        const compile = if (snippet.kind == .exe)
            b.addExecutable(.{ .name = snippet.name, .root_module = module })
        else
            b.addTest(.{ .name = snippet.name, .root_module = module });

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
    /// browser sandbox lacks — threads, a real filesystem, sockets.
    runnable: bool,

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

        const rel = b.pathJoin(&.{ root, entry.path });
        const source = try build_root.readFileAlloc(io, rel, b.allocator, .limited(1 << 20));

        const stem = entry.basename[0 .. entry.basename.len - ".zig".len];
        const chapter = std.fs.path.dirname(entry.path) orelse ".";

        // A sibling `.expected` file, if the author supplied one.
        const expected_rel = b.fmt("{s}/{s}.expected", .{ root, replaceExt(b, entry.path) });
        const expected: ?[]const u8 = if (fileExists(b, expected_rel)) expected_rel else null;

        try out.append(b.allocator, .{
            .name = b.fmt("{s}.{s}", .{ chapter, stem }),
            .path = rel,
            .chapter = b.dupe(chapter),
            .kind = if (std.mem.indexOf(u8, source, "pub fn main") != null) .exe else .@"test",
            .expected = expected,
            .runnable = std.mem.indexOf(u8, source, "//! norun") == null,
        });
    }

    // Deterministic ordering so builds are reproducible.
    std.mem.sort(Snippet, out.items, {}, struct {
        fn lessThan(_: void, a: Snippet, c: Snippet) bool {
            return std.mem.order(u8, a.name, c.name) == .lt;
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
