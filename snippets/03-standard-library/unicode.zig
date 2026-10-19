//! title: Unicode
//! []const u8 holds bytes. UTF-8 support is in std.unicode, when you want it.

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
    // 0xff never occurs in well-formed UTF-8.
    try expect(!std.unicode.utf8ValidateSlice(&.{ 0xff, 0xfe }));
}

test "iterate codepoints" {
    // Utf8View.init validates one time. After that, the iterator cannot fail.
    const view = try std.unicode.Utf8View.init("héllo");
    var it = view.iterator();

    try expect(it.nextCodepoint().? == 'h');
    try expect(it.nextCodepoint().? == 'é');
    try expect(it.nextCodepoint().? == 'l');

    // nextCodepointSlice returns the raw bytes, not a u21.
    // Use it to slice the original string.
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
    // s[0..2] cuts é in half: 'h', then the first byte of é without the
    // continuation byte that must follow it.
    try expect(!std.unicode.utf8ValidateSlice(s[0..2]));
    // When you need safe cut points, iterate over codepoint slices.
    try expect(std.unicode.utf8ValidateSlice(s[0..3]));
}
