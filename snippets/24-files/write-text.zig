//! title: Writing Text Files
//! Truncate or not, create only if new, append, the flush that was forgotten,
//! and replacing a file so a reader never sees half of it.

const std = @import("std");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [2048]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();

    // 1. createFile truncates by default. With `.truncate = false`, the new
    //    bytes are written over the start of the old ones and the rest stays.
    try out.print("1. truncate\n", .{});
    try writeText(io, dir, "note.txt", .{}, "first version\n");
    try writeText(io, dir, "note.txt", .{}, "v2\n");
    try show(io, gpa, dir, "note.txt", "   truncate = true: ", out);
    try writeText(io, dir, "note.txt", .{}, "first version\n");
    try writeText(io, dir, "note.txt", .{ .truncate = false }, "v2\n");
    try show(io, gpa, dir, "note.txt", "   truncate = false:", out);

    // 2. Create a file only if it does not exist yet.
    try out.print("2. exclusive\n", .{});
    for (0..2) |attempt| {
        if (dir.createFile(io, "id.txt", .{ .exclusive = true })) |file| {
            file.close(io);
            try out.print("   attempt {d}: created\n", .{attempt + 1});
        } else |err| {
            try out.print("   attempt {d}: {t}\n", .{ attempt + 1, err });
        }
    }

    // 3. Append: open the file, then start the writer at the end. The mode
    //    is read_write because asking for the length needs read access on
    //    WASI; on Linux or macOS write_only would do.
    try out.print("3. append\n", .{});
    try writeText(io, dir, "log.txt", .{}, "started\n");
    for ([_][]const u8{ "loaded 3 items\n", "stopped\n" }) |line| {
        const file = try dir.openFile(io, "log.txt", .{ .mode = .read_write });
        defer file.close(io);
        var buf: [64]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.seekTo(try file.length(io));
        try writer.interface.writeAll(line);
        try writer.interface.flush();
    }
    try show(io, gpa, dir, "log.txt", "", out);

    // 4. The bytes wait in the writer's buffer until a flush.
    try out.print("4. flush\n", .{});
    {
        const file = try dir.createFile(io, "lost.txt", .{});
        var buf: [64]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll("this line never reaches the file\n");
        try out.print("   buffered {d} bytes, file length {d}\n", .{ writer.interface.buffered().len, try file.length(io) });
        file.close(io); // closed without flush
    }
    try out.print("   after close: {d} bytes on disk\n", .{(try dir.statFile(io, "lost.txt", .{})).size});

    // 5. Replace a file in one step. The new content goes to a temporary
    //    file next to it, and a rename puts it in place.
    try out.print("5. atomic replace\n", .{});
    try writeText(io, dir, "config.txt", .{}, "port = 8080\n");
    {
        var atomic = try dir.createFileAtomic(io, "config.txt", .{ .replace = true });
        defer atomic.deinit(io);

        var buf: [64]u8 = undefined;
        var writer = atomic.file.writer(io, &buf);
        try writer.interface.writeAll("port = 9090\n");
        try writer.interface.flush();

        try show(io, gpa, dir, "config.txt", "   while writing:", out);
        try atomic.replace(io);
    }
    try show(io, gpa, dir, "config.txt", "   after replace:", out);

    // The same, but the program fails before `replace`. `deinit` deletes
    // the temporary file and the old content is untouched.
    {
        var atomic = try dir.createFileAtomic(io, "config.txt", .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, "port = ");
        // ...an error happens here, and we return before replace.
    }
    try show(io, gpa, dir, "config.txt", "   after a failed write:", out);
    try out.print("   files in the directory: {d}\n", .{try countEntries(io, dir)});

    for ([_][]const u8{ "note.txt", "id.txt", "log.txt", "lost.txt", "config.txt" }) |name| {
        try dir.deleteFile(io, name);
    }
}

fn writeText(io: Io, dir: Io.Dir, name: []const u8, options: Io.Dir.CreateFileOptions, text: []const u8) !void {
    const file = try dir.createFile(io, name, options);
    defer file.close(io);

    var buf: [64]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn show(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, name: []const u8, label: []const u8, out: *Io.Writer) !void {
    const text = try dir.readFileAlloc(io, name, gpa, .limited(4096));
    defer gpa.free(text);
    if (label.len == 0) {
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (lines.next()) |line| try out.print("   {s}\n", .{line});
    } else {
        try out.print("{s} \"{f}\"\n", .{ label, std.zig.fmtString(text) });
    }
}

fn countEntries(io: Io, dir: Io.Dir) !usize {
    var d = try dir.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}
