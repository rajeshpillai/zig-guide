# Arrays

> Fixed-length sequences whose length is part of the type.

An array is written `[N]T`. The length `N` is part of the *type*, so `[3]u8`
and `[4]u8` are as different as `u8` and `u16`.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "array literal and length" {
    const message = [5]u8{ 'h', 'e', 'l', 'l', 'o' };
    try expect(message.len == 5);

    // `_` infers the length from the literal.
    const alt = [_]u8{ 'w', 'o', 'r', 'l', 'd' };
    try expect(alt.len == 5);
}

test "arrays are values, not pointers" {
    const a = [_]i32{ 1, 2, 3 };
    var b = a; // a full copy
    b[0] = 99;
    try expect(a[0] == 1);
    try expect(b[0] == 99);
}

test "concatenate at comptime" {
    const joined = [_]i32{ 1, 2 } ++ [_]i32{ 3, 4 };
    try expect(joined.len == 4);
    try expect(joined[3] == 4);
}

test "repeat with @splat" {
    // Older tutorials show `"-" ** 5`. The `**` repeat operator no longer
    // exists on master (`**` does not even tokenise), so use `@splat`,
    // which fills an array of known length with one value.
    const dashes: [5]u8 = @splat('-');
    try expect(std.mem.eql(u8, &dashes, "-----"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.arrays`)*

## Arrays are values

Assigning an array copies it. This is the opposite of C, where an array decays
to a pointer at the slightest provocation. If you want a reference, take one
explicitly with `&`, which gives you a
[slice](https://www.ziglang.in/learn/language-basics/slices/).

`.len` is a compile-time constant, not a field read at runtime.

Being a value has a consequence worth planning for: passing a `[4096]u8` to a
function passes 4096 bytes, or at least gives the compiler the option. Passing
`&buffer` passes a slice, which is a pointer and a length. For anything larger
than a few words, the slice is what you meant.

## Writing one down

`[_]T` lets the compiler count for you, which is the form to prefer because
the length cannot fall out of sync with the contents:

```zig
const a = [_]u8{ 1, 2, 3 };        // [3]u8
const grid = [2][3]u8{             // rows of columns
    .{ 1, 2, 3 },
    .{ 4, 5, 6 },
};
```

Multidimensional arrays are arrays of arrays, so `grid[1][2]` is 6 and
`grid.len` is 2, the number of rows. There is no separate matrix type and no
comma-indexing.

## Comparing and joining

`==` does not work on arrays:

```
error: operator == not allowed for type '[3]u8'
```

Zig will not silently pick between comparing the contents and comparing the
addresses. Compare contents with `std.mem.eql(u8, &a, &b)`, which takes slices
and so also works between an array and a slice of a larger buffer.

`++` concatenates, at compile time, producing an array whose length is the
sum:

```zig
const joined = a ++ [_]u8{ 4 };    // [4]u8
```

Both operands have to be comptime-known, because the result's *type* depends
on their lengths. Joining runtime data is a copy into a buffer, not an
operator.

## `**` is gone

Older tutorials, including the current zig.guide, show array repetition:

```zig
const dashes = "-" ** 5;   // does not compile on master
```

The `**` operator has been **removed**; `**` no longer even tokenises, so the
compiler reports a confusing message about whitespace around `*`. Use `@splat`
instead:

```zig
const dashes: [5]u8 = @splat('-');
```

`@splat` takes its length from the type you are assigning to, which is why the
annotation is not optional here. It is the same builtin used to fill a
[vector](https://www.ziglang.in/learn/language-basics/vectors/), and reading it as "every element
gets this value" covers both uses.

Concatenation with `++` is unaffected and still works at comptime.

## Coercion to slices

An array coerces to a slice of the same element type when you take a reference
to it, and the length comes along:

```zig
const s: []const u8 = &a;    // len 3, checked
```

That is the usual direction. Build with an array, where the size is known and
the memory is on the stack. Then pass a slice, where the length travels with
the pointer. Going back the other way, turning a slice into a fixed-size
array, needs the length to be comptime-known and is covered in [array
recipes](https://www.ziglang.in/learn/language-basics/array-recipes/).

Grids, tables computed at compile time, and getting a fixed-size array back
out of a slice are in [Array Recipes](https://www.ziglang.in/learn/language-basics/array-recipes/).
