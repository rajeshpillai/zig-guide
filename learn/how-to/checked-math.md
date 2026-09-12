# Recipe: Overflow Without Panics

> Handling arithmetic that might not fit, without undefined behavior and without crashing.

## The problem

You are adding numbers that come from outside your control: user input, a
file, a network peer. `200 + 100` does not fit in a `u8`. In C that overflow
is undefined behavior (signed) or silent wraparound (unsigned). In Zig, plain
`+` on a value that does not fit **panics** in safe builds. That panic is
correct for a programming bug, and wrong for input handling: bad input is an
expected condition, and the program should handle it, not die.

Zig's answer is to make the overflow policy part of the code. There are four,
and choosing one is the recipe.

## The plan

Pick the operator that states what overflow means for this value:

| You want | Use | On overflow |
| --- | --- | --- |
| an error to handle | `std.math.add(T, a, b)` | returns `error.Overflow` |
| clamp at the bounds | `a +| b` | yields `maxInt` / `minInt` |
| modular arithmetic | `a +% b` | wraps, by definition |
| the flag and the bits | `@addWithOverflow(a, b)` | returns both |

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // In a debug or safe build, plain `a + b` on these panics. That is the
    // right default for bugs, and the wrong tool for untrusted input:
    // input problems are expected conditions, not programming errors.
    const a: u8 = 200;
    const b: u8 = 100;

    // Option 1: an error you can handle. The usual choice at trust
    // boundaries, because the caller decides what "too big" means.
    if (std.math.add(u8, a, b)) |sum| {
        try out.print("std.math.add: {d}\n", .{sum});
    } else |err| {
        try out.print("std.math.add: {t}\n", .{err});
    }

    // Option 2: saturate. Clamps at the type's bounds. Right for gain
    // knobs, progress counters, anything where "pin at max" is meaningful.
    try out.print("saturating +|: {d}\n", .{a +| b});

    // Option 3: wrap. Modular arithmetic, stated in the operator. Right
    // for hashes, checksums, ring buffer indices; wrong for quantities.
    try out.print("wrapping   +%: {d}\n", .{a +% b});

    // Option 4: the bit you can inspect. Returns the wrapped result and a
    // flag, so you can branch without losing the low bits.
    const pair = @addWithOverflow(a, b);
    try out.print("@addWithOverflow: result={d} overflowed={d}\n", .{
        pair[0], pair[1],
    });

    // Same choices exist for subtraction and multiplication: std.math.sub
    // and mul, the -| and *| operators, -% and *%, and the builtins.
    try out.print("u8 floor stays a u8: {d}\n", .{@as(u8, 255) +| 1});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.checked-math`)*

## Choosing between them

- **`std.math.add`** belongs at trust boundaries. The caller gets a real
  error value and decides what "too big" means: reject the request, log it,
  fall back to a default.
- **Saturating (`+|`)** fits quantities where pinning at the limit is
  meaningful: volume, progress, brightness. The result is still wrong as
  arithmetic, but right as behavior.
- **Wrapping (`+%`)** is for domains that are genuinely modular: hashes,
  checksums, ring buffer indices, sequence numbers. Using it to silence a
  panic on a quantity is a bug you have chosen not to hear about.
- **`@addWithOverflow`** is the low-level tool: you get the wrapped result
  and a `u1` flag, so multi-word arithmetic can propagate the carry.

Subtraction and multiplication have the same four spellings: `std.math.sub`
and `std.math.mul`, the `-|` and `*|` operators, `-%` and `*%`, and
`@subWithOverflow` and `@mulWithOverflow`.

## Why plain `+` should stay plain

It is tempting to reach for `+%` everywhere so nothing ever panics. Resist
it. A panic in a safe build points at the exact line where an assumption
broke; a wrap keeps running with a corrupt value. Use plain `+` where
overflow would be a bug, and one of the four explicit forms where overflow
is an input condition.
