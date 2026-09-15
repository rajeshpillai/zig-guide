# Inline Loops

> Unrolled loops where each iteration can differ in type.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "inline for over a tuple" {
    // A tuple's elements have different types, so the loop body must be
    // compiled separately for each. That is what `inline` provides.
    const tuple = .{ @as(u8, 1), @as(f32, 2.5), true };
    var count: usize = 0;
    inline for (tuple) |value| {
        if (@TypeOf(value) == bool) count += 10 else count += 1;
    }
    try expect(count == 12);
}

test "inline for over types" {
    const types = [_]type{ u8, u16, u32 };
    var total: usize = 0;
    inline for (types) |T| {
        total += @sizeOf(T);
    }
    try expect(total == 7);
}

test "the loop variable becomes comptime-known" {
    var sum: usize = 0;
    inline for (0..4) |i| {
        // `i` is comptime here, so it can be used where a comptime value
        // is required, such as an array type's length.
        const arr: [i]u8 = undefined;
        sum += arr.len;
    }
    try expect(sum == 6); // 0 + 1 + 2 + 3
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.inline-loops`)*

`inline for` unrolls at compile time. That is occasionally about performance,
but the real reason it exists is **types**.

## Iterating heterogeneous things

A tuple's elements have different types. A normal loop body is compiled once,
so it cannot handle that. An `inline for` body is compiled separately per
iteration, so `@TypeOf(value)` can differ each time:

```zig
inline for (tuple) |value| {
    if (@TypeOf(value) == bool) { ... }
}
```

This is how `std.debug.print` walks its arguments, and how serialisation code
walks a struct's fields.

The `if` in that body is not a runtime branch. Each unrolled copy has a
comptime-known `@TypeOf(value)`, so the condition folds to true or false while
compiling and only the surviving branch is generated. A twelve-way `if` chain
over types costs nothing at runtime, because eleven of the arms do not exist
in the output.

## The loop variable becomes comptime-known

Inside `inline for (0..4) |i|`, `i` is a comptime value, so it can be used
where the compiler demands one (array lengths, type construction, field
names):

```zig
const arr: [i]u8 = undefined;   // only valid because i is comptime
```

That is what makes reflection work. `@typeInfo(T).@"struct".field_names` is a
comptime array of strings, and walking it with `inline for` gives you each
name as a comptime string, which `@field(value, name)` can then use to read
the field. A normal `for` gives you a runtime string, and there is no runtime
field lookup to hand it to.

```zig
inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
    try writer.print("{s}={any}\n", .{ name, @field(value, name) });
}
```

Nine tenths of the generic code in the standard library is that shape.

If you have seen `info.fields[i].name` in older Zig code, that is the shape
this replaced. `Type.Struct` now carries parallel arrays (`field_names`,
`field_types`, `field_attrs`) rather than one array of field structs. A loop
that only needs names does not touch the rest.

## `inline while` and `inline else`

The same idea appears on `while` and on `switch`. On `while` the condition has
to be comptime-known, so the compiler can decide how many copies to make. On
`switch`, `inline else` generates one arm per remaining case, with the tag
available as a comptime value. Reach for those in the same situations: when
the body needs to know something the runtime version would have erased.

## Use it deliberately

Unrolling multiplies generated code by the iteration count. For a 3-element
tuple that is free; for `inline for (0..10000)` it is a compile-time and
binary-size disaster. Reach for `inline` when you need comptime-ness, not as a
performance reflex.

The performance reflex is wrong for a second reason: the optimiser already
unrolls loops it thinks are worth unrolling, using cost information about the
target that you do not have. Writing `inline` to make a loop fast overrides a
decision that was probably better than yours. It also does it in a way that
shows up as compile time rather than in a benchmark.

The honest test is whether the body would still compile without `inline`. If
it would, you probably do not need it. If it would not, because the body uses
the loop variable where a comptime value is required, then `inline` is not an
optimisation at all. There was never a choice to make.
