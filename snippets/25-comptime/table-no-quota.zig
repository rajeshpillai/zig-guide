//! title: A Table Without a Branch Quota
//! compile-fails
//! The same CRC-32 table, without `@setEvalBranchQuota`.

const std = @import("std");

const table: [256]u32 = blk: {
    var t: [256]u32 = undefined;
    for (&t, 0..) |*entry, byte| {
        var c: u32 = @intCast(byte);
        for (0..8) |_| {
            c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        }
        entry.* = c;
    }
    break :blk t;
};

pub fn main() void {
    std.debug.print("0x{x}\n", .{table[1]});
}
