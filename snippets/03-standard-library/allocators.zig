//! title: Allocators
//! Zig never allocates behind your back; you pass an `Allocator` explicitly.

const std = @import("std");
const expect = std.testing.expect;

test "allocate a slice" {
    const allocator = std.testing.allocator;

    const numbers = try allocator.alloc(u32, 10);
    defer allocator.free(numbers);

    for (numbers, 0..) |*n, i| n.* = @intCast(i * i);
    try expect(numbers[9] == 81);
}

test "arena frees everything at once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // No individual `free` needed; `deinit` reclaims it all.
    for (0..100) |_| _ = try allocator.alloc(u8, 64);
}

test "fixed buffer needs no heap at all" {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const slice = try allocator.alloc(u8, 100);
    try expect(slice.len == 100);
    try expect(allocator.alloc(u8, 1000) == error.OutOfMemory);
}
