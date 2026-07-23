//! title: Strings
//! A string is []const u8. The tools live in std.mem and std.ascii.

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
    // indexOf returns the byte offset of the first match, or null.
    try expect(std.mem.indexOf(u8, "hello world", "world").? == 6);
    try expect(std.mem.indexOf(u8, "hello world", "moon") == null);
    try expect(std.mem.lastIndexOfScalar(u8, "a.b.c", '.').? == 3);
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
