# String Recipes

> Padding, runtime concatenation, and the std.mem and std.ascii calls that the Strings chapter does not show.

To pad a string in Zig, give it a width in the format spec, as in `{s:<8}`. To join strings at runtime, use `std.mem.concat`, which takes an allocator. For a case-insensitive search, use `std.ascii.findIgnoreCase`.

```zig
const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "pad a string into a column" {
    var buf: [64]u8 = undefined;

    // There is no lpad or rjust. To pad a string, give {s} a width.
    // Right alignment is the default for all types, and strings too.
    try expectEqualStrings("[     zig]", try std.mem.print(&buf, "[{s:8}]", .{"zig"}));
    try expectEqualStrings("[zig     ]", try std.mem.print(&buf, "[{s:<8}]", .{"zig"}));
    try expectEqualStrings("[  zig   ]", try std.mem.print(&buf, "[{s:^8}]", .{"zig"}));

    // Put the fill byte before the alignment character.
    try expectEqualStrings("[.....zig]", try std.mem.print(&buf, "[{s:.>8}]", .{"zig"}));

    // The width is a minimum. It never truncates. If a value is wider than
    // the field, the formatter prints the full value and the column grows.
    try expectEqualStrings("[abcdefghij]", try std.mem.print(&buf, "[{s:>3}]", .{"abcdefghij"}));
}

test "the width can come from a value" {
    var buf: [64]u8 = undefined;

    // [1] takes the width from argument 1, not from the format string. Use it
    // when the column must be as wide as the longest row.
    const width: usize = 7;
    try expectEqualStrings("....zig", try std.mem.print(&buf, "{s:.>[1]}", .{ "zig", width }));
}

test "padding counts bytes, not characters" {
    var buf: [64]u8 = undefined;

    // Writer.alignBuffer calculates `width - buffer.len`, and len counts bytes.
    // The e-acute is two bytes. Thus this row gets one space less than it needs.
    const accented = try std.mem.print(&buf, "{s:>8}", .{"héllo"});
    try expect(accented.len == 8); // eight bytes
    try expect(try std.unicode.utf8CountCodepoints(accented) == 7); // seven columns

    var other: [64]u8 = undefined;
    const plain = try std.mem.print(&other, "{s:>8}", .{"world"});
    try expect(plain.len == 8);
    try expect(try std.unicode.utf8CountCodepoints(plain) == 8);

    // The spec is the same and the byte count is the same, but the two widths
    // on screen are different. A table of names loses its alignment when one
    // name has an accent.
}

test "concat is ++ with an allocator" {
    const gpa = std.testing.allocator;

    // ++ works only when the compiler knows the two sides at compile time.
    const parts: []const []const u8 = &.{ "usr", "local", "bin" };
    const joined = try std.mem.concat(gpa, u8, parts);
    defer gpa.free(joined);
    try expectEqualStrings("usrlocalbin", joined);

    // joinZ adds the separator and a null terminator, for a C API.
    const path = try std.mem.joinZ(gpa, "/", parts);
    defer gpa.free(path);
    try expectEqualStrings("usr/local/bin", path);
    try expect(path[path.len] == 0);
}

test "measure the format before you allocate" {
    const gpa = std.testing.allocator;

    // count runs the formatter with a writer that discards its output. Thus
    // the length is exact. You do not guess a size and grow the buffer later.
    const size = std.fmt.count("{d}:{d:0>2}", .{ 7, 5 });
    try expect(size == 4);

    const text = try gpa.alloc(u8, size);
    defer gpa.free(text);
    try expectEqualStrings("7:05", try std.mem.print(text, "{d}:{d:0>2}", .{ 7, 5 }));
}

test "replace without allocating" {
    // replacementSize gives the size of the destination. replace fills it and
    // returns the number of substitutions. replaceOwned does not give you that.
    const input = "a-b-c";
    var buf: [16]u8 = undefined;

    const size = std.mem.replacementSize(u8, input, "-", "__");
    try expect(size == 7);

    const count = std.mem.replace(u8, input, "-", "__", buf[0..size]);
    try expect(count == 2);
    try expectEqualStrings("a__b__c", buf[0..size]);
}

test "case-insensitive search" {
    // Use findIgnoreCase, not indexOfIgnoreCase. Zig removed indexOfIgnoreCase
    // and did not rename it. Thus old code that calls it does not compile.
    try expect(std.ascii.findIgnoreCase("Build.ZIG", "zig").? == 6);
    try expect(std.ascii.startsWithIgnoreCase("Build.zig", "BUILD"));
    try expect(std.ascii.endsWithIgnoreCase("Build.zig", ".ZIG"));

    // orderIgnoreCase sorts, and it does not allocate a lowercase copy first.
    try expect(std.ascii.orderIgnoreCase("apple", "Banana") == .lt);
}

test "classify a byte" {
    // trim cannot do this check: each byte must be a digit or a dash.
    const ok = for ("2026-07-30") |c| {
        if (!std.ascii.isDigit(c) and c != '-') break false;
    } else true;
    try expect(ok);

    try expect(std.ascii.isAlphabetic('z'));
    try expect(std.ascii.isWhitespace('\t'));
    try expect(std.ascii.isHex('f'));
    try expect(!std.ascii.isHex('g'));
}

test "build a string then take ownership of it" {
    const gpa = std.testing.allocator;

    // ArrayList has no writer() on master. Writer.Allocating is the growable
    // buffer that you print into. toOwnedSlice gives the memory to the caller.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    for (0..3) |i| try out.writer.print("{d};", .{i});
    try expectEqualStrings("0;1;2;", out.written());

    const owned = try out.toOwnedSlice();
    defer gpa.free(owned);
    try expectEqualStrings("0;1;2;", owned);
    try expect(out.written().len == 0); // the writer kept nothing
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.string-recipes`)*

