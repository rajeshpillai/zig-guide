//! title: Open, Read, Close
//! Three ways to read a file, and what each one does at its limit.

const std = @import("std");

const Io = std.Io;

// The playground starts every run in an empty directory, so the program
// writes the file it is about to read. 18 bytes: three lines of 5, 6 and 5
// characters, each followed by a newline.
const shopping = "apples\nbread\nmilk\n";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = "shopping.txt", .data = shopping });

    // 1. The whole file, into memory the allocator owns.
    try out.print("1. readFileAlloc\n", .{});
    const whole = try dir.readFileAlloc(io, "shopping.txt", gpa, .limited(1024));
    defer gpa.free(whole);
    try out.print("   read {d} bytes\n", .{whole.len});

    // The limit counts the file size too. Reaching it is an error, not only
    // going past it, so a limit equal to the size fails.
    for ([_]usize{ 17, 18, 19 }) |limit| {
        if (dir.readFileAlloc(io, "shopping.txt", gpa, .limited(limit))) |bytes| {
            defer gpa.free(bytes);
            try out.print("   limit {d}: ok, {d} bytes\n", .{ limit, bytes.len });
        } else |err| {
            try out.print("   limit {d}: {t}\n", .{ limit, err });
        }
    }

    // 2. Into a buffer we already have. No allocator, but a full buffer is
    //    ambiguous: the file fitted exactly, or there was more.
    try out.print("2. readFile\n", .{});
    var small: [8]u8 = undefined;
    const part = try dir.readFile(io, "shopping.txt", &small);
    try out.print("   8-byte buffer: {d} bytes \"{f}\"\n", .{ part.len, std.zig.fmtString(part) });
    var large: [64]u8 = undefined;
    const all = try dir.readFile(io, "shopping.txt", &large);
    try out.print("   64-byte buffer: {d} bytes\n", .{all.len});

    // 3. A handle we open and close ourselves. Ask the file its length,
    //    then read exactly that many bytes from offset 0.
    try out.print("3. openFile\n", .{});
    {
        const file = try dir.openFile(io, "shopping.txt", .{});
        defer file.close(io);

        // A file length is a u64. A length in memory is a usize, which is
        // 32 bits on wasm32. The cast fails rather than truncating.
        const len = try file.length(io);
        const bytes = try gpa.alloc(u8, std.math.cast(usize, len) orelse return error.FileTooBig);
        defer gpa.free(bytes);
        const n = try file.readPositionalAll(io, bytes, 0);
        try out.print("   length {d}, read {d}\n", .{ len, n });
        try out.print("   first line: {s}\n", .{bytes[0..std.mem.findScalar(u8, bytes, '\n').?]});
    }

    // 4. A file that is not there. The error names the problem, so the
    //    caller can decide it is not a problem at all.
    try out.print("4. missing file\n", .{});
    if (dir.openFile(io, "settings.txt", .{})) |file| {
        file.close(io);
    } else |err| switch (err) {
        error.FileNotFound => try out.print("   settings.txt: FileNotFound, using defaults\n", .{}),
        else => return err,
    }

    try dir.deleteFile(io, "shopping.txt");
}
