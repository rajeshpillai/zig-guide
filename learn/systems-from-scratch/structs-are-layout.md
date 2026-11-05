# Structs Are Layout

> Fields are next to each other in memory, and the size is not the sum of the parts.

When you put some values together under one name, you get a struct. In a
managed language, that is all. At the level of the machine, there is a second
part: the values must go to a place in memory, in some order. The machine has
a preference about the place.

The name of that preference is **alignment**. A processor reads memory in
blocks. If a four-byte number starts at an address that is divisible by four,
the processor can read the number in one operation. If the number goes across
the boundary, the processor needs two reads and some extra instructions. On
some processors, that read is not permitted. Thus the rule for a number is:
the number starts at an address that is divisible by its own size.

Apply that rule to a struct with fields of different sizes, and the result can
be a surprise: **the struct is larger than its fields**. The name of the gaps
that keep each field aligned is **padding**. You pay for the padding when you
know about it and when you do not.

## The program

```zig
const std = @import("std");

// `extern` gives the layout of C: the fields are in the order of the source.
// Padding makes each field start at an address that the machine prefers for
// its type. Learn this layout first, because other languages and file formats
// use it.
const Row = extern struct {
    flag: u8,
    count: u32,
    tag: u8,
};

// The same three fields, largest first.
const Packed = extern struct {
    count: u32,
    flag: u8,
    tag: u8,
};

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    try out.print("the fields hold {d} bytes of data\n", .{@sizeOf(u8) + @sizeOf(u32) + @sizeOf(u8)});
    try out.print("but @sizeOf(Row) = {d}\n\n", .{@sizeOf(Row)});

    // The start and the size of each field. The gaps are the padding.
    try out.print("flag  starts at byte {d}, size {d}\n", .{ @offsetOf(Row, "flag"), @sizeOf(u8) });
    try out.print("count starts at byte {d}, size {d}\n", .{ @offsetOf(Row, "count"), @sizeOf(u32) });
    try out.print("tag   starts at byte {d}, size {d}\n\n", .{ @offsetOf(Row, "tag"), @sizeOf(u8) });

    // Only the order of the fields changed.
    try out.print("same fields, largest first: {d} bytes\n", .{@sizeOf(Packed)});
    try out.print("count starts at byte {d}, size {d}\n", .{ @offsetOf(Packed, "count"), @sizeOf(u32) });
    try out.print("flag  starts at byte {d}, size {d}\n", .{ @offsetOf(Packed, "flag"), @sizeOf(u8) });
    try out.print("tag   starts at byte {d}, size {d}\n\n", .{ @offsetOf(Packed, "tag"), @sizeOf(u8) });

    // Without `extern`, Zig can put the fields in any order. Zig usually
    // selects the smaller layout.
    const Auto = struct { flag: u8, count: u32, tag: u8 };
    try out.print("Zig's own layout for them:  {d} bytes\n", .{@sizeOf(Auto)});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.structs-are-layout`)*

## What just happened

**Six bytes of data used twelve bytes.** The fields are `u8`, `u32` and `u8`.
The offsets show the reason: `flag` at 0, `count` at **4**, `tag` at 8.
`count` could not start at byte 1, because 1 is not divisible by 4. Thus
three bytes are not used.

Then the compiler adds padding at the end, and the struct becomes 12 bytes.
Thus in an array of these structs, each `count` is also aligned.

**The same fields, with the largest first, used eight bytes.** The struct lost
no fields. `count` is at 0, `flag` at 4, `tag` at 5, and two bytes of padding
are at the end.

The order of the fields decides the size. In C, you alone must get the order
correct. Four bytes on one struct are not important. Four bytes on ten million
rows are 40 MB.

The figure places the fields one at a time, at the offsets that the program
printed. Select an order to compare the two layouts at the same step.

*Figure: The struct with flag, count and tag in 12 bytes. In the declared order it uses 12 bytes with padding; largest first it uses 8. The offsets and sizes the program above prints. Select an order and step through the fields. The steps have the same names, thus you can switch at any step.*

**The layout that Zig selected also used eight bytes.** Here Zig is different
from C. A plain `struct` in Zig has **no guaranteed layout**. The compiler can
put the fields in any order, and it usually packs them for you. With `extern
struct`, you ask for the rules of C. Use `extern struct` when the layout must
agree with something outside your program: a C library, a file format, or a
network packet. Inside your own program, let the compiler decide.

## Check yourself

If you add a `u64` field to `Packed`, what will `@sizeOf` become?

16. The `u64` needs an address that is divisible by 8. `count` uses four
bytes, and `flag` and `tag` use two more, thus 6 bytes are already used. Thus
the `u64` starts at 8 and ends at 16. The alignment of the struct also becomes
8, because a struct takes the alignment of its field with the largest
alignment. This rule makes arrays of the struct work. One 8-byte field added
to an 8-byte struct cost 8 bytes. This result is the usual case, not a
surprise.

## If you know C

The rules, the padding and the arithmetic are the same. The two languages have
two differences.

First, C guarantees the order of the declarations. Thus you can find the
layout of a struct from its source, and you can trust that layout. Zig gives
that guarantee only for `extern struct` and `packed struct`. For a plain
struct, the compiler decides.

This default is better, because most structs never go outside your program.
When the compiler packs them, you get better performance at no cost. The
default is wrong in exactly one place: at a boundary with C, if you assume the
C layout. Use `extern struct` there, and the two languages agree.

Second, C gives you `offsetof` from `<stddef.h>`. In Zig, `@offsetOf` is a
builtin, and it needs no include. The program above used `@offsetOf` to show
the gaps. Thus you do not have to trust a statement about them.

The [memory layout](https://www.ziglang.in/learn/how-to/memory-layout/) recipe tells about the other
layout controls: `align`, `packed struct` for bit fields, and the C ABI in
detail.

Next: [Errors Are Values](https://www.ziglang.in/learn/systems-from-scratch/errors-are-values/).
That chapter is about what a function returns when it cannot do the work that
you asked for.