## Padding is a spec, not a function

Zig has no `lpad`, no `rjust` and no `String.padStart`. To pad a string, give `{s}` a width. The grammar is the one that [Formatting](https://www.ziglang.in/learn/standard-library/formatting/) shows: `{[fill][align][width]}`. For a string, two things are different: the default, and the unit of the width.

Right alignment is the default for all types. Thus `{s:8}` puts the spaces *before* the text. This can surprise you if you know a language where strings align left and numbers align right. Write the alignment that you want:

```zig
"{s:8}"     // "     zig"
"{s:<8}"    // "zig     "
"{s:^8}"    // "  zig   "
"{s:.>8}"   // ".....zig"
```

The width is a minimum. If a value is wider than the field, the formatter prints the full value, and the column becomes wider. The formatter never truncates a value.

## The width counts bytes, not characters

The formatter does not decode the value first. The standard library says this in its own docs: alignment "is not Unicode-aware; appropriate only when used with raw bytes or ASCII."

A table of names stays aligned until one of the names has an accent. To count what a reader calls a character is a different problem. [Unicode Recipes](https://www.ziglang.in/learn/standard-library/unicode-recipes/) shows how to solve it.

## Join at runtime

`++` is a compile-time operator. When the program knows the parts only at runtime, use `std.mem.concat`. It does the same work, and it takes an allocator. `joinZ` puts a separator between the parts and a null terminator at the end. Use it when you give the result to a C API.

If you prefer to calculate the buffer size yourself, use `std.fmt.count`. It runs the formatter with a writer that discards its output, and it returns the exact length. Then you make one allocation of the correct size, and you do not guess.

## Replace without an allocator

`std.mem.replaceOwned` is the easy form, and it allocates. The two functions below it do not allocate:

- `replacementSize` tells you the size of the result.
- `replace` fills memory that you already have.

`replace` also returns the number of substitutions that it made. The owned version does not give you that number.

## Ignore case, with care

`std.ascii` has the full family of functions: `startsWithIgnoreCase`, `endsWithIgnoreCase`, `findIgnoreCase`, and `orderIgnoreCase`. Use `orderIgnoreCase` to sort, because it does not allocate a lowercase copy first.

`findIgnoreCase` replaced a function that Zig removed. An older version had `indexOfIgnoreCase`, and Zig removed it fully. Thus code that uses the old name does not compile. It does not continue to work silently. The `std.mem` search functions are different: their old names still exist as aliases.

All of these functions stop at byte 127.

## When you want a String type

`std.mem` and `std.ascii` give you bytes and a set of functions that operate on them. They do not give you a type that behaves like a string class. If you want that shape, [zig-string](https://github.com/JakubSzark/zig-string) is a UTF-8 aware `String` with the usual methods. It has the MIT license, and its author still maintains it.

It is a dependency, not part of `std`, and on this site that difference is important. Each night, CI compiles and runs each snippet on this site against Zig master. An external library follows the compiler on its own schedule.
