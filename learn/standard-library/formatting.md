# Formatting

> Format strings that the compiler checks.

A format string is a string that is known at compile time. It has one `{}` placeholder for each argument. `{d}` prints a number, `{s}` prints a string, and `{any}` prints all other values.

The compiler checks the placeholders against the arguments. Thus a mismatch is a compile error, not wrong output at runtime.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "bufPrint formats into memory you own" {
    var buf: [64]u8 = undefined;
    const text = try std.mem.print(&buf, "{s} is {d}", .{ "answer", 42 });
    try expect(std.mem.eql(u8, text, "answer is 42"));
}

test "common specifiers" {
    var buf: [64]u8 = undefined;

    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d}", .{255}), "255"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{x}", .{255}), "ff"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{X}", .{255}), "FF"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{b}", .{5}), "101"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{o}", .{8}), "10"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{c}", .{@as(u8, 'A')}), "A"));
}

test "width, alignment and fill" {
    var buf: [64]u8 = undefined;

    // {[fill][align][width]}: the align value is <, ^ or >.
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:5}", .{42}), "   42"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:<5}", .{42}), "42   "));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:^5}", .{42}), " 42  "));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:0>5}", .{42}), "00042"));
}

test "a width makes a signed integer carry its sign" {
    var buf: [64]u8 = undefined;

    // The same width with three types. A literal is `comptime_int`, and it
    // prints with no sign. The tests above depend on this result.
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:5}", .{42}), "   42"));

    // When you give a width, a signed value prints a `+` in front. The sign
    // is part of the number. Thus the fill goes in front of the sign, not
    // between the sign and the digits.
    const signed: i32 = 42;
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:5}", .{signed}), "  +42"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:<5}", .{signed}), "+42  "));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:0>5}", .{signed}), "00+42"));

    // An unsigned value has no sign. Thus a width adds the expected padding.
    const unsigned: u32 = 42;
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:5}", .{unsigned}), "   42"));

    // Without the width, the `+` does not appear. For this reason, you
    // usually see the problem only when you align a column of numbers.
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d}", .{signed}), "42"));
}

test "float precision" {
    var buf: [64]u8 = undefined;
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:.2}", .{3.14159}), "3.14"));
}

test "escaping braces" {
    var buf: [64]u8 = undefined;
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{{{d}}}", .{1}), "{1}"));
}

test "allocPrint when the length is unknown" {
    const gpa = std.testing.allocator;
    const text = try gpa.print("{d}-{d}", .{ 1, 2 });
    defer gpa.free(text);
    try expect(std.mem.eql(u8, text, "1-2"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.formatting`)*

## The destination of the output

| Function | Writes to |
| --- | --- |
| `std.mem.print` | a buffer that you supply (no allocation) |
| `allocator.print` | new memory (the caller frees it) |
| `writer.print` | any writer |

`std.mem.print` returns a slice of the part that it filled. If the buffer is too small, it fails with `error.NoSpaceLeft`. It does not truncate the text.

## Specifiers

| Spec | Meaning |
| --- | --- |
| `{d}` | decimal |
| `{x}` / `{X}` | lower / upper hex |
| `{b}` / `{o}` | binary / octal |
| `{s}` | string |
| `{c}` | a byte as a character |
| `{any}` | structural dump |

## Width, alignment, precision

The form is `{[fill][align][width]}`. For alignment, use `<`, `^` or `>`:

```zig
"{d:5}"     // "   42"  (right by default for numbers)
"{d:<5}"    // "42   "
"{d:^5}"    // " 42  "
"{d:0>5}"   // "00042"
"{d:.2}"    // "3.14"
```

Right alignment is the default for each type, also for strings. This often causes mistakes: `{s:8}` puts the padding before the text, not after the text. A column of strings has three more rules for alignment. [String
Recipes](https://www.ziglang.in/learn/standard-library/string-recipes/) gives these rules.

To write a literal brace, write it two times: `{{` and `}}`.

## A width makes a signed integer show its sign

The outputs above are the result of a literal, and a literal is `comptime_int`. If you give the same width to a signed value, a `+` appears in front of the value:

```zig
const signed: i32 = 42;
"{d:5}"    // "  +42"
"{d:<5}"   // "+42  "
"{d:0>5}"  // "00+42"
"{d}"      // "42"     no width, no sign
```

An unsigned value has no sign. Thus `{d:5}` on a `u32` adds padding to `"   42"`, as the table above shows.

The `+` is part of the width. The fill goes in front of the `+`, not between the sign and the digits. For this reason, `00042` becomes `00+42`.

A review usually does not find the bug that this causes. The format string is correct and the type is correct. The column is only one character narrower than the numbers in the column.

You see the bug when a heading does not align with a table that the program printed from an `i64`. If the value cannot be negative, the fix is a cast to the unsigned type.

## `bufPrint` and `allocPrint` moved

If you wrote Zig before, you know the first two rows of the table as `std.fmt.bufPrint` and `std.fmt.allocPrint`:

```zig
// older tutorials
const text = try std.fmt.bufPrint(&buf, "{d}", .{42});
const owned = try std.fmt.allocPrint(gpa, "{d}", .{42});

// current master
const text = try std.mem.print(&buf, "{d}", .{42});
const owned = try gpa.print("{d}", .{42});
```

The two old names still resolve, and the error sets are the same. Now the definition of `std.fmt.BufPrintError` is `std.mem.PrintError`.

The buffer version moved to `std.mem`, because a function that fills a slice is a slice operation. The version that allocates became `Allocator.print`, a method next to `alloc` and `dupe`.

The new names do not say "print into a buffer" as `bufPrint` did. Also, `Allocator.print` does not look like a function that allocates. Thus read the receiver, not the verb:

- `mem` means that you supplied the memory.
- An allocator means that you own the result, and you must free it.

## The compiler checks the format string

The format string is a comptime parameter. Thus the compiler checks the argument count and each specifier against the argument types. A `{d}` for a string does not compile. A format string cannot fail at runtime.
