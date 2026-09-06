# Memory Is Numbered

> An address is an ordinary number, and a pointer is a variable holding one.

Memory is one long row of byte-sized boxes, and the boxes are numbered from
one end. The number of a box is its **address**. That is the entire concept.

Picture a street: every house has a number, the numbers run in order, and
knowing a number is enough to go and look. A house number is not a house. You
can write one on a scrap of paper and give it to someone else. They can go to
the same house and repaint the door. The paint ends up on the real house, not
on the paper.

That scrap of paper is a **pointer**. It is a variable whose value is an
address. Everything that sounds hard about pointers is either that sentence or
a consequence of it.

## The program

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var row = [_]u32{ 10, 20, 30, 40 };

    // @intFromPtr does no work. It shows the number the address already was.
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

    // A pointer holds one of those numbers and nothing else.
    const p: *u32 = &row[2];
    try out.print("a *u32 is {d} bytes wide\n", .{@sizeOf(*u32)});
    try out.print("this one holds {d}\n", .{@intFromPtr(p)});
    try out.print("reading through it gives {d}\n\n", .{p.*});

    // Writing through it writes that box in the row, not a copy of it.
    p.* = 99;
    try out.print("after p.* = 99, row[2] = {d}\n", .{row[2]});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.memory-is-numbered`)*

Your numbers will not match the ones described below, and they will change if
you Run it twice or open this page tomorrow. That is expected. Where a program
gets put in memory is decided when it is loaded, not when it is written. What
does not change is the **spacing**, and the spacing is what the page is about.

## What just happened

**Four `u32` values printed at offsets 0, 4, 8 and 12.** They are four bytes
apart because a `u32` is four bytes wide, and an array puts its elements
directly against each other with no gap. This is why `row[2]` can be found
without searching for it: the machine computes the address of `row[0]` plus
two times four, and goes straight there. That is the reason reading
`row[999999]` of an array costs the same as reading `row[0]`, which is not
true of every data structure you will meet.

**`@intFromPtr` did nothing.** It performs no work and produces no new
information. A pointer is already a number, and `@intFromPtr` is how you ask
Zig to let you look at it as one. Zig makes you ask because a number you can
do arithmetic on is a number you can do wrong arithmetic on.

**The pointer was 4 bytes wide.** That is because this page runs your program
as 32-bit WebAssembly, where 4 bytes is enough to number every box. Compile
the same file for your laptop and the same line prints 8. A pointer is exactly
as wide as it needs to be to hold an address on the machine it is running on,
and that is what "64-bit" describes.

**`p.* = 99` changed `row[2]`.** Not a copy of `row[2]`. The pointer held the
address of that specific box, so writing through it wrote that box, and the
array sees the change. This is the repainted door.

## Check yourself

If the array held `u8` values instead of `u32` values, what would the four
offsets be?

0, 1, 2 and 3. Each box now holds one byte, so the boxes sit one apart. The
addresses did not become smaller. The values did, so more of them fit in the
same stretch of street.

## If you have written C

Same concept, same layout, different notation. C writes the type as `int *p`
and reads through it with a prefix `*p`. Zig writes `*u32` and reads through
it with a postfix `.*`, so it reads left to right, like field access.

Two differences matter now. Zig's `*u32` can never be null, so there is no
such thing as forgetting to check. When a pointer might be absent, its type
says so and the compiler will not let you read it without unwrapping first.
Zig also does not let you do arithmetic on a `*u32`. Pointer arithmetic
without a length is how buffer overruns happen. Instead a pointer and a length
travel together, as a [slice](https://www.ziglang.in/learn/language-basics/slices/).

The language-level detail, including the null question and how constness
travels, is in [Pointers](https://www.ziglang.in/learn/language-basics/pointers/). This page was
about the street.

Next: [The Stack](https://www.ziglang.in/learn/systems-from-scratch/the-stack/), which is about who
decides the addresses and for how long.
