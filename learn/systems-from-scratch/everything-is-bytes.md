# Everything Is Bytes

> A type is not a property of the bytes. A type is an agreement about how to read the bytes.

A computer stores one kind of thing: numbers from 0 to 255. One of these
numbers is a **byte**. Letters do not have a separate place in memory.
Decimals, dates and pictures do not have a separate place either. All of them
are bytes.

Then how does the machine know that one byte is the letter `A` and another
byte is the number 65?

The machine does not know. The two are the same byte. The difference is the
**type**. A type is an agreement about how to read a sequence of bytes: how
many bytes go together, and what the pattern means. The agreement is in your
program, not in the memory. If you change the agreement, the same bytes have a
different meaning.

Many things that look strange later have this cause. For example, the
operating system sees a file and an image as the same thing. Also, a network
can send numbers and receive text.

## The program

Press **Run**. The program runs in your browser. The build for this site
compiled and ran the same file before this page went on the site.

```zig
const std = @import("std");

const Point = struct { x: u8, y: u8 };

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // A letter is a number. 'A' is 65, in a form that a person can read
    // more easily.
    const letter: u8 = 'A';
    try out.print("'A' is the number {d}\n\n", .{letter});

    // @sizeOf gives the space that each type uses.
    try out.print("a u8 takes {d} byte\n", .{@sizeOf(u8)});
    try out.print("a u32 takes {d} bytes\n", .{@sizeOf(u32)});
    try out.print("a Point takes {d} bytes\n\n", .{@sizeOf(Point)});

    // std.mem.asBytes gives the bytes of the value.
    const n: u32 = 1;
    try out.writeAll("the u32 1, byte by byte:");
    for (std.mem.asBytes(&n)) |byte| try out.print(" {d}", .{byte});
    try out.writeAll("\n\n");

    // No conversion occurs here. The four bytes do not change. Only the
    // rule for how to read the bytes changes.
    const number: u32 = 0x41424344;
    const letters: [4]u8 = @bitCast(number);
    try out.print("read as a number: {d}\n", .{number});
    try out.writeAll("read as letters:  ");
    for (letters) |c| try out.print("{c}", .{c});
    try out.writeAll("\n");

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.everything-is-bytes`)*

## What just happened

**`'A'` printed as 65.** In Zig, `'A'` does not make a letter. `'A'` is a
different way to write the number 65, and a person can read it more easily.
You can use one in place of the other: `letter == 65` is true.

**`@sizeOf` gave the number of bytes that each type uses.** A `u8` is one
byte, and a `u32` is four bytes. The `Point` in the program is two bytes,
because it holds two `u8` fields next to each other. `@sizeOf` answers a
physical question: if you ask for a million of these values, how much memory
do you ask for?

**The `u32` that holds 1 printed as `1 0 0 0`.** The value has four bytes, and
the useful byte is first. This machine stores the smallest place value at the
lowest address. The name of this order is **little-endian**. The hardware
selected this order, and arithmetic does not need it. Most machines that you
will use have the same order.

The byte order is important in exactly two places, and you will see both much
later:

- when you read a file that a different program wrote
- when you send bytes across a network

**The last pair shows the same bytes read in two ways.** `0x41424344` printed
as the number 1094861636, and then as the letters `DCBA`. No conversion
occurred between those two lines. `@bitCast` copies no bytes and does no
arithmetic.

`@bitCast` tells the compiler: read the four bytes as four `u8` values, not as
one `u32`. The bytes did not move. Only the agreement changed.

(`0x41` is 65, the number for `A`. In memory, the first byte is `0x44`, the
number for `D`, because of the little-endian order above. Thus the letters
print in the reverse order.)

The figure shows the four bytes from the program, and reads them once as a
`u32` and once as four `u8` values.

*Figure: Four bytes in memory, 68, 67, 66, 65, read once as the u32 1094861636 and once as the letters DCBA. The bytes from the program above. The same four bytes give a number or four letters, and only the type decides which.*

## Check yourself

If `Point` held two `u32` fields instead of two `u8` fields, what would
`@sizeOf(Point)` print?

Eight. A struct is its fields, one after the other, and its size is the space
that the fields need. The size is not always exactly the sum. The [memory
layout](https://www.ziglang.in/learn/how-to/memory-layout/) recipe gives the reasons. But at the
start, the sum is a good model.

## If you know C

In C, a programmer uses a union or a pointer cast to do the work of
`@bitCast`:

```c
uint32_t n = 0x41424344;
char *letters = (char *)&n;      /* the same four bytes, read as chars */
```

The C version uses a pointer. The C version lets you read five bytes, or read
four bytes that do not exist. `@bitCast` makes sure at compile time that the
source and the destination have the same size. Thus a `@bitCast` from a `u32`
to a `[5]u8` does not compile.

You will see this pattern frequently. Zig lets you do the same operation, but
Zig stops the mistake that usually comes with the operation.

Next: [Numbers Have a Size](https://www.ziglang.in/learn/systems-from-scratch/numbers-have-a-size/),
which asks the same question about arithmetic.
