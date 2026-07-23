//! title: Catching Memory Leaks
//! The testing allocator fails the test if anything is still allocated.

const std = @import("std");
const expect = std.testing.expect;

// A type that owns two allocations. The second one is where init can fail
// halfway, and where leaks hide.
const Buffers = struct {
    a: []u8,
    b: []u8,

    fn init(gpa: std.mem.Allocator, size: usize) !Buffers {
        const a = try gpa.alloc(u8, size);
        // If the second alloc fails, `a` is already live and about to be
        // orphaned. errdefer frees it on that path and only that path.
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
    // Remove this deinit and the test fails with a leak report and the
    // stack trace of the allocation that was never freed.
    defer bufs.deinit(gpa);
    try expect(bufs.a.len == 64);
}

test "init that fails halfway leaks nothing" {
    // FailingAllocator succeeds `fail_index` times, then returns
    // error.OutOfMemory. Failing the second alloc exercises the errdefer.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        Buffers.init(failing.allocator(), 64),
    );
    // The testing allocator behind it now verifies nothing was orphaned.
}

test "an arena makes scoped cleanup trivial" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    // One deinit frees every allocation made through the arena, in any
    // order, including ones whose pointers you no longer hold.
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var all: usize = 0;
    for (0..10) |i| {
        const chunk = try arena.alloc(u8, i + 1);
        all += chunk.len;
    }
    try expect(all == 55);
}
