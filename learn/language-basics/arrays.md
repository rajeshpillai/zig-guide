# Arrays

> Fixed-length sequences whose length is part of the type.

You write an array as `[N]T`. The length `N` is part of the *type*. Thus `[3]u8` and `[4]u8` are as different as `u8` and `u16`.

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
    // Older tutorials show `"-" ** 5`. The `**` repeat operator does not
    // exist on master (`**` is not even a token). Thus use `@splat`. It fills
    // an array of known length with one value.
    const dashes: [5]u8 = @splat('-');
    try expect(std.mem.eql(u8, &dashes, "-----"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.arrays`)*

## Arrays are values

When you assign an array, Zig copies the array. C does the opposite: in almost all expressions, a C array changes into a pointer. If you want a reference, take one explicitly with `&`. The result is a [slice](https://www.ziglang.in/learn/language-basics/slices/).

`.len` is a compile-time constant. The program does not read it from a field at runtime.

An array is a value. Thus, when you give a `[4096]u8` to a function, the compiler can pass all 4096 bytes. When you give `&buffer`, the call passes a slice, which is a pointer and a length. For data that is larger than a few words, pass the slice.

## Write an array literal

With `[_]T`, the compiler counts the elements for you. Use this form, because then the length always agrees with the contents:

```zig
const a = [_]u8{ 1, 2, 3 };        // [3]u8
const grid = [2][3]u8{             // rows of columns
    .{ 1, 2, 3 },
    .{ 4, 5, 6 },
};
```

Multidimensional arrays are arrays of arrays. Thus `grid[1][2]` is 6, and `grid.len` is 2, the number of rows. Zig has no separate matrix type, and no index syntax with commas.

## Compare and join arrays

`==` does not work on arrays:

```
error: operator == not allowed for type '[3]u8'
```

Zig does not make a silent selection between a comparison of the contents and a comparison of the addresses. To compare the contents, use `std.mem.eql(u8, &a, &b)`. This function takes slices. Thus it also compares an array with a slice of a larger buffer.

`++` joins arrays at compile time. The result is an array, and its length is the sum of the two lengths:

```zig
const joined = a ++ [_]u8{ 4 };    // [4]u8
```

The compiler must know the two operands, because the *type* of the result depends on their lengths. To join runtime data, copy the data into a buffer. No operator does this.

## `**` is gone

Older tutorials, and the current zig.guide too, show array repetition:

```zig
const dashes = "-" ** 5;   // does not compile on master
```

The `**` operator does not exist now. `**` is not even a token. Thus the compiler gives a message about whitespace around `*`, and the message is not clear. Use `@splat` instead:

```zig
const dashes: [5]u8 = @splat('-');
```

`@splat` gets its length from the type of the destination. Thus the type annotation is necessary here. The same builtin fills a [vector](https://www.ziglang.in/learn/language-basics/vectors/). Read it as "each element gets this value", and the meaning is correct for the two uses.

The change does not affect `++`. It still joins arrays at comptime.

## Coercion to slices

When you take a reference to an array, the array coerces to a slice of the same element type. The slice gets the length too:

```zig
const s: []const u8 = &a;    // len 3, checked
```

The usual direction is from array to slice. Make the data with an array, where the compiler knows the size and the memory is on the stack. Then pass a slice, where the length moves with the pointer.

The other direction, from a slice to a fixed-size array, needs a length that the compiler knows. [Array recipes](https://www.ziglang.in/learn/language-basics/array-recipes/) explains this direction. That chapter also shows grids and tables that the compiler calculates at compile time.
