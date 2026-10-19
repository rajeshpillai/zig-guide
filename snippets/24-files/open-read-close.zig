//! title: Open, Read, Close
//! Three ways to read a file, and what each one does at its limit.

const std = @import("std");

const Io = std.Io;

// The playground starts each run in an empty directory. Thus the program
// writes the file before it reads the file. The file is 18 bytes: three
// lines of 6, 5 and 4 characters, and a newline after each line.
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

    // 1. Read the full file into memory from the allocator.
    try out.print("1. readFileAlloc\n", .{});
    const whole = try dir.readFileAlloc(io, "shopping.txt", gpa, .limited(1024));
    defer gpa.free(whole);
    try out.print("   read {d} bytes\n", .{whole.len});

    // The function fails when the file size is equal to the limit, and also
    // when the file size is more than the limit.
    for ([_]usize{ 17, 18, 19 }) |limit| {
        if (dir.readFileAlloc(io, "shopping.txt", gpa, .limited(limit))) |bytes| {
            defer gpa.free(bytes);
            try out.print("   limit {d}: ok, {d} bytes\n", .{ limit, bytes.len });
        } else |err| {
            try out.print("   limit {d}: {t}\n", .{ limit, err });
        }
    }

    // 2. Read into a buffer that you supply. No allocator is necessary. A full
    //    buffer does not tell you if the file is longer than the buffer.
    try out.print("2. readFile\n", .{});
    var small: [8]u8 = undefined;
    const part = try dir.readFile(io, "shopping.txt", &small);
    try out.print("   8-byte buffer: {d} bytes \"{f}\"\n", .{ part.len, std.zig.fmtString(part) });
    var large: [64]u8 = undefined;
    const all = try dir.readFile(io, "shopping.txt", &large);
    try out.print("   64-byte buffer: {d} bytes\n", .{all.len});

    // 3. Open a handle. You must close the handle. Get the length of the
    //    file, then read exactly that number of bytes from offset 0.
    try out.print("3. openFile\n", .{});
    {
        const file = try dir.openFile(io, "shopping.txt", .{});
        defer file.close(io);

        // A file length is a u64. A length in memory is a usize, and a usize
        // is 32 bits on wasm32. If the value is too large, the cast fails.
        // It does not remove the high bits.
        const len = try file.length(io);
        const bytes = try gpa.alloc(u8, std.math.cast(usize, len) orelse return error.FileTooBig);
        defer gpa.free(bytes);
        const n = try file.readPositionalAll(io, bytes, 0);
        try out.print("   length {d}, read {d}\n", .{ len, n });
        try out.print("   first line: {s}\n", .{bytes[0..std.mem.findScalar(u8, bytes, '\n').?]});
    }

    // 4. A file that does not exist. The error gives the name of the
    //    problem. Thus the caller can use a default value for this error.
    try out.print("4. missing file\n", .{});
    if (dir.openFile(io, "settings.txt", .{})) |file| {
        file.close(io);
    } else |err| switch (err) {
        error.FileNotFound => try out.print("   settings.txt: FileNotFound, using defaults\n", .{}),
        else => return err,
    }

    try dir.deleteFile(io, "shopping.txt");
}
