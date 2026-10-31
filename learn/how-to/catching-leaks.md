# Recipe: Catch Memory Leaks

> Make the test suite prove that the code frees each allocation.

Zig tests find memory leaks when the tests allocate through `std.testing.allocator`. To find leaks on error paths, use `std.testing.FailingAllocator`. This allocator makes a selected allocation return `error.OutOfMemory`.

## The problem

With manual memory management, each `alloc` needs a `free` that matches it. The `free` must occur on each path, and also on the paths that occur only when a different operation fails.

A careful read of the code does not work when the code becomes large. You want the test suite to fail, with a stack trace, immediately when a path leaks memory.

If memory from `std.testing.allocator` is still allocated at the end of a test, the test **fails**. The allocator shows where the program allocated the memory that has no owner.

## The plan

1. Send all of the allocations in tests through `std.testing.allocator`.
2. Some `init` functions make more than one allocation. For each of these functions, test the failure in the middle with `std.testing.FailingAllocator`. This allocator succeeds N times. Then it returns `error.OutOfMemory` on purpose.
3. If many small allocations have the same lifetime, use an arena. Then the cleanup is one call, and not one `free` for each allocation.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.catching-leaks`)*

## The failure path is the path that leaks

Look at `Buffers.init`. The first `alloc` succeeds, and the second `alloc` can fail. On that path, the function returns an error, and the caller does not get the struct. Thus `a` has no owner.

The `errdefer gpa.free(a)` runs on that error return and on no other path.

The second test proves this. `FailingAllocator` with `fail_index = 1` lets the first allocation succeed and makes the second allocation fail. Thus `init` must take the error path. If you remove the `errdefer` line, this test fails with a leak report.

Copy this pattern. For each `init` that makes more than one allocation, write a test that makes each allocation fail, one after the other.

## Why this works in ReleaseFast too

Here, the allocator finds the leaks, not the build mode. `std.testing.allocator` is a `std.heap.SafeAllocator`. It keeps its own record of each live allocation, in all build modes of the tested code. Thus CI finds leaks, and you do not have to ship a debug build.

## Variations

- **Leak checks for the full program:** run the full program on a `std.heap.SafeAllocator`, and call `deinit` at exit. `deinit` returns the number of leaks and logs where the program allocated each leak. (Master does not have `GeneralPurposeAllocator` now, and `DebugAllocator` is deprecated. Use `SafeAllocator`.)
- **Failure injection for all allocations:** `std.testing.checkAllAllocationFailures` runs a function one time for each allocation that the function makes. Each time, it makes a different allocation fail. It does automatically the `fail_index` sweep that this recipe does by hand.
