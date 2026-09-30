//! title: When Things Go Wrong
//! What a file or directory is, six operations that fail and the error each
//! one names, turning errors into messages, and cleaning up after a failure.

const std = @import("std");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello\n" });
    try dir.createDirPath(io, "archive");

    // 1. stat: what is at a path, without opening it.
    try out.print("1. stat\n", .{});
    for ([_][]const u8{ "notes.txt", "archive" }) |path| {
        const st = try dir.statFile(io, path, .{});
        try out.print("   {s:<10} kind {t}", .{ path, st.kind });
        // A directory's size is up to the filesystem (4096 on ext4, 0 in
        // memory) and says nothing about what is in it.
        if (st.kind == .file) try out.print(", size {d}", .{st.size});
        try out.writeByte('\n');
    }

    // 2. Six operations that fail, and the error each one returns.
    try out.print("2. six failures\n", .{});
    try out.print("   open a file that is not there:     {t}\n", .{fails(dir.openFile(io, "missing.txt", .{}), io)});
    try out.print("   create a file in a missing dir:    {t}\n", .{fails(dir.createFile(io, "drafts/new.txt", .{}), io)});
    try out.print("   open a directory as a file:        {t}\n", .{fails(dir.openFile(io, "archive", .{ .allow_directory = false }), io)});
    try out.print("   use a file as a directory:         {t}\n", .{fails(dir.openFile(io, "notes.txt/x", .{}), io)});
    try out.print("   deleteFile on a directory:         {t}\n", .{failsVoid(dir.deleteFile(io, "archive"))});
    try out.print("   deleteFile on a missing file:      {t}\n", .{failsVoid(dir.deleteFile(io, "missing.txt"))});

    // 3. The same errors as messages for a person.
    try out.print("3. messages\n", .{});
    for ([_][]const u8{ "missing.txt", "archive", "notes.txt/x", "notes.txt" }) |path| {
        try out.print("   {s:<12} ", .{path});
        loadNotes(io, dir, path, out) catch |err| try out.print("{s}\n", .{message(err)});
    }

    // 4. A write that fails halfway, with and without cleanup.
    try out.print("4. cleanup\n", .{});
    for ([_]bool{ false, true }) |cleanup| {
        exportReport(io, dir, "report.txt", cleanup) catch |err| {
            try out.print("   cleanup={}: {t}, ", .{ cleanup, err });
        };
        if (dir.statFile(io, "report.txt", .{})) |st| {
            try out.print("report.txt left behind, {d} bytes\n", .{st.size});
            try dir.deleteFile(io, "report.txt");
        } else |_| {
            try out.print("no report.txt\n", .{});
        }
    }

    try dir.deleteFile(io, "notes.txt");
    try dir.deleteDir(io, "archive");
}

/// The error an operation returned. The operation is expected to fail, so
/// a success is closed and reported as a mistake in this program.
fn fails(result: anytype, io: Io) anyerror {
    if (result) |file| {
        file.close(io);
        return error.UnexpectedSuccess;
    } else |err| return err;
}

fn failsVoid(result: anytype) anyerror {
    if (result) |_| return error.UnexpectedSuccess else |err| return err;
}

fn loadNotes(io: Io, dir: Io.Dir, path: []const u8, out: *Io.Writer) !void {
    // Without `.allow_directory = false`, opening a directory succeeds and
    // the error only arrives on the first read, and differs by system.
    const file = try dir.openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    var buf: [64]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    try out.print("loaded {d} bytes\n", .{n});
}

/// One sentence per error a person can act on. Everything else is printed
/// by name, because hiding it helps nobody.
fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "not found: check the name and the folder",
        error.IsDir => "that is a folder, not a file",
        error.NotDir => "part of the path is a file, not a folder",
        error.AccessDenied, error.PermissionDenied => "no permission to read it",
        error.NoSpaceLeft => "the disk is full",
        else => @errorName(err),
    };
}

/// Writes three lines of a report. The third one fails, as a real check
/// on the data might.
fn exportReport(io: Io, dir: Io.Dir, name: []const u8, cleanup: bool) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    // Runs only if this function returns an error. `defer` above still
    // closes the file first, because defers run in reverse order.
    errdefer if (cleanup) dir.deleteFile(io, name) catch {};

    var buf: [64]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll("total: 3\n");
    try w.interface.writeAll("item 1\n");
    try w.interface.flush();
    return error.InvalidItem;
}
