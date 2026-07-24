//! A small persistent to-do CLI, built on the fixed-size-record design from
//! the "File-Backed To-Do Store" recipe. Unlike the recipe (one deterministic
//! run, verified by CI), this is a real program: it takes commands and keeps
//! its data in ~/.todos.db between runs.
//!
//!   zig build-exe examples/todo/todo.zig -femit-bin=todo
//!   ./todo add buy milk
//!   ./todo add write the docs
//!   ./todo done 1
//!   ./todo            # or: ./todo list
//!   ./todo rm 2
//!   ./todo clear

const std = @import("std");

// Fixed size, so record N lives at offset N * @sizeOf(Record) and can be read
// or rewritten in place. `deleted` is a tombstone: removing an item leaves its
// slot so later ids stay put.
const Record = extern struct {
    id: u32,
    done: bool,
    deleted: bool,
    len: u8,
    text: [120]u8,
};

const db_name = ".todos.db";

fn openDb(io: std.Io, dir: std.Io.Dir) !std.Io.File {
    return dir.openFile(io, db_name, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(io, db_name, .{ .read = true, .truncate = false }),
        else => return err,
    };
}

fn readRec(io: std.Io, file: std.Io.File, id: u32) !?Record {
    const offset = (id - 1) * @sizeOf(Record);
    if (offset >= try file.length(io)) return null;
    var rec: Record = undefined;
    _ = try file.readPositionalAll(io, std.mem.asBytes(&rec), offset);
    return rec;
}

fn writeRec(io: std.Io, file: std.Io.File, rec: Record) !void {
    const offset = (rec.id - 1) * @sizeOf(Record);
    try file.writePositionalAll(io, std.mem.asBytes(&rec), offset);
}

fn cmdAdd(io: std.Io, dir: std.Io.Dir, out: *std.Io.Writer, text: []const u8) !void {
    if (text.len == 0) {
        try out.writeAll("usage: todo add <text>\n");
        return;
    }
    const file = try openDb(io, dir);
    defer file.close(io);

    const end = try file.length(io);
    const id: u32 = @intCast(end / @sizeOf(Record) + 1);
    var rec: Record = .{
        .id = id,
        .done = false,
        .deleted = false,
        .len = @intCast(@min(text.len, 120)),
        .text = @splat(0),
    };
    @memcpy(rec.text[0..rec.len], text[0..rec.len]);
    try file.writePositionalAll(io, std.mem.asBytes(&rec), end);
    try out.print("added {d}: {s}\n", .{ id, text[0..rec.len] });
}

fn cmdList(io: std.Io, dir: std.Io.Dir, out: *std.Io.Writer) !void {
    const file = try openDb(io, dir);
    defer file.close(io);

    const end = try file.length(io);
    var offset: u64 = 0;
    var shown: usize = 0;
    while (offset < end) : (offset += @sizeOf(Record)) {
        var rec: Record = undefined;
        _ = try file.readPositionalAll(io, std.mem.asBytes(&rec), offset);
        if (rec.deleted) continue;
        try out.print("{d:>3}  [{s}]  {s}\n", .{
            rec.id,
            if (rec.done) "x" else " ",
            rec.text[0..rec.len],
        });
        shown += 1;
    }
    if (shown == 0) try out.writeAll("(no items)\n");
}

fn cmdUpdate(
    io: std.Io,
    dir: std.Io.Dir,
    out: *std.Io.Writer,
    id: u32,
    comptime what: enum { done, toggle, remove },
) !void {
    const file = try openDb(io, dir);
    defer file.close(io);

    var rec = (try readRec(io, file, id)) orelse {
        try out.print("no item {d}\n", .{id});
        return;
    };
    if (rec.deleted) {
        try out.print("no item {d}\n", .{id});
        return;
    }
    switch (what) {
        .done => rec.done = true,
        .toggle => rec.done = !rec.done,
        .remove => rec.deleted = true,
    }
    try writeRec(io, file, rec);
    switch (what) {
        .done => try out.print("done {d}\n", .{id}),
        .toggle => try out.print("{d} is now {s}\n", .{ id, if (rec.done) "done" else "todo" }),
        .remove => try out.print("removed {d}\n", .{id}),
    }
}

