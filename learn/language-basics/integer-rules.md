# Integer Rules

> Arbitrary widths, explicit narrowing, chosen overflow behaviour.

Zig integer types have an explicit width, such as `u8`, `i32` or `u3`. A conversion from a wider type to a narrower type needs `@intCast`.

For plain `+`, overflow is illegal behaviour, and safety builds panic on it. When you want a different result, use one of the two other operators:

- `+%` wraps.
- `+|` saturates.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "arbitrary bit widths" {
    // Each width from u0/i0 to u65535 is a real type.
    const small: u3 = 7;
    try expect(@as(u8, small) == 7);
    try expect(std.math.maxInt(u3) == 7);
}

test "widening is implicit, narrowing is not" {
    const a: u8 = 200;
    const b: u16 = a; // always safe, thus allowed
    try expect(b == 200);

    // `const c: u8 = b;` does not compile. Convert explicitly:
    const c: u8 = @intCast(b); // checked in safety builds
    try expect(c == 200);
}

test "wrapping and saturating operators" {
    const max: u8 = 255;
    // Plain `max + 1` is illegal behaviour (a panic in safety builds).
    try expect(max +% 1 == 0); // wrapping
    try expect(max +| 1 == 255); // saturating
}

test "overflow can be detected instead" {
    const max: u8 = 255;
    const result = @addWithOverflow(max, 1);
    try expect(result[0] == 0); // wrapped value
    try expect(result[1] == 1); // overflow bit set
}

test "comptime_int has no width" {
    // Literals have arbitrary precision until they get a type.
    const big = 1 << 100;
    try expect(big > 0);
    try expect(@TypeOf(1 + 1) == comptime_int);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.integer-rules`)*

## Any width that you want

`u3`, `i7`, `u64` and `u1000` are all real types. `u8` is not special. It is only the width of a byte. Packed structs use these widths to describe bitfields exactly.

The width is part of the type, and the width never depends on the platform. Zig has no `int` whose size changes with the compiler, and no integer promotion rules to remember. Your computer and the CI computer calculate the same results.

The only integer type that depends on the target is `usize`. It depends on the target on purpose, because it is the width of a pointer. See [pointer-sized integers](https://www.ziglang.in/learn/language-basics/pointer-sized-integers/).

`@sizeOf(u3)` is 1, because memory addresses are in bytes. Inside a `packed
struct`, the same `u3` uses exactly three bits. Unusual widths are for the description of a layout and for a limit on a value. Alone, they do not save memory.

## A wider type has no cost, a narrower type has a cost

A conversion from `u8` to `u16` is always safe. Thus Zig does it implicitly. The reverse conversion can lose data. Thus you must write it:

```zig
const c: u8 = @intCast(b);
```

In a build with safety checks, `@intCast` panics if the value does not fit. In `ReleaseFast`, a value that does not fit is illegal behaviour. In the two cases, the cast is visible in the source. Thus you cannot lose the top bits by accident.

The sign is also information. For Zig, a conversion from `i8` to `u8` is a narrowing, also when the widths are equal. The reason is that `u8` has no place for a negative value. Thus this conversion also needs `@intCast`.

`@bitCast` is the other conversion. It keeps the same bits and reads them as a different type. It never checks the value, because nothing can go wrong at the bit level. Use `@intCast` when you mean "this number", and `@bitCast` when you mean "these bits".

## You decide what overflow does

On overflow, plain `+` on integers **traps**. It does not wrap. If you want a different behaviour, ask for it:

| Operator | On overflow |
| --- | --- |
| `+` `-` `*` | illegal behaviour (panics in safety builds) |
| `+%` `-%` `*%` | wrap around |
| `+\|` `-\|` `*\|` | saturate at the type's limit |

You can also detect the overflow. `@addWithOverflow(a, b)` returns a tuple of the wrapped result and an overflow bit.

In C, overflow can corrupt a value, and you get no warning. In Zig, the behaviour is an explicit selection.

Each of the three behaviours is the correct answer for some data:

- Wrapping is correct for hashes, checksums and counters that must cycle.
- Saturating is correct for pixel arithmetic and audio mixing. In these cases, the correct answer above the limit really is the limit.
- The default trap is correct for all other data.

A number that does not fit its type now means that the code has a bug. It is better to find the bug immediately than three functions later.

A common mistake is unsigned subtraction. When `b > a`, `a - b` is an overflow, not a negative number, and it panics. When you count down from `.len`, put the decrement in a place where it cannot run at zero.

## Division and shifts also have rules

`/` on a signed integer that the compiler does not know at comptime does not compile at all. Rounding toward zero and rounding down give different results when an operand is negative. Thus Zig makes you write the one that you want: `@divTrunc`, `@divFloor`, `@divCeil` or `@divExact`.

`%` has the same rule, and you use `@rem` or `@mod`. C shows why the selection is important: for twenty years, the C answer to `-7 / 2` was implementation-defined.

On all platforms, a shift by more than the width is illegal behaviour. Also, the type of the shift amount has only enough bits for a legal shift. Thus `x << 8` on a `u8` does not compile.

## `comptime_int`

Literals have no width until they get one from an assignment. `1 << 100` is correct at compile time. It must fit only when it becomes a runtime value.

`comptime_int` has arbitrary precision. `comptime_float` does not, because it uses `f128`. Thus integer arithmetic at compile time is exact at all magnitudes. The error occurs only when you store the result in a location with a size.

For this reason, a `var` cannot hold a `comptime_int`. To refer to the limits of a type, use `std.math.maxInt(T)` and `minInt(T)`. Do not write the constant yourself.
