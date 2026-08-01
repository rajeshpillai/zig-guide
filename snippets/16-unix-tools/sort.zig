//! title: sort
//! Sorting lines is easy. Owning them is the part that costs you something.

const std = @import("std");

/// Sort the lines of `text`, returning slices that point back into `text`.
/// Nothing is copied, so the result is only valid while `text` is, and the
/// caller frees exactly one thing: the list of pointers.
fn sortLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);

    var reader: std.Io.Reader = .fixed(text);
    while (try reader.takeDelimiter('\n')) |line| {
        try lines.append(allocator, line);
    }

    const slice = try lines.toOwnedSlice(allocator);
    std.mem.sort([]const u8, slice, {}, lessThan);
    return slice;
}

/// Byte order, which is what `sort` does by default and why "Zebra" comes
/// before "apple": upper case is 65..90 and lower case is 97..122.
fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // A fixed buffer, so this program never touches the heap. The arena the
    // C version carves by hand is this, with the bookkeeping already written.
    var storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);

    const text =
        \\banana
        \\Zebra
        \\apple
        \\cherry
        \\apple
        \\
    ;

    const sorted = try sortLines(fba.allocator(), text);
    defer fba.allocator().free(sorted);

    for (sorted) |line| try out.print("{s}\n", .{line});

    try out.print("\n{d} lines, {d} bytes of pointers, 0 bytes of copied text\n", .{
        sorted.len,
        sorted.len * @sizeOf([]const u8),
    });
    try out.flush();
}