fn usage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\todo - a tiny persistent to-do list (~/.todos.db)
        \\
        \\  todo add <text>   add an item
        \\  todo list         list items (default)
        \\  todo done <id>    mark an item done
        \\  todo toggle <id>  flip an item's done state
        \\  todo rm <id>      remove an item
        \\  todo clear        delete every item
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // The process arena is freed automatically on exit, so short-lived
    // allocations here need no matching frees (and no leak reports).
    const arena = init.arena.allocator();

    var buf: [2048]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    // Keep the database in the home directory so it is the same list wherever
    // you run from. Fall back to the current directory if HOME is unset.
    var dir = std.Io.Dir.cwd();
    var home_dir: ?std.Io.Dir = null;
    if (init.environ_map.get("HOME")) |home| {
        if (dir.openDir(io, home, .{})) |hd| {
            home_dir = hd;
            dir = hd;
        } else |_| {}
    }
    defer if (home_dir) |*hd| hd.close(io);

    const argv = try init.minimal.args.toSlice(arena);
    const cmd: []const u8 = if (argv.len >= 2) argv[1] else "list";

    if (std.mem.eql(u8, cmd, "list")) {
        try cmdList(io, dir, out);
    } else if (std.mem.eql(u8, cmd, "add")) {
        // Join the rest of argv so quotes are optional: `todo add buy milk`.
        var text: std.ArrayList(u8) = .empty;
        for (argv[2..], 0..) |word, i| {
            if (i > 0) try text.append(arena, ' ');
            try text.appendSlice(arena, word);
        }
        try cmdAdd(io, dir, out, text.items);
    } else if (std.mem.eql(u8, cmd, "done")) {
        try cmdUpdate(io, dir, out, try argId(argv, out), .done);
    } else if (std.mem.eql(u8, cmd, "toggle")) {
        try cmdUpdate(io, dir, out, try argId(argv, out), .toggle);
    } else if (std.mem.eql(u8, cmd, "rm")) {
        try cmdUpdate(io, dir, out, try argId(argv, out), .remove);
    } else if (std.mem.eql(u8, cmd, "clear")) {
        dir.deleteFile(io, db_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try out.writeAll("cleared\n");
    } else {
        try usage(out);
    }
}

// Parse the id argument, defaulting to 0 (which no record has) on a bad or
// missing value so the update reports "no item" rather than crashing.
fn argId(argv: []const [:0]const u8, out: *std.Io.Writer) !u32 {
    if (argv.len < 3) {
        try out.print("usage: todo {s} <id>\n", .{argv[1]});
        return 0;
    }
    return std.fmt.parseInt(u32, argv[2], 10) catch 0;
}

// The tests drive the same file operations `main` does, against a throwaway
// temp directory, so `zig build verify` catches API drift here too even though
// the example is not an output-diffed snippet. `std.testing.io` is the Io, and
// a fixed writer swallows the command output the assertions don't need.
const testing = std.testing;

test "add assigns sequential ids and stores text" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try cmdAdd(io, tmp.dir, &w, "alpha");
    try cmdAdd(io, tmp.dir, &w, "beta");
    try cmdAdd(io, tmp.dir, &w, "gamma");

    const file = try openDb(io, tmp.dir);
    defer file.close(io);

    const r1 = (try readRec(io, file, 1)).?;
    try testing.expectEqual(@as(u32, 1), r1.id);
    try testing.expectEqualStrings("alpha", r1.text[0..r1.len]);
    try testing.expect(!r1.done and !r1.deleted);

    const r3 = (try readRec(io, file, 3)).?;
    try testing.expectEqualStrings("gamma", r3.text[0..r3.len]);

    // Nothing past the last record.
    try testing.expect((try readRec(io, file, 4)) == null);
}

test "done, toggle, and remove update in place" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try cmdAdd(io, tmp.dir, &w, "one");
    try cmdAdd(io, tmp.dir, &w, "two");

    try cmdUpdate(io, tmp.dir, &w, 1, .done);
    try cmdUpdate(io, tmp.dir, &w, 2, .remove);

    {
        const file = try openDb(io, tmp.dir);
        defer file.close(io);
        try testing.expect((try readRec(io, file, 1)).?.done);
        try testing.expect((try readRec(io, file, 2)).?.deleted);
    }

    // Toggle flips the flag back.
    try cmdUpdate(io, tmp.dir, &w, 1, .toggle);
    {
        const file = try openDb(io, tmp.dir);
        defer file.close(io);
        try testing.expect(!(try readRec(io, file, 1)).?.done);
    }
}
