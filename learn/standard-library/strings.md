# Strings

> Search, trim, split, join. All of it lives in std.mem.

```zig
const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "compare content, not pointers" {
    // There is no == for slices; that would compare pointer and length.
    try expect(std.mem.eql(u8, "zig", "zig"));
    try expect(std.mem.startsWith(u8, "build.zig", "build"));
    try expect(std.mem.endsWith(u8, "build.zig", ".zig"));
}

test "search" {
    // find returns the byte offset of the first match, or null.
    try expect(std.mem.find(u8, "hello world", "world").? == 6);
    try expect(std.mem.find(u8, "hello world", "moon") == null);
    try expect(std.mem.findScalarLast(u8, "a.b.c", '.').? == 3);
    try expect(std.mem.count(u8, "banana", "an") == 2);
}

test "trim strips a set of bytes, not a pattern" {
    // The second slice is the set of bytes to remove from the ends.
    try expectEqualStrings("data", std.mem.trim(u8, "  data\n", " \n"));
    try expectEqualStrings("data  ", std.mem.trimStart(u8, "  data  ", " "));
    try expectEqualStrings("  data", std.mem.trimEnd(u8, "  data  ", " "));
}

test "split keeps empty fields, tokenize skips them" {
    // split: one entry per delimiter. "a,,b" has three fields, one empty.
    // Right for CSV-shaped input where an empty field means something.
    var fields = std.mem.splitScalar(u8, "a,,b", ',');
    try expectEqualStrings("a", fields.next().?);
    try expectEqualStrings("", fields.next().?);
    try expectEqualStrings("b", fields.next().?);
    try expect(fields.next() == null);

    // tokenize: runs of delimiters collapse. Right for whitespace.
    var words = std.mem.tokenizeScalar(u8, "  one  two ", ' ');
    try expectEqualStrings("one", words.next().?);
    try expectEqualStrings("two", words.next().?);
    try expect(words.next() == null);
}

test "join and replace return new memory" {
    const gpa = std.testing.allocator;

    const path = try std.mem.join(gpa, "/", &.{ "usr", "local", "bin" });
    defer gpa.free(path);
    try expectEqualStrings("usr/local/bin", path);

    const snake = try std.mem.replaceOwned(u8, gpa, "a-b-c", "-", "_");
    defer gpa.free(snake);
    try expectEqualStrings("a_b_c", snake);
}

test "case functions are ASCII-only on purpose" {
    // Real case mapping needs Unicode tables the std library does not ship.
    try expect(std.ascii.eqlIgnoreCase("Zig", "zIG"));

    const gpa = std.testing.allocator;
    const lower = try std.ascii.allocLowerString(gpa, "MiXeD");
    defer gpa.free(lower);
    try expectEqualStrings("mixed", lower);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.strings`)*

## There is no string type

A string is `[]const u8`: a slice of bytes. That means `==` compares the
pointer and length, not the content, and the compiler will tell you so.
Content comparison is `std.mem.eql(u8, a, b)`. Everything else you would
expect from a string class is a free function in `std.mem` that works on any
slice type. That is why each call names the element type first.

## `indexOf` is now `find`

The search functions were renamed during the 0.17 development series:

```zig
// older tutorials
std.mem.indexOf(u8, haystack, needle);
std.mem.lastIndexOfScalar(u8, path, '.');

// current master
std.mem.find(u8, haystack, needle);
std.mem.findScalarLast(u8, path, '.');
```

The whole family moved the same way: `indexOfScalar` to `findScalar`,
`indexOfAny` to `findAny`, `indexOfPos` to `findPos`, `lastIndexOf` to
`findLast`, `indexOfNone` to `findNone`.

The old names are still there, as one-line aliases marked `Deprecated` in
`std/mem.zig`. Code written against them compiles and behaves identically.
That is exactly why this is worth a section: nothing fails, so a guide could
teach the old spelling for another year and never find out.

## split or tokenize

The two look interchangeable until the input has consecutive delimiters:

| Input `"a,,b"` with `,` | Yields |
| --- | --- |
| `splitScalar` | `"a"`, `""`, `"b"` |
| `tokenizeScalar` | `"a"`, `"b"` |

`split` preserves empty fields, which is what CSV-shaped data needs.
`tokenize` collapses runs of delimiters, which is what whitespace needs. Both
have `Any` and `Sequence` variants: `splitAny` treats the delimiter string as
a set of single bytes, `splitSequence` matches it whole.

## What allocates and what does not

`trim`, `split`, and `tokenize` return views into the original bytes: no copy,
but the result is only valid as long as the original. `join`, `replaceOwned`,
and `std.ascii.allocLowerString` build new strings, so they take an allocator
and you own the result.

## ASCII on purpose

`std.ascii` stops at byte 127. Case mapping beyond that needs Unicode tables
the standard library does not ship; see the Unicode chapter for what it does
give you.

Case-insensitive search, padding a column, joining at runtime and replacing
without an allocator are in [String
Recipes](https://www.ziglang.in/learn/standard-library/string-recipes/).
