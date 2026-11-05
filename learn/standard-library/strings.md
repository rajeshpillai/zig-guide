# Strings

> Search, trim, split, join. All of these functions are in std.mem.

In Zig, a string is a `[]const u8`. The functions that search, trim, split and join strings are free functions in `std.mem`, for example `std.mem.find`, `std.mem.trim` and `std.mem.splitScalar`.

```zig
const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "compare content, not pointers" {
    // The compiler rejects == on slices. Thus compare the contents with eql.
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
    // The second slice is the set of bytes to remove from the two ends.
    try expectEqualStrings("data", std.mem.trim(u8, "  data\n", " \n"));
    try expectEqualStrings("data  ", std.mem.trimStart(u8, "  data  ", " "));
    try expectEqualStrings("  data", std.mem.trimEnd(u8, "  data  ", " "));
}

test "split keeps empty fields, tokenize skips them" {
    // split: one entry for each field. "a,,b" has three fields, and one field
    // is empty. Use split for CSV-shaped input, where an empty field has a meaning.
    var fields = std.mem.splitScalar(u8, "a,,b", ',');
    try expectEqualStrings("a", fields.next().?);
    try expectEqualStrings("", fields.next().?);
    try expectEqualStrings("b", fields.next().?);
    try expect(fields.next() == null);

    // tokenize: a sequence of delimiters counts as one. Use it for whitespace.
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
    // Real case mapping needs Unicode tables. The std library does not include them.
    try expect(std.ascii.eqlIgnoreCase("Zig", "zIG"));

    const gpa = std.testing.allocator;
    const lower = try std.ascii.allocLowerString(gpa, "MiXeD");
    defer gpa.free(lower);
    try expectEqualStrings("mixed", lower);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.strings`)*

## There is no string type

A string is `[]const u8`, a slice of bytes. Thus you cannot compare two strings with `==`, because the compiler rejects `==` on slices. To compare the contents, use `std.mem.eql(u8, a, b)`. To put two strings in order, use `std.mem.order(u8, a, b)`, which returns `.lt`, `.eq` or `.gt`.

All the other functions that you expect from a string class are free functions in `std.mem`. They work on all slice types. For this reason, each call gives the element type first.

## `indexOf` is now `find`

Zig renamed the search functions in the 0.17 development series:

```zig
// older tutorials
std.mem.indexOf(u8, haystack, needle);
std.mem.lastIndexOfScalar(u8, path, '.');

// current master
std.mem.find(u8, haystack, needle);
std.mem.findScalarLast(u8, path, '.');
```

All the functions in the family changed in the same way:

- `indexOfScalar` became `findScalar`.
- `indexOfAny` became `findAny`.
- `indexOfPos` became `findPos`.
- `lastIndexOf` became `findLast`.
- `indexOfNone` became `findNone`.

The old names still exist, as one-line aliases with the `Deprecated` mark in `std/mem.zig`. Code that uses the old names compiles and behaves in the same way. Nothing fails. Thus a guide can teach the old names for another year, and the authors do not see the problem.

## split or tokenize

The two functions look interchangeable until the input has two delimiters next to each other:

| Input `"a,,b"` with `,` | Yields |
| --- | --- |
| `splitScalar` | `"a"`, `""`, `"b"` |
| `tokenizeScalar` | `"a"`, `"b"` |

`split` keeps empty fields. CSV-shaped data needs this behaviour. `tokenize` treats a sequence of delimiters as one delimiter. Whitespace needs this behaviour.

The two functions have `Any` and `Sequence` variants:

- `splitAny` uses each byte of the delimiter string as a separate delimiter.
- `splitSequence` matches the full delimiter string.

## What allocates and what does not

`trim`, `split`, and `tokenize` return views into the original bytes. They do not copy. Thus the result is valid only while the original is valid.

`join`, `replaceOwned`, and `std.ascii.allocLowerString` make new strings. Thus they take an allocator, and you own the result.

## ASCII only

`std.ascii` stops at byte 127. Case mapping above byte 127 needs Unicode tables, and the standard library does not include these tables. The Unicode chapter shows what the standard library gives you.

[String Recipes](https://www.ziglang.in/learn/standard-library/string-recipes/) shows a case-insensitive search, padding for a column, a join at runtime, and a replace without an allocator.
