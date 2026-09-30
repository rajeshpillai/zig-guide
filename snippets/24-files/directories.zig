//! title: Directories
//! Create a tree, list it, walk it, measure it, rename it and delete it.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const cwd = Io.Dir.cwd();

    // 1. Create a small project tree. createDirPath makes every missing
    //    directory on the way, like `mkdir -p`.
    try out.print("1. create\n", .{});
    try cwd.createDirPath(io, "project/src/util");
    try cwd.createDirPath(io, "project/docs");
    const files = [_]struct { path: []const u8, data: []const u8 }{
        .{ .path = "project/README.md", .data = "# project\n" },
        .{ .path = "project/src/main.zig", .data = "pub fn main() void {}\n" },
        .{ .path = "project/src/util/math.zig", .data = "pub fn add(a: u8, b: u8) u8 {\n    return a + b;\n}\n" },
        .{ .path = "project/docs/notes.txt", .data = "todo\n" },
    };
    for (files) |f| try cwd.writeFile(io, .{ .sub_path = f.path, .data = f.data });
    try out.print("   {d} files written\n", .{files.len});

    // Creating a directory that exists is an error. createDirPath is not.
    if (cwd.createDir(io, "project", .default_dir)) |_| {
        try out.print("   createDir again: ok\n", .{});
    } else |err| try out.print("   createDir again: {t}\n", .{err});
    try cwd.createDirPath(io, "project/src");
    try out.print("   createDirPath again: ok\n", .{});

    // 2. One level, sorted.
    try out.print("2. list project/\n", .{});
    {
        var dir = try cwd.openDir(io, "project", .{ .iterate = true });
        defer dir.close(io);
        try listSorted(io, gpa, dir, out);
    }

    // 3. Every level, sorted, with sizes.
    try out.print("3. walk project/\n", .{});
    try walkSorted(io, gpa, cwd, "project", out);

    // 4. Rename a directory. Everything inside it moves too.
    try out.print("4. rename project/docs -> project/doc\n", .{});
    try cwd.rename("project/docs", cwd, "project/doc", io);
    if (cwd.statFile(io, "project/doc/notes.txt", .{})) |st| {
        try out.print("   project/doc/notes.txt is {d} bytes\n", .{st.size});
    } else |err| return err;

    // 5. Delete. deleteDir only removes an empty directory.
    try out.print("5. delete\n", .{});
    if (cwd.deleteDir(io, "project")) |_| {
        try out.print("   deleteDir: ok\n", .{});
    } else |err| try out.print("   deleteDir: {t}\n", .{err});
    try cwd.deleteTree(io, "project");
    if (cwd.statFile(io, "project", .{})) |_| {
        try out.print("   deleteTree: project still exists\n", .{});
    } else |err| try out.print("   deleteTree: done, stat now gives {t}\n", .{err});
}

const Item = struct {
    name: []const u8,
    kind: Io.File.Kind,

    fn lessThan(_: void, a: Item, b: Item) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

fn listSorted(io: Io, gpa: Allocator, dir: Io.Dir, out: *Io.Writer) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The order entries come back in is up to the filesystem. Collect them
    // and sort, so the output is the same everywhere.
    var items: std.ArrayList(Item) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // `entry.name` is only valid until the next call to `next`.
        try items.append(arena, .{ .name = try arena.dupe(u8, entry.name), .kind = entry.kind });
    }
    std.mem.sort(Item, items.items, {}, Item.lessThan);
    for (items.items) |item| try out.print("   {t:<9} {s}\n", .{ item.kind, item.name });
}

fn walkSorted(io: Io, gpa: Allocator, parent: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = try parent.openDir(io, name, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var items: std.ArrayList(Item) = .empty;
    var total: u64 = 0;
    while (try walker.next(io)) |entry| {
        try items.append(arena, .{ .name = try arena.dupe(u8, entry.path), .kind = entry.kind });
        if (entry.kind == .file) {
            // `entry.dir` is the directory that holds this entry, so stat
            // by basename there rather than building a path from the top.
            total += (try entry.dir.statFile(io, entry.basename, .{})).size;
        }
    }
    std.mem.sort(Item, items.items, {}, Item.lessThan);
    for (items.items) |item| {
        const depth = std.mem.count(u8, item.name, "/");
        try out.splatByteAll(' ', 3 + 2 * depth);
        try out.print("{s}{s}\n", .{ std.Io.Dir.path.basename(item.name), if (item.kind == .directory) "/" else "" });
    }
    try out.print("   {d} entries, {d} bytes in files\n", .{ items.items.len, total });
}
