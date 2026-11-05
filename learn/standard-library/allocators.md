# Allocators

> Explicit memory management, with the allocator given as a value.

Zig has no global allocator and no garbage collector. All code that needs heap memory takes an `std.mem.Allocator` parameter. Thus the signature of a function always shows if the function allocates.

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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.allocators`)*

## Select an allocator

The `Allocator` interface is one type, but you select the strategy behind the interface:

| Allocator | Frees memory | Use for |
| --- | --- | --- |
| `ArenaAllocator` | at `deinit()`, all at the same time | Request handlers, compilers, all work that occurs in phases |
| `FixedBufferAllocator` | never (bump pointer) | Embedded code, hot loops, code that has no heap |
| `SafeAllocator` | at each `free`, with leak detection | Development builds |
| `std.testing.allocator` | at each `free`, and the test fails on a leak | Tests |

The arena is correct for more programs than most people expect. Some programs do one unit of work and then discard all of the memory. For such a program, an arena changes hundreds of `free` calls into one `deinit`. An arena also removes a full category of leak.

## `defer` makes this easy to manage

```zig
const numbers = try allocator.alloc(u32, 10);
defer allocator.free(numbers);
```

`defer` runs when the scope ends. It runs on all paths, and an early `return` and an error return are two of these paths. In Zig code, the `free` is on the line directly *after* the `alloc`. Thus you see the two calls together.

The test above uses `std.testing.allocator`. If a test leaks memory, the test fails. Tests check for leaks by default. You do not have to remember to run a separate tool.

## The usual operations

| Call | Gives you | Use with |
| --- | --- | --- |
| `alloc(T, n)` | a `[]T` of `n` items | `free` |
| `create(T)` | a `*T`, one value | `destroy` |
| `dupe(T, slice)` | an owned copy of `slice` | `free` |
| `realloc(slice, n)` | the slice with a new size, contents kept | `free` |

Each pair has a different use:

- Use `create` and `destroy` for one value. Examples are a node in a linked list, and a struct that must live longer than its stack frame.
- Use `alloc` and `free` for slices.
- Use `dupe` to keep a string when the original string will soon disappear. This is the fix for the dangling key that the Hash Maps chapter tells you about.

`realloc` can return a new pointer. Thus always assign the result again: `slice = try allocator.realloc(slice, n)`.

## `SafeAllocator` has two older names

The name of the allocator that checks for leaks changed two times. An older tutorial can use `std.heap.GeneralPurposeAllocator`. That name changed to `std.heap.DebugAllocator`, and on current master the name is `std.heap.SafeAllocator`. The two older names still resolve.

The second change also changed the shape of the type, not only its name:

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

The new name says "safe" and not "debug", because the checks are also useful outside a development build. The allocator panics in these conditions:

- a double free
- a free through the wrong allocator
- most writes after a free

The cost is code size. On this site, five programs about data structures changed to `SafeAllocator`, and each `.wasm` became about 14 KB larger. If you do not want this bookkeeping, use `std.heap.smp_allocator` or an arena.
