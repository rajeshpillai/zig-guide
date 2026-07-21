//! title: Readers and Writers
//! The 0.15 interfaces: buffered, non-generic, buffer owned by the caller.

const std = @import("std");
const expect = std.testing.expect;

test "iterate lines with takeDelimiter" {
    var reader: std.Io.Reader = .fixed("line one\nline two\n");

    // `takeDelimiter` consumes the delimiter and returns null at the end,
    // which is what you want for a line loop.
    var count: usize = 0;
    while (try reader.takeDelimiter('\n')) |line| {
        count += 1;
        try expect(line.len == 8);
    }
    try expect(count == 2);
}

test "the Exclusive variant leaves the delimiter behind" {
    var reader: std.Io.Reader = .fixed("line one\nline two\n");

    const first = try reader.takeDelimiterExclusive('\n');
    try expect(std.mem.eql(u8, first, "line one"));

    // The '\n' has NOT been consumed, so the next call sees it immediately
    // and returns an empty slice. Use `takeDelimiter` to loop over lines,
    // or `toss(1)` to step past the delimiter yourself.
    const second = try reader.takeDelimiterExclusive('\n');
    try expect(second.len == 0);

    reader.toss(1);
    const third = try reader.takeDelimiterExclusive('\n');
    try expect(std.mem.eql(u8, third, "line two"));
}

test "take a fixed number of bytes" {
    var reader: std.Io.Reader = .fixed("abcdef");
    const chunk = try reader.take(3);
    try expect(std.mem.eql(u8, chunk, "abc"));
}

test "write into a caller-owned buffer" {
    var buf: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writer.writeAll("hello");
    try writer.print(" {d}", .{42});

    try expect(std.mem.eql(u8, writer.buffered(), "hello 42"));
}

test "allocating writer grows as needed" {
    const gpa = std.testing.allocator;
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    for (0..5) |i| try writer.writer.print("{d},", .{i});
    try expect(std.mem.eql(u8, writer.written(), "0,1,2,3,4,"));
}

test "a fixed writer reports when it runs out" {
    var buf: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.WriteFailed, writer.writeAll("too long"));
}
