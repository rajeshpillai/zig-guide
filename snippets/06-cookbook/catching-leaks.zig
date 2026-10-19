//! title: Catch Memory Leaks
//! The testing allocator fails the test if memory is still allocated.

const std = @import("std");
const expect = std.testing.expect;

// A type that owns two allocations. At the second allocation, init can fail
// in the middle. There, it is easy to miss a leak.
const Buffers = struct {
    a: []u8,
    b: []u8,

    fn init(gpa: std.mem.Allocator, size: usize) !Buffers {
        const a = try gpa.alloc(u8, size);
        // If the second alloc fails, `a` is already allocated, and `a` leaks.
        // errdefer frees `a` on that path, and on no other path.
        errdefer gpa.free(a);
        const b = try gpa.alloc(u8, size);
        return .{ .a = a, .b = b };
    }

    fn deinit(self: Buffers, gpa: std.mem.Allocator) void {
        gpa.free(self.a);
        gpa.free(self.b);
    }
};

test "every alloc has a matching free" {
    const gpa = std.testing.allocator;
    const bufs = try Buffers.init(gpa, 64);
    // If you remove this deinit, the test fails. It gives a leak report and
    // the stack trace of the allocation that the code did not free.
    defer bufs.deinit(gpa);
    try expect(bufs.a.len == 64);
}

test "init that fails halfway leaks nothing" {
    // FailingAllocator succeeds `fail_index` times, then returns
    // error.OutOfMemory. A failure of the second alloc runs the errdefer.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        Buffers.init(failing.allocator(), 64),
    );
    // Then the testing allocator below it makes sure that no memory leaked.
}

test "an arena makes scoped cleanup trivial" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    // One deinit frees all of the allocations from the arena, in any order.
    // It also frees the allocations whose pointers you do not have now.
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var all: usize = 0;
    for (0..10) |i| {
        const chunk = try arena.alloc(u8, i + 1);
        all += chunk.len;
    }
    try expect(all == 55);
}
