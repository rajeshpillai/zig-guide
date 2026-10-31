# Memory Is Numbered

> An address is an ordinary number, and a pointer is a variable that holds an address.

Memory is one long row of boxes, and each box holds one byte. The boxes have
numbers, in order from one end. The number of a box is its **address**.

Think of a street. Each house has a number, and the numbers are in order. If
you know the number, you can go to the house.

A house number is not a house. You can write a house number on a piece of
paper, and give the paper to a different person. That person can go to the
same house and paint the door. The paint goes on the real house, not on the
paper.

The piece of paper is a **pointer**. A pointer is a variable, and its value is
an address. All the other facts about pointers come from this fact.

## The program

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var row = [_]u32{ 10, 20, 30, 40 };

    // @intFromPtr does no work. It shows the address as the number that it is.
    const first = @intFromPtr(&row[0]);
    try out.print("row[0] sits at address {d}\n\n", .{first});

    for (&row, 0..) |*slot, i| {
        const here = @intFromPtr(slot);
        try out.print(
            "row[{d}] = {d}, {d} bytes along from row[0]\n",
            .{ i, slot.*, here - first },
        );
    }
    try out.print("\n@sizeOf(u32) = {d}\n\n", .{@sizeOf(u32)});

    // A pointer holds one of these numbers and nothing else.
    const p: *u32 = &row[2];
    try out.print("a *u32 is {d} bytes wide\n", .{@sizeOf(*u32)});
    try out.print("this one holds {d}\n", .{@intFromPtr(p)});
    try out.print("reading through it gives {d}\n\n", .{p.*});

    // A write through the pointer changes that box in the row, not a copy.
    p.* = 99;
    try out.print("after p.* = 99, row[2] = {d}\n", .{row[2]});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.memory-is-numbered`)*

Your numbers will not be the same as the numbers below. They also change if
you press Run two times, or if you open this page tomorrow. This is correct.
The loader decides the position of a program in memory when the program loads,
not when you write the program. The **spacing** between the addresses does not
change.

## What just happened

**Four `u32` values printed at offsets 0, 4, 8 and 12.** The values are four
bytes apart, because a `u32` is four bytes wide. An array puts its elements
directly next to each other, with no gap. Thus the machine does not search for
`row[2]`. The machine calculates the address of `row[0]` plus two times four,
and goes directly to that address.

To find element 999,999 of a large array, the machine does the same arithmetic
as for element 0. Not all data structures have this property.

**`@intFromPtr` did nothing.** `@intFromPtr` does no work and makes no new
information. A pointer is already a number. With `@intFromPtr`, you tell Zig
that you want to see the pointer as a number. Zig makes you ask, because when
you can do arithmetic on an address, you can also make a mistake in that
arithmetic.

**The pointer was 4 bytes wide.** This page runs your program as 32-bit
WebAssembly. On that target, 4 bytes are sufficient to give a number to each
box. If you compile the same file for your laptop, the same line prints 8. A
pointer is exactly as wide as an address on the machine that runs the
program. The term "64-bit" describes this width.

**`p.* = 99` changed `row[2]`, not a copy of `row[2]`.** The pointer held the
address of that box. Thus a write through the pointer wrote to that box, and
the array shows the change. This write is the door that the other person
painted.

## Check yourself

If the array held `u8` values instead of `u32` values, what would the four
offsets be?

The offsets would be 0, 1, 2 and 3. Each box now holds one byte, thus the
boxes are one address apart. The addresses did not become smaller. The boxes
became smaller, thus more boxes fit into the same length of street.

## If you know C

The concept and the layout are the same, but the notation is different. C
writes the type as `int *p`, and reads through the pointer with a prefix `*p`.
Zig writes `*u32`, and reads through the pointer with a postfix `.*`. Thus Zig
code reads from left to right, as a field access does.

Two differences are important now:

- A Zig `*u32` can never be null. Thus you cannot forget a null check. When a
  pointer can be absent, its type says so. The compiler does not let you read
  the pointer before you unwrap it.
- Zig does not let you do arithmetic on a `*u32`. Pointer arithmetic without
  a length causes buffer overruns. In Zig, a pointer and a length go
  together, as a [slice](https://www.ziglang.in/learn/language-basics/slices/).

[Pointers](https://www.ziglang.in/learn/language-basics/pointers/) gives the details at the level of
the language, which include the null question and the rules for constness.

Next: [The Stack](https://www.ziglang.in/learn/systems-from-scratch/the-stack/). That chapter tells
who decides the addresses, and for how long the addresses stay valid.
