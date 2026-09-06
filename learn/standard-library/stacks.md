# Stacks

> ArrayList from one end, or no allocator at all.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "ArrayList is the stack you want" {
    const gpa = std.testing.allocator;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);

    try stack.append(gpa, 1);
    try stack.append(gpa, 2);
    try stack.append(gpa, 3);

    try expect(stack.pop().? == 3);
    try expect(stack.last().? == 2);
    try expect(stack.items.len == 2);
}

test "last is null on an empty stack, not a panic" {
    const gpa = std.testing.allocator;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);

    try expect(stack.last() == null);
    try stack.append(gpa, 7);
    try expect(stack.last().? == 7);
}

test "pop returns null when empty" {
    const gpa = std.testing.allocator;
    var stack: std.ArrayList(u8) = .empty;
    defer stack.deinit(gpa);

    try expect(stack.pop() == null);
}

test "a bounded stack needs no allocator at all" {
    // For a known maximum, a fixed buffer avoids the heap entirely.
    var buffer: [8]u32 = undefined;
    var len: usize = 0;

    for ([_]u32{ 10, 20, 30 }) |v| {
        buffer[len] = v;
        len += 1;
    }
    len -= 1;
    try expect(buffer[len] == 30);
}

test "balanced bracket check" {
    const gpa = std.testing.allocator;
    var stack: std.ArrayList(u8) = .empty;
    defer stack.deinit(gpa);

    const input = "([]{})";
    var balanced = true;
    for (input) |c| switch (c) {
        '(', '[', '{' => try stack.append(gpa, c),
        ')' => balanced = balanced and stack.pop() == '(',
        ']' => balanced = balanced and stack.pop() == '[',
        '}' => balanced = balanced and stack.pop() == '{',
        else => {},
    };
    try expect(balanced and stack.items.len == 0);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.stacks`)*

Zig has no dedicated `Stack` type because it does not need one. An `ArrayList`
used from the end is a stack:

| Operation | Call |
| --- | --- |
| push | `append(gpa, x)` |
| pop | `pop()` (returns `?T`) |
| peek | `last()` (returns `?T`) |
| size | `items.len` |

Both `pop()` and `last()` return an optional, so the empty case is handled by
the type rather than by a precondition you might forget.

If you learned this from an older tutorial, peek was `getLast()`, and it
returned a `T`. It asserted the list was not empty, so calling it on an empty
list was a safety-checked panic in a debug build and undefined behaviour in a
release one. That name is gone. `last()` replaces it and returns `?T`, which
moves the empty case into the type. `getLastOrNull()` still compiles as a
deprecated alias for `last()`. There is also `lastPtr()`, which returns
`?*T` when you want to modify the top element in place rather than copy it.

Using the end rather than the front is what makes it cheap. Removing from the
back is one decrement of the length; removing from the front would shift every
remaining element. That is the entire reason a stack is a natural fit for an
array and a queue is not.

## When the depth is bounded

If you know the maximum, skip the allocator entirely: a fixed array plus a
length index is a complete stack with no failure mode. This matters for
embedded targets and hot paths, and it is the sort of thing Zig makes
comfortable rather than exotic.

```zig
var buf: [64]Frame = undefined;
var top: usize = 0;

buf[top] = frame; top += 1;   // push
top -= 1; const f = buf[top]; // pop
```

No allocator means no `try` on push, which changes the shape of the code that
uses it. A parser with a bounded nesting depth has no error path for "ran out
of stack", only a check against the limit. That check is the thing to write,
and it is the difference between rejecting deeply nested input and crashing on
it.

## Where you will actually want one

Almost every case where you need to remember what to come back to.

- **Matching brackets**, in a parser or a linter. Push on open, pop on close,
  compare.
- **Depth-first traversal** of a tree or a graph, written iteratively so it
  cannot overflow the machine's own stack on deep input.
- **Undo history**, where the most recent action is the first to reverse.
- **An evaluator** for postfix expressions, which is exactly a stack machine.

The [tiny language](https://www.ziglang.in/learn/tiny-lang/) track uses the second and fourth of
those, and the recursion-versus-explicit-stack trade is the reason.

## Why not a linked list

A linked-list stack allocates per element and scatters them across memory.
`ArrayList` amortises to one allocation and keeps everything contiguous, which
is faster for essentially every real workload. Reach for a linked list only
when you need stable addresses or O(1) splicing.

"Faster" here is not a small constant factor. A pop from an array reads memory
the CPU has already fetched; a pop from a linked list follows a pointer to
somewhere the cache knows nothing about, and waits. Textbooks present the two
as equivalent because they compare instruction counts, which stopped being the
thing that decides performance decades ago.

The exception is real: if something else holds pointers to the elements, an
array cannot be used, because growing it moves everything. That is the case
where the extra allocation gives you something.
