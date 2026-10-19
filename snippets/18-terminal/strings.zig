//! title: String Primitives
//! str_len, str_eq, str_copy, str_trim, written out. The off-by-one error is here.

const std = @import("std");

/// Walk the string until the zero byte. C calls this function `strlen`. Its
/// cost is the reason that a slice holds its length. Each call is O(n). A call
/// inside a loop changes an O(n) job into O(n^2) work.
fn strLen(s: [*:0]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) i += 1;
    return i;
}

fn strEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Copy `src` into `dest` and terminate the copy. If `src` is too large for
/// `dest`, return null. Do not write a part of `src`.
///
/// The `+ 1` is for the terminator. A 5-byte string needs 6 bytes of space.
/// A version that checks `src.len > dest.len` compiles and passes a simple
/// test. But that version writes one byte past the end of the buffer.
fn strCopy(dest: []u8, src: []const u8) ?[:0]u8 {
    if (src.len + 1 > dest.len) return null;
    @memcpy(dest[0..src.len], src);
    dest[src.len] = 0;
    return dest[0..src.len :0];
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Trim both ends, and do not move a byte. A trim does not need a copy. The
/// result is a slice of the bytes that you already have.
fn strTrim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isSpace(s[start])) start += 1;
    while (end > start and isSpace(s[end - 1])) end -= 1;
    return s[start..end];
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const greeting = "hello";
    try out.print("strLen(\"hello\")   = {d}\n", .{strLen(greeting)});
    try out.print("greeting.len      = {d}   (already known, no walk)\n\n", .{greeting.len});

    try out.print("strEq(\"cat\",\"cat\") = {}\n", .{strEq("cat", "cat")});
    try out.print("strEq(\"cat\",\"cot\") = {}\n", .{strEq("cat", "cot")});
    try out.print("strEq(\"cat\",\"cats\")= {}\n\n", .{strEq("cat", "cats")});

    // Six bytes of space for five bytes of text.
    var room: [6]u8 = undefined;
    if (strCopy(&room, "hello")) |copied| {
        try out.print("copied \"{s}\" into 6 bytes, terminator at index {d}\n", .{ copied, copied.len });
    }
    var tight: [5]u8 = undefined;
    try out.print("copying \"hello\" into 5 bytes -> {s}\n\n", .{
        if (strCopy(&tight, "hello") == null) "refused" else "wrote",
    });

    // This buffer is separate from `buf`. An earlier version gave `buf` here.
    // Then `buf` held the data of the writer and the data of `escape`, and
    // this garbled the first line of output. Both slices hold a length. Thus the
    // mistake garbled the output, and did not write past the end of a buffer.
    var scratch: [64]u8 = undefined;
    for ([_][]const u8{ "  padded  ", "\tboth\n", "none", "   ", "" }) |sample| {
        try out.print("trim(\"{s}\") -> \"{s}\"\n", .{ escape(sample, &scratch), strTrim(sample) });
    }

    try out.flush();
}

/// Show whitespace as visible text, so that you can check the trim by eye.
fn escape(s: []const u8, scratch: []u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        const replacement: []const u8 = switch (c) {
            '\t' => "\\t",
            '\n' => "\\n",
            else => &[_]u8{c},
        };
        @memcpy(scratch[n..][0..replacement.len], replacement);
        n += replacement.len;
    }
    return scratch[0..n];
}
