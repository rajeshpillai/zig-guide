//! title: Build Lookup Tables
//! A CRC-32 table computed by the compiler, checked against std.

const std = @import("std");

// The reflected CRC-32 polynomial. Zip, PNG and Ethernet use it.
const poly: u32 = 0xEDB88320;

// One entry for each possible byte. Each entry is the result of eight
// shift-and-xor steps on that byte. The steps run during compilation, and
// the binary contains only the 256 results.
const table: [256]u32 = blk: {
    // 256 bytes times 8 steps is more than 1000 backward branches.
    @setEvalBranchQuota(256 * 8 + 256);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*entry, byte| {
        var c: u32 = @intCast(byte);
        for (0..8) |_| {
            c = if (c & 1 != 0) poly ^ (c >> 1) else c >> 1;
        }
        entry.* = c;
    }
    break :blk t;
};

// One table read for each byte of input, not eight steps.
fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

// A table can be a type check too. The compiler runs this block, and
// a false condition stops the build.
comptime {
    std.debug.assert(table[0] == 0);
    std.debug.assert(table[128] == poly);
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("table: {d} entries, {d} bytes\n", .{ table.len, @sizeOf(@TypeOf(table)) });
    for (table[0..4], 0..) |entry, i| {
        try out.print("  table[{d}] = 0x{x:0>8}\n", .{ i, entry });
    }

    const inputs = [_][]const u8{ "", "a", "hello, world", "The quick brown fox jumps over the lazy dog" };
    for (inputs) |input| {
        const ours = crc32(input);
        const theirs = std.hash.Crc32.hash(input);
        try out.print("\"{s}\"\n  ours 0x{x:0>8}, std 0x{x:0>8}, {s}\n", .{
            input,
            ours,
            theirs,
            if (ours == theirs) "same" else "DIFFERENT",
        });
    }

    // A table that the compiler made is also usable at compile time.
    const at_compile = comptime crc32("hello, world");
    try out.print("comptime crc32(\"hello, world\") = 0x{x:0>8}\n", .{at_compile});
}
