# Stacks

> ArrayList from one end, or no allocator at all.

In Zig, push and pop are `append(gpa, x)` and `pop()` on a `std.ArrayList`. `pop()` returns `null` when the list is empty. When you know the maximum depth, a fixed array and a length index make a stack with no allocator.

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
    // When you know the maximum, a fixed buffer does not use the heap.
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

Zig has no special `Stack` type, because it does not need one. An `ArrayList` that you use from the end is a stack:

| Operation | Call |
| --- | --- |
| push | `append(gpa, x)` |
| pop | `pop()` (returns `?T`) |
| peek | `last()` (returns `?T`) |
| size | `items.len` |

`pop()` and `last()` both return an optional. Thus the type handles the empty case. You do not have to remember a precondition.

In older tutorials, peek was `getLast()`, and it returned a `T`. It asserted that the list was not empty. Thus a call on an empty list was a safety-checked panic in a debug build, and undefined behaviour in a release build.

That function still exists. It is deprecated, and it still asserts. `last()` is the replacement. It returns `?T`, and thus the empty case is in the type.

`getLastOrNull()` is a deprecated alias for `last()`. There is also `lastPtr()`, which returns `?*T`. Use `lastPtr()` when you want to change the top element in place and not copy it.

The stack is cheap because it uses the end of the list, not the front. A removal from the end decrements the length one time. A removal from the front moves each of the other elements. For this reason, an array is a good fit for a stack, but not for a queue.

## When the depth has a limit

If you know the maximum, do not use an allocator. A fixed array and a length index are a complete stack that cannot fail. This is important for embedded targets and hot paths, and in Zig it is ordinary code.

```zig
var buf: [64]Frame = undefined;
var top: usize = 0;

buf[top] = frame; top += 1;   // push
top -= 1; const f = buf[top]; // pop
```

With no allocator, push needs no `try`, and this changes the shape of the code that uses the stack. A parser with a limit on the depth of nested brackets has no error path for "no more stack". It has only a check against the limit.

Write that check. With the check, the parser rejects input with too many levels. Without the check, the program crashes.

## Where to use a stack

Use a stack in almost all cases where the code must remember a point to return to:

- **Brackets that match**, in a parser or a linter. Push on an open bracket, pop on a close bracket, and compare.
- **Depth-first traversal** of a tree or a graph. Write it as a loop, so that deep input cannot overflow the stack of the machine.
- **Undo history**, where the code reverses the most recent action first.
- **An evaluator** for postfix expressions, which is exactly a stack machine.

The [tiny language](https://www.ziglang.in/learn/tiny-lang/) track uses the second and fourth items of this list. It uses them to replace recursion with an explicit stack.

## Why not a linked list

A stack on a linked list allocates for each element, and puts the elements at many different places in memory. An `ArrayList` amortises to one allocation and keeps all the elements next to each other. This is faster for almost all real workloads. Use a linked list only when you need stable addresses or O(1) splicing.

The difference is more than a small constant factor. A pop from an array reads memory that the CPU already loaded. A pop from a linked list follows a pointer to memory that is not in the cache, and the CPU waits.

Textbooks show the two stacks as equal, because they compare instruction counts. Instruction counts decided performance until decades ago. Today they do not.

There is one real exception. If other code holds pointers to the elements, you cannot use an array, because when the array grows, all the elements move. In that case, the extra allocations give you a benefit.
