//! title: Allocators
//! Zig does not allocate memory secretly. You give an `Allocator` to the code.

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

    // It is not necessary to free each value. `deinit` frees all of them.
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

test "create and destroy a single value" {
    const allocator = std.testing.allocator;

    // Use alloc/free for slices. Use create/destroy for one value.
    const node = try allocator.create(Node);
    defer allocator.destroy(node);

    node.* = .{ .value = 42, .next = null };
    try expect(node.value == 42);
}

const Node = struct {
    value: u32,
    next: ?*Node,
};

test "dupe copies a slice into owned memory" {
    const allocator = std.testing.allocator;

    // A common use: keep a copy of a string when the original can disappear.
    const owned = try allocator.dupe(u8, "borrowed");
    defer allocator.free(owned);
    try expect(std.mem.eql(u8, owned, "borrowed"));
}

test "resize in place, or realloc to move" {
    const allocator = std.testing.allocator;

    var slice = try allocator.alloc(u8, 4);
    // realloc keeps the contents. It can return a new pointer.
    slice = try allocator.realloc(slice, 8);
    defer allocator.free(slice);
    try expect(slice.len == 8);
}

test "SafeAllocator catches leaks in a real program" {
    // In a program, you own the allocator. std.testing.allocator wraps this
    // allocator for you. The name changed two times: GeneralPurposeAllocator,
    // then DebugAllocator, and now SafeAllocator. The function `init` takes
    // the allocator that supplies the pages. `deinit` returns the number of
    // allocations that the program did not free.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(safe.deinit() == 0);
    const allocator = safe.allocator();

    const data = try allocator.alloc(u8, 16);
    allocator.free(data); // without this line, deinit returns 1
}
