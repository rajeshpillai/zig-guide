# Recipe: Catching Memory Leaks

> Make the test suite prove that every allocation is freed.

## The problem

Manual memory management means every `alloc` needs a matching `free`, on every
path, including the paths that only happen when something else fails. Reading
the code very carefully does not scale. You want the test suite to fail, with
a stack trace, the moment a path leaks.

Zig ships this. `std.testing.allocator` tracks every allocation made through
it, and a test that ends with anything still allocated **fails**, printing
where the orphaned memory was allocated.

## The plan

1. Route all allocation in tests through `std.testing.allocator`.
2. For any `init` that makes more than one allocation, cover the halfway
   failure with `std.testing.FailingAllocator`, which succeeds N times and
   then returns `error.OutOfMemory` on purpose.
3. Where many small allocations share one lifetime, use an arena so cleanup
   is a single call instead of a bookkeeping exercise.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.catching-leaks`)*

## The failure path is the one that leaks

Look at `Buffers.init`. The first `alloc` succeeds, the second may fail. On
that path the function returns an error, the caller never receives the struct,
and `a` would be orphaned. The `errdefer gpa.free(a)` runs exactly on that
error return and nowhere else.

The second test proves it. `FailingAllocator` with `fail_index = 1` lets the
first allocation through and fails the second, forcing `init` down the error
path. If you delete the `errdefer` line, this test fails with a leak report.
That is the pattern worth copying: every multi-allocation `init` deserves a
test that fails each allocation in turn.

## Why this works in ReleaseFast too

Leak detection here is a property of the allocator, not of a build mode. The
testing allocator wraps a debug allocator regardless of how the code under
test is compiled, so CI catches leaks without shipping a debug build.

## Variations

- **Whole-program leak checking:** `std.heap.GeneralPurposeAllocator` (the
  debug allocator) reports leaks from `deinit` at process exit; return code
  and stderr tell you what was left.
- **Exhaustive failure injection:** `std.testing.checkAllAllocationFailures`
  runs a function once per allocation it makes, failing a different one each
  time. It automates the `fail_index` sweep this recipe does by hand.
