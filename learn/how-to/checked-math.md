# Recipe: Overflow Without Panics

> Do arithmetic on values that can be too large, without undefined behavior and without a crash.

In safe builds, a plain `+` in Zig panics on overflow. To handle the overflow, select one of four explicit forms:

- `std.math.add` returns `error.Overflow`.
- `+|` saturates.
- `+%` wraps.
- `@addWithOverflow` returns the result and a flag.

## The problem

You add numbers that you do not control: user input, a file or a network peer. `200 + 100` is too large for a `u8`.

In C, this overflow is undefined behavior for a signed type. For an unsigned type, the value wraps and no error occurs. In Zig, in safe builds, a plain `+` **panics** when the result is too large for the type.

The panic is correct for a programming bug. It is wrong for input. The program must handle bad input, and it must not stop.

## The plan

Select the operator that tells what overflow means for this value:

| You want | Use | On overflow |
| --- | --- | --- |
| an error to handle | `std.math.add(T, a, b)` | returns `error.Overflow` |
| a value that stops at the limits | `a +| b` | gives `maxInt` / `minInt` |
| modular arithmetic | `a +% b` | wraps, by definition |
| the flag and the bits | `@addWithOverflow(a, b)` | returns both |

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // In a debug or safe build, plain `a + b` on these values panics. A panic
    // is the correct default for bugs. It is wrong for untrusted input,
    // because bad input is an expected condition, not a programming error.
    const a: u8 = 200;
    const b: u8 = 100;

    // Option 1: an error that you can handle. Use it at trust boundaries,
    // because there the caller decides what "too large" means.
    if (std.math.add(u8, a, b)) |sum| {
        try out.print("std.math.add: {d}\n", .{sum});
    } else |err| {
        try out.print("std.math.add: {t}\n", .{err});
    }

    // Option 2: saturate. The value stops at the limits of the type. Use it
    // for gain controls, progress counters, and all values that must stay at max.
    try out.print("saturating +|: {d}\n", .{a +| b});

    // Option 3: wrap. The operator tells that the arithmetic is modular. Use it
    // for hashes, checksums and ring buffer indices. Do not use it for quantities.
    try out.print("wrapping   +%: {d}\n", .{a +% b});

    // Option 4: an overflow bit that you can check. It returns the wrapped
    // result and a flag. Thus you can branch, and you keep the low bits.
    const pair = @addWithOverflow(a, b);
    try out.print("@addWithOverflow: result={d} overflowed={d}\n", .{
        pair[0], pair[1],
    });

    // Subtraction and multiplication have the same options: std.math.sub
    // and mul, the -| and *| operators, -% and *%, and the builtins.
    try out.print("u8 floor stays a u8: {d}\n", .{@as(u8, 255) +| 1});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.checked-math`)*

## Select a form

- **`std.math.add`** is correct at trust boundaries. The caller gets an error value and decides what "too large" means. For example, the caller can refuse the request, log the error or use a default value.
- **Saturating (`+|`)** is correct for quantities where a value at the limit has a meaning: volume, progress, brightness. The result is not the true sum, but a stop at the limit is the behavior that you want.
- **Wrapping (`+%`)** is for domains that are modular: hashes, checksums, ring buffer indices and sequence numbers. If you use it on a quantity only to prevent a panic, it hides a bug.
- **`@addWithOverflow`** is the low-level tool. You get the wrapped result and a `u1` flag. Thus arithmetic on more than one word can move the carry to the next word.

Subtraction and multiplication have the same four forms:

- `std.math.sub` and `std.math.mul`
- the `-|` and `*|` operators
- `-%` and `*%`
- `@subWithOverflow` and `@mulWithOverflow`

## Why plain `+` must stay plain

You can use `+%` everywhere, and then no operation panics. Do not do this. In a safe build, a panic shows the exact line where an assumption was false. A wrap continues with an incorrect value.

Use plain `+` where overflow is a bug. Use an explicit form where overflow is a condition of the input.
