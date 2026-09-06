# String Recipes

> Padding, runtime concatenation, and the std.mem and std.ascii calls the Strings chapter left out.

```zig
const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "pad a string into a column" {
    var buf: [64]u8 = undefined;

    // There is no lpad or rjust. You pad by giving {s} a width.
    // Right is the default for every type, strings included.
    try expectEqualStrings("[     zig]", try std.mem.print(&buf, "[{s:8}]", .{"zig"}));
    try expectEqualStrings("[zig     ]", try std.mem.print(&buf, "[{s:<8}]", .{"zig"}));
    try expectEqualStrings("[  zig   ]", try std.mem.print(&buf, "[{s:^8}]", .{"zig"}));

    // The fill byte goes before the alignment character.
    try expectEqualStrings("[.....zig]", try std.mem.print(&buf, "[{s:.>8}]", .{"zig"}));

    // Width is a minimum, never a truncation: a value wider than the field is
    // printed whole and pushes the column out.
    try expectEqualStrings("[abcdefghij]", try std.mem.print(&buf, "[{s:>3}]", .{"abcdefghij"}));
}

test "the width can come from a value" {
    var buf: [64]u8 = undefined;

    // [1] takes the width from argument 1 rather than the format string, which
    // is what you need when the column is as wide as the longest row.
    const width: usize = 7;
    try expectEqualStrings("....zig", try std.mem.print(&buf, "{s:.>[1]}", .{ "zig", width }));
}

test "padding counts bytes, not characters" {
    var buf: [64]u8 = undefined;

    // Writer.alignBuffer computes `width - buffer.len`, and len is bytes. The
    // e-acute costs two bytes, so this row gets one fewer space than it needs.
    const accented = try std.mem.print(&buf, "{s:>8}", .{"héllo"});
    try expect(accented.len == 8); // eight bytes
    try expect(try std.unicode.utf8CountCodepoints(accented) == 7); // seven columns

    var other: [64]u8 = undefined;
    const plain = try std.mem.print(&other, "{s:>8}", .{"world"});
    try expect(plain.len == 8);
    try expect(try std.unicode.utf8CountCodepoints(plain) == 8);

    // Same spec, same byte count, two different widths on screen. A table of
    // names stops lining up the moment one of them has an accent in it.
}

test "concat is ++ with an allocator" {
    const gpa = std.testing.allocator;

    // ++ only works when both sides are known at compile time.
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

    // count runs the formatter against a writer that discards, so the length is
    // exact rather than a guess you have to grow out of.
    const size = std.fmt.count("{d}:{d:0>2}", .{ 7, 5 });
    try expect(size == 4);

    const text = try gpa.alloc(u8, size);
    defer gpa.free(text);
    try expectEqualStrings("7:05", try std.mem.print(text, "{d}:{d:0>2}", .{ 7, 5 }));
}

test "replace without allocating" {
    // replacementSize sizes the destination; replace fills it and returns how
    // many substitutions it made, which replaceOwned does not tell you.
    const input = "a-b-c";
    var buf: [16]u8 = undefined;

    const size = std.mem.replacementSize(u8, input, "-", "__");
    try expect(size == 7);

    const count = std.mem.replace(u8, input, "-", "__", buf[0..size]);
    try expect(count == 2);
    try expectEqualStrings("a__b__c", buf[0..size]);
}

test "case-insensitive search" {
    // findIgnoreCase, not indexOfIgnoreCase: that one was removed rather than
    // renamed, so old code fails to compile instead of quietly working.
    try expect(std.ascii.findIgnoreCase("Build.ZIG", "zig").? == 6);
    try expect(std.ascii.startsWithIgnoreCase("Build.zig", "BUILD"));
    try expect(std.ascii.endsWithIgnoreCase("Build.zig", ".ZIG"));

    // orderIgnoreCase sorts without allocating a lowercased copy first.
    try expect(std.ascii.orderIgnoreCase("apple", "Banana") == .lt);
}

test "classify a byte" {
    // A validator trim cannot express: every byte has to be a digit or a dash.
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
    // buffer you print into, and toOwnedSlice hands the memory to the caller.
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

There is no `lpad`, no `rjust`, no `String.padStart`. You pad by giving `{s}`
a width, and the grammar is the one
[Formatting](https://www.ziglang.in/learn/standard-library/formatting/) sets out:
`{[fill][align][width]}`. What changes for a string is the default and what
the width is counted in.

Right is the default for every type, so `{s:8}` puts the spaces *before* the
text. That surprises people arriving from languages where strings left-align
and numbers right-align. Say which one you want:

```zig
"{s:8}"     // "     zig"
"{s:<8}"    // "zig     "
"{s:^8}"    // "  zig   "
"{s:.>8}"   // ".....zig"
```

Width is a minimum. A value wider than the field is printed whole and pushes
the column out; formatting never truncates for you.

## The width can be a value

Nothing decodes the value first, and the standard library says so in its own
docs: alignment "is not Unicode-aware; appropriate only when used with raw
bytes or ASCII." A table of names lines up until one of them has an accent in
it. Counting what a reader would call a character is a separate problem, and
[Unicode Recipes](https://www.ziglang.in/learn/standard-library/unicode-recipes/) is where it lives.

## Joining at runtime

`++` is a compile-time operator. When the pieces are only known while the
program runs, `std.mem.concat` is the equivalent and it takes an allocator.
`joinZ` puts a separator between the parts and a null terminator on the end,
for handing the result to a C API.

When you would rather size the buffer yourself, `std.fmt.count` runs the
formatter against a writer that discards and returns the exact length. That
turns "allocate and hope" into one allocation of the right size.

## Replacing without an allocator

`std.mem.replaceOwned` is the convenient form and it allocates. The pair
underneath it does not: `replacementSize` tells you how big the result will
be, and `replace` fills memory you already have. `replace` also returns how
many substitutions it made, which the owned version throws away.

## Ignoring case, carefully

`std.ascii` has the whole family: `startsWithIgnoreCase`,
`endsWithIgnoreCase`, `findIgnoreCase`, and `orderIgnoreCase` for sorting
without allocating a lowercased copy first.

`findIgnoreCase` is worth naming, because it is not a rename. There used to be
an `indexOfIgnoreCase` and it was removed outright, so code written against
the old name fails to compile rather than quietly working. That is the
opposite of what happened to the `std.mem` search family, where the old names
survive as aliases.

All of it stops at byte 127, on purpose.

## When you want a String type

`std.mem` and `std.ascii` give you bytes and a set of functions over them, and
nothing that behaves like a string class. If that shape is what you are after,
[zig-string](https://github.com/JakubSzark/zig-string) is a UTF-8 aware
`String` with the methods you would expect, MIT licensed and still maintained.

It is a dependency rather than part of `std`, which matters here specifically.
Every snippet on this site is compiled and run against Zig master nightly, and
an external library tracks the compiler on its own schedule.
