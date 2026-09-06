# Allocators

> Explicit memory management, passed as a value.

Zig has no global allocator and no garbage collector. Anything that needs heap
memory takes an `std.mem.Allocator` parameter, which means you can always see,
from the signature alone, whether a function allocates.

```zig
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

test "create and destroy a single value" {
    const allocator = std.testing.allocator;

    // alloc/free is for slices; create/destroy is for one value.
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

    // The classic use: keep a copy of a string whose original may go away.
    const owned = try allocator.dupe(u8, "borrowed");
    defer allocator.free(owned);
    try expect(std.mem.eql(u8, owned, "borrowed"));
}

test "resize in place, or realloc to move" {
    const allocator = std.testing.allocator;

    var slice = try allocator.alloc(u8, 4);
    // realloc keeps the contents and may return a new pointer.
    slice = try allocator.realloc(slice, 8);
    defer allocator.free(slice);
    try expect(slice.len == 8);
}

test "SafeAllocator catches leaks in a real program" {
    // In a program you own the allocator; this is what std.testing.allocator
    // wraps for you. It has been renamed twice: GeneralPurposeAllocator, then
    // DebugAllocator, now SafeAllocator. It takes the allocator it draws pages
    // from, and `deinit` returns how many allocations were never freed.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(safe.deinit() == 0);
    const allocator = safe.allocator();

    const data = try allocator.alloc(u8, 16);
    allocator.free(data); // omit this and deinit reports .leak
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.allocators`)*

## Choosing an allocator

The `Allocator` interface is one type, but the strategy behind it is yours to
pick:

| Allocator | Frees when | Good for |
| --- | --- | --- |
| `ArenaAllocator` | `deinit()`, all at once | Request handlers, compilers, anything phase-shaped |
| `FixedBufferAllocator` | never (bump pointer) | Embedded, hot loops, no-heap contexts |
| `SafeAllocator` | per-`free`, with leak detection | Development builds |
| `std.testing.allocator` | per-`free`, fails the test on leak | Tests |

The arena is the one to reach for more often than you would think. Does your
program have a natural "do a unit of work, then throw everything away" shape?
Then an arena turns hundreds of `free` calls into a single `deinit`, and
removes a whole category of leak.

## `defer` is what makes this bearable

```zig
const numbers = try allocator.alloc(u32, 10);
defer allocator.free(numbers);
```

`defer` runs at scope exit, on every path, including early `return` and error
returns. Writing the `free` on the line directly *after* the `alloc` keeps the
pair visible in one glance, which is why Zig code reads the way it does.

Note the test above uses `std.testing.allocator`: if a test leaks, the test
fails. Leak checking is not an optional tool you remember to run, it is the
default in tests.

## The operations you reach for

| Call | Gives you | Pair with |
| --- | --- | --- |
| `alloc(T, n)` | a `[]T` of `n` items | `free` |
| `create(T)` | a `*T`, one value | `destroy` |
| `dupe(T, slice)` | an owned copy of `slice` | `free` |
| `realloc(slice, n)` | the slice resized, contents kept | `free` |

`create` and `destroy` are the single-value pair, for a linked-list node or a
struct that outlives its stack frame; `alloc`/`free` are for slices. `dupe` is
how you keep a string whose original is about to disappear, the fix for the
dangling-key problem the Hash Maps chapter warns about. `realloc` may return a
new pointer, so always reassign: `slice = try allocator.realloc(slice, n)`.

## `SafeAllocator` was `DebugAllocator` was `GeneralPurposeAllocator`

The leak-checking allocator has been renamed twice. If you arrived from an
older tutorial looking for `std.heap.GeneralPurposeAllocator`, it became
`std.heap.DebugAllocator`, and on current master it is
`std.heap.SafeAllocator`. Both older names still resolve.

The second rename changed the shape, not just the spelling:

```zig
// DebugAllocator: comptime config, backing allocator implied,
// deinit() returns .ok or .leak
var debug: std.heap.DebugAllocator(.{}) = .init;
defer std.debug.assert(debug.deinit() == .ok);
const allocator = debug.allocator();
```

```zig
// SafeAllocator: a plain struct, backing allocator passed in,
// deinit() returns how many allocations leaked
var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
defer std.debug.assert(safe.deinit() == 0);
const allocator = safe.allocator();
```

The word "safe" rather than "debug" is the claim being made. It panics on a
double free, on a free through the wrong allocator, and on most writes after
free, which is worth having outside a development build. You pay for it in
code size: swapping the five data-structure programs on this site over added
about 14 KB to each `.wasm`. When you do not want the bookkeeping, use
`std.heap.smp_allocator` or an arena.
