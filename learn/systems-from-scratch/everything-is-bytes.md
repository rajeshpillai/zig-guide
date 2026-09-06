# Everything Is Bytes

> A type is not a property of the bytes. It is an agreement about how to read them.

A computer stores one kind of thing: numbers between 0 and 255. One of those
numbers is a **byte**. There is no separate place where letters live, and no
separate place for decimals or dates or pictures. All of it is bytes.

So how does the machine know that one byte is the letter `A` and another is
the number 65?

It does not. They are the same byte. What differs is the **type**. A type is
an agreement about how to read a run of bytes: how many of them belong
together, and what the pattern means. The agreement lives in your program, not
in the memory. Change the agreement and the same bytes say something else.

That is the whole idea, and it carries further than it sounds. Almost
everything that feels mysterious later comes back to that one sentence. Why a
file and an image are the same thing to the operating system. Why a network
sends numbers and receives text.

## The program

Press **Run**. It executes in your browser, and it is the same file our build
compiled and ran before this page was published.

```zig
const std = @import("std");

const Point = struct { x: u8, y: u8 };

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // A letter is not a different kind of thing from a number. 'A' is 65,
    // written the way a person prefers to read it.
    const letter: u8 = 'A';
    try out.print("'A' is the number {d}\n\n", .{letter});

    // Every value can be asked how much room it takes.
    try out.print("a u8 takes {d} byte\n", .{@sizeOf(u8)});
    try out.print("a u32 takes {d} bytes\n", .{@sizeOf(u32)});
    try out.print("a Point takes {d} bytes\n\n", .{@sizeOf(Point)});

    // And it can be asked for the bytes themselves.
    const n: u32 = 1;
    try out.writeAll("the u32 1, byte by byte:");
    for (std.mem.asBytes(&n)) |byte| try out.print(" {d}", .{byte});
    try out.writeAll("\n\n");

    // Nothing here converts anything. The four bytes stay exactly as they
    // were; only the agreement about how to read them changes.
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

**`'A'` printed as 65.** Writing `'A'` in Zig does not make a letter. It is a
way of writing the number 65 that is easier for a person to read. The two are
interchangeable: `letter == 65` is true.

**`@sizeOf` reported how many bytes each type occupies.** A `u8` is one byte, a
`u32` is four, and the `Point` in the program is two because it holds two `u8`
fields side by side. `@sizeOf` is answering a physical question: if you asked
for a million of these, how much memory would you be asking for?

**The `u32` holding 1 printed as `1 0 0 0`.** Four bytes, and the useful one
came first. This machine stores the smallest place value at the lowest
address, which is called **little-endian**. It is a choice the hardware made,
not a rule of arithmetic. Most machines you will meet do it this way, and it
stops being surprising once you have seen it once. It matters in exactly two
places, both much later: reading a file someone else wrote, and sending bytes
over a network.

**The last pair is the point of the page.** `0x41424344` printed as the number
1094861636 and then as the letters `DCBA`. Nothing was converted between those
two lines. `@bitCast` copies no bytes and does no arithmetic. It says: stop
reading these four bytes as one `u32` and start reading them as four `u8`
values. The bytes never moved. Only the agreement changed.

(`0x41` is 65, so the first byte really is `A`. It reads backwards for the
little-endian reason above.)

## Check yourself

If `Point` held two `u32` fields instead of two `u8` fields, what would
`@sizeOf(Point)` print?

Eight. A struct is its fields laid out one after another, and its size is the
space they need. (It is not always exactly the sum, for reasons the [memory
layout](https://www.ziglang.in/learn/how-to/memory-layout/) recipe covers, but for a start it is a
good model.)

The **Edit** button opens the snippet so you can change it. Running edited
code needs a Zig compiler this deployment does not carry yet, so it will offer
to copy the source out to an external playground instead. Every unedited
snippet runs here.

## If you have written C

`@bitCast` is what a C programmer reaches for a union or a pointer cast to do:

```c
uint32_t n = 0x41424344;
char *letters = (char *)&n;      /* the same four bytes, read as chars */
```

The difference is that the C version goes through a pointer and will happily
let you read five bytes, or four bytes that were never there. `@bitCast`
checks at compile time that the source and destination are the same size, so
`@bitCast` from a `u32` to a `[5]u8` does not compile. You will see this shape
repeatedly: the same operation is available, and the mistake next to it is
not.

Next: [Numbers Have a Size](https://www.ziglang.in/learn/systems-from-scratch/numbers-have-a-size/),
which is the same question asked about arithmetic.
