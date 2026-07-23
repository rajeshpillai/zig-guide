//! title: Unicode
//! []const u8 holds bytes. UTF-8 awareness is opt-in, in std.unicode.

const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "len counts bytes, not characters" {
    const s = "héllo"; // é is two bytes in UTF-8
    try expect(s.len == 6);
    try expect(try std.unicode.utf8CountCodepoints(s) == 5);
}

test "validate untrusted input first" {
    try expect(std.unicode.utf8ValidateSlice("héllo"));
    // 0xff never appears in well-formed UTF-8.
    try expect(!std.unicode.utf8ValidateSlice(&.{ 0xff, 0xfe }));
}

test "iterate codepoints" {
    // Utf8View.init validates once; iteration after that cannot fail.
    const view = try std.unicode.Utf8View.init("héllo");
    var it = view.iterator();

    try expect(it.nextCodepoint().? == 'h');
    try expect(it.nextCodepoint().? == 'é');
    try expect(it.nextCodepoint().? == 'l');

    // nextCodepointSlice returns the raw bytes instead of a u21,
    // useful when slicing the original string.
    var rest = view.iterator();
    _ = rest.nextCodepointSlice();
    const e_bytes = rest.nextCodepointSlice().?;
    try expect(e_bytes.len == 2);
}

test "encode a codepoint to bytes" {
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode('→', &buf);
    try expect(len == 3);
    try expectEqualStrings("→", buf[0..len]);
}

test "slicing bytes can split a character" {
    const s = "héllo";
    // s[0..2] cuts é in half: one valid byte, one dangling continuation.
    try expect(!std.unicode.utf8ValidateSlice(s[0..2]));
    // Iterate codepoint slices when you need safe cut points.
    try expect(std.unicode.utf8ValidateSlice(s[0..3]));
}
