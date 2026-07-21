//! title: Iterators
//! A convention, not an interface: any struct with `next()`.

const std = @import("std");
const expect = std.testing.expect;

// Zig has no Iterator trait. A type is iterable if it has `next()` returning
// an optional, because that is what `while (it.next()) |x|` needs.
const Countdown = struct {
    remaining: u32,

    pub fn next(self: *Countdown) ?u32 {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return self.remaining;
    }
};

test "write your own iterator" {
    var it = Countdown{ .remaining = 3 };
    var sum: u32 = 0;
    while (it.next()) |value| sum += value;
    try expect(sum == 3); // 2 + 1 + 0
}

test "split on a single byte" {
    var it = std.mem.splitScalar(u8, "a,b,c", ',');
    try expect(std.mem.eql(u8, it.next().?, "a"));
    try expect(std.mem.eql(u8, it.next().?, "b"));
    try expect(std.mem.eql(u8, it.next().?, "c"));
    try expect(it.next() == null);
}

test "split keeps empty fields, tokenize does not" {
    var split = std.mem.splitScalar(u8, "a,,b", ',');
    var split_count: u32 = 0;
    while (split.next()) |_| split_count += 1;
    try expect(split_count == 3); // "a", "", "b"

    var tokens = std.mem.tokenizeScalar(u8, "a,,b", ',');
    var token_count: u32 = 0;
    while (tokens.next()) |_| token_count += 1;
    try expect(token_count == 2); // "a", "b"
}

test "tokenize on any of several separators" {
    var it = std.mem.tokenizeAny(u8, "one two\tthree", " \t");
    try expect(std.mem.eql(u8, it.next().?, "one"));
    try expect(std.mem.eql(u8, it.next().?, "two"));
    try expect(std.mem.eql(u8, it.next().?, "three"));
}

test "window and chunk a slice" {
    var windows = std.mem.window(u8, "abcd", 2, 1); // overlapping
    try expect(std.mem.eql(u8, windows.next().?, "ab"));
    try expect(std.mem.eql(u8, windows.next().?, "bc"));
}
