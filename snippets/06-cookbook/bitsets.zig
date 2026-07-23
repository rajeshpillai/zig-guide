//! title: Set Operations on the Cheap
//! Membership of small integer sets as bits: no allocation, one-word math.

const std = @import("std");

const Hours = std.StaticBitSet(24);

fn setHours(set: *Hours, hours: []const u5) void {
    for (hours) |h| set.set(h);
}

fn printHours(out: *std.Io.Writer, label: []const u8, set: Hours) !void {
    try out.print("{s} ({d} free):", .{ label, set.count() });
    var it = set.iterator(.{});
    while (it.next()) |h| try out.print(" {d}", .{h});
    try out.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Two calendars, each a set of free hours in a day. 24 possible
    // members, so the whole set is one u24 under the hood; every
    // operation below is a bitwise instruction or two.
    var ana: Hours = .empty;
    var raj: Hours = .empty;
    setHours(&ana, &.{ 9, 10, 11, 14, 15, 16 });
    setHours(&raj, &.{ 10, 11, 13, 15, 19 });

    try printHours(out, "ana", ana);
    try printHours(out, "raj", raj);

    // Overlap: the hours where a meeting can happen.
    try printHours(out, "both free", ana.intersectWith(raj));

    // Union answers the opposite question.
    try printHours(out, "either free", ana.unionWith(raj));

    // Single-membership checks are one bit test.
    try out.print("raj free at 14: {}\n", .{raj.isSet(14)});

    try out.flush();
}
