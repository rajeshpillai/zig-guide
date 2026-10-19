//! title: Set Operations on the Cheap
//! Keep sets of small integers as bits: no allocation, and math on one word.

const std = @import("std");

const Hours = std.bit_set.Static(24);

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

    // Two calendars. Each calendar is a set of free hours in a day. A set
    // has 24 possible members, thus one u24 keeps the full set. Each
    // operation below is one or two bitwise instructions.
    var ana: Hours = .empty;
    var raj: Hours = .empty;
    setHours(&ana, &.{ 9, 10, 11, 14, 15, 16 });
    setHours(&raj, &.{ 10, 11, 13, 15, 19 });

    try printHours(out, "ana", ana);
    try printHours(out, "raj", raj);

    // Intersection: the hours when a meeting can occur.
    try printHours(out, "both free", ana.intersectWith(raj));

    // Union gives the hours when one or both people are free.
    try printHours(out, "either free", ana.unionWith(raj));

    // A check for one member is one bit test.
    try out.print("raj free at 14: {}\n", .{raj.isSet(14)});

    try out.flush();
}
