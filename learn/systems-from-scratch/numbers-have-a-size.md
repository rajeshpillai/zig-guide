# Numbers Have a Size

> A u8 counts to 255 and stops. You decide what happens next.

In Python or JavaScript, a number is only a number. You add one to the number
and you get one more. You can do that again and again, with no limit.

At the level of the machine, a number is a fixed number of bytes. A fixed
number of bytes can hold only a fixed number of different patterns. One byte
has 256 patterns. No person selected this limit. The limit comes from a simple
count: eight switches have 256 possible settings, and no 257th setting.

Thus a `u8` counts from 0 to 255. What occurs after 255?

A language can do one of three things, and many well-known bugs come from the
difference between them:

- The value wraps to 0.
- The program stops.
- The operation reports that the result did not fit, and lets you decide.

Zig makes you write which one you want.

## The program

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // The name gives the size. A u8 is an unsigned 8-bit integer. Thus a u8
    // can hold 256 patterns and no more.
    try out.print("u8  counts {d} to {d}\n", .{ std.math.minInt(u8), std.math.maxInt(u8) });
    try out.print("i8  counts {d} to {d}\n", .{ std.math.minInt(i8), std.math.maxInt(i8) });
    try out.print("u32 counts {d} to {d}\n\n", .{ std.math.minInt(u32), std.math.maxInt(u32) });

    const top: u8 = 255;

    // One way past the top: use a different operator that wraps. The answer
    // is 0, and 0 is the answer that you asked for.
    try out.print("255 +% 1 = {d}\n", .{top +% 1});

    // A second way: ask for an answer that can be absent. Then handle the
    // case where the answer is absent.
    if (std.math.add(u8, top, 1)) |sum| {
        try out.print("255 + 1 = {d}\n\n", .{sum});
    } else |err| {
        try out.print("255 + 1 = {t}\n\n", .{err});
    }

    // The size that you select decides the memory for a million values.
    try out.print("a million u8  = {d} bytes\n", .{1_000_000 * @sizeOf(u8)});
    try out.print("a million u32 = {d} bytes\n", .{1_000_000 * @sizeOf(u32)});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.numbers-have-a-size`)*

## What just happened

**The names describe the storage.** `u8` is an **u**nsigned **8**-bit
integer: eight switches, no sign, thus 0 to 255. `i8` has the same eight
switches, but it uses one pattern for the sign. Thus `i8` goes up only to 127,
but it goes down to -128. `u32` has thirty-two switches, thus it counts past
four billion.

After you see a few of these names, you can read the range directly from the
name. Zig also has `u1` to `u65535`, if you need an unusual size.

**`255 +% 1` gave 0.** The value wrapped. This result is not a bug, because
`+%` is a different operator from `+`. With the `%`, you tell the compiler: "I
know that this can overflow, and I want the value to wrap". Hash functions and
checksums need exactly this behaviour.

**`std.math.add` returned `Overflow` instead of a number.** The return type of
`std.math.add` says that the answer can be absent. Thus the program must
handle both cases before it can use the result. You cannot read a sum by
accident when the sum does not exist.

## Check yourself

The program does not use a plain `+` on `top`. What would occur if it did?

The result would not be 0, and it would not be 256. `top` is a `const` with a
known value. Thus the compiler can do the addition, see that 256 does not fit
in a `u8`, and reject the program. You get a compile error, and the program
does not run.

Sometimes the numbers are known only when the program runs. Then the compiler
cannot decide before the program runs. The compiler adds a check that runs
with the program.

Some builds keep these checks. In those builds, an overflow stops the program
with a message that gives the line. [A different
chapter](https://www.ziglang.in/learn/systems-from-scratch/when-checks-are-off/) tells which builds
keep the checks. In short, the builds that you use during development keep
them.

## If you know C

This difference in behaviour between the two languages is large. Because of
this difference, this material is easier to learn in Zig.

```c
unsigned char x = 255;
x = x + 1;        /* x is now 0. No warning, no error, nothing. */

int y = 2147483647;
y = y + 1;        /* undefined behaviour: the compiler may assume it cannot happen */
```

The first line wraps, and gives no message. The second line is more dangerous.
In C, signed overflow is undefined behaviour. Thus an optimiser can assume
that signed overflow never occurs, and it can delete the check that you wrote
for it. A beginner can spend days on a bug like this, and many beginners
decide that they are bad programmers.

The C behaviours have these equivalents in Zig:

- The silent wrap of C is `+%` in Zig, and you must type the `%`.
- The undefined behaviour of C is a crash that you can see, in Debug and
  ReleaseSafe builds.

[Integer Rules](https://www.ziglang.in/learn/language-basics/integer-rules/) gives the full rules,
and what changes in a release build.

Next: [Memory Is Numbered](https://www.ziglang.in/learn/systems-from-scratch/memory-is-numbered/).
In that chapter, each value gets an address.
