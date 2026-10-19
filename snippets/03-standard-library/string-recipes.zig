//! title: String Recipes
//! Padding, runtime concatenation, and the std.mem and std.ascii calls that
//! the Strings chapter does not show.

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
