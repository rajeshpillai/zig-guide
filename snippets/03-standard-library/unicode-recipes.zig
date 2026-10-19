//! title: Unicode Recipes
//! Truncate on a character boundary, decode one codepoint, and convert to UTF-16.

const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "length from the first byte" {
    const s = "héllo";

    // The lead byte gives the length of the sequence. Thus you can decode
    // one character, and you do not scan forward for the next boundary.
    try expect(try std.unicode.utf8ByteSequenceLength(s[0]) == 1);
    try expect(try std.unicode.utf8ByteSequenceLength(s[1]) == 2);

    // Decode with the function for that length. The old utf8Decode took a
    // slice, and it is deprecated. It asserted that the length matched, and it
    // could not tell you when the length did not match.
    try expect(try std.unicode.utf8Decode2(s[1..3].*) == 'é');

    // A continuation byte is not a start byte, and the function tells you so.
    try std.testing.expectError(error.Utf8InvalidStartByte, std.unicode.utf8ByteSequenceLength(s[2]));
}

test "how many bytes will this codepoint need" {
    // The same question for the encoder. Ask before you set the size of a buffer.
    try expect(try std.unicode.utf8CodepointSequenceLength('a') == 1);
    try expect(try std.unicode.utf8CodepointSequenceLength('é') == 2);
    try expect(try std.unicode.utf8CodepointSequenceLength('€') == 3);
}

/// Cut `s` to `max_bytes` or less. Stop at the last full character, not in
/// the middle of a character. std has no function for this.
fn truncate(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    const view = std.unicode.Utf8View.init(s) catch return s[0..0];
    var it = view.iterator();
    var end: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        const next = end + slice.len;
        if (next > max_bytes) break;
        end = next;
    }
    return s[0..end];
}

test "truncate at a character boundary" {
    const s = "héllo";

    // Byte 2 is inside the e-acute. The simple cut gives invalid UTF-8.
    try expect(!std.unicode.utf8ValidateSlice(s[0..2]));

    // truncate moves back to the last full character.
    try expectEqualStrings("h", truncate(s, 2));
    try expect(std.unicode.utf8ValidateSlice(truncate(s, 2)));

    try expectEqualStrings("hé", truncate(s, 3));
    try expectEqualStrings("héllo", truncate(s, 99));
}

test "find the character that contains byte 2" {
    const s = "héllo";

    // Continuation bytes are 0b10xxxxxx. Walk back while the byte is a
    // continuation byte. The walk stops on the start byte of the character.
    var i: usize = 2;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;

    try expect(i == 1);
    try expect(try std.unicode.utf8ByteSequenceLength(s[i]) == 2);
    try expect(try std.unicode.utf8Decode2(s[i..][0..2].*) == 'é');
}

test "look ahead without consuming" {
    const view = try std.unicode.Utf8View.init("héllo");
    var it = view.iterator();

    // peek returns the bytes of the next n characters, and does not move the
    // cursor. Thus a parser can decide before it selects a branch.
    try expectEqualStrings("hé", it.peek(2));
    try expect(it.i == 0);

    try expect(it.nextCodepoint().? == 'h');
    try expectEqualStrings("él", it.peek(2));
}

test "a comptime view cannot fail" {
    // initComptime validates during compilation. Thus a literal needs no try,
    // and a malformed literal is a compile error, not a runtime branch.
    const view = comptime std.unicode.Utf8View.initComptime("héllo");
    var it = view.iterator();
    try expect(it.nextCodepoint().? == 'h');
}

test "print bytes you did not validate" {
    var buf: [64]u8 = undefined;

    // fmtUtf8 puts U+FFFD in place of ill-formed sequences, and does not fail.
    // A log line needs this behaviour for untrusted input.
    const broken = [_]u8{ 'a', 0xff, 'b' };
    const shown = try std.mem.print(&buf, "{f}", .{std.unicode.fmtUtf8(&broken)});
    try expectEqualStrings("a\u{FFFD}b", shown);
}

test "cross to UTF-16 and back" {
    const gpa = std.testing.allocator;
    const s = "héllo";

    // Each Windows path goes through this conversion. The unit counts are
    // different: five UTF-16 units and six UTF-8 bytes.
    const wide = try std.unicode.utf8ToUtf16LeAlloc(gpa, s);
    defer gpa.free(wide);
    try expect(wide.len == 5);
    try expect(s.len == 6);

    const back = try std.unicode.utf16LeToUtf8Alloc(gpa, wide);
    defer gpa.free(back);
    try expectEqualStrings(s, back);
}

test "a combining mark is two codepoints" {
    // The two strings show as one character. The second string is e and a
    // combining acute accent. Thus the codepoint count is 2, but a reader sees 1.
    const composed = "é";
    const decomposed = "e\u{301}";

    try expect(try std.unicode.utf8CountCodepoints(composed) == 1);
    try expect(try std.unicode.utf8CountCodepoints(decomposed) == 2);
    try expect(!std.mem.eql(u8, composed, decomposed));

    // Nothing in std normalizes the two strings to one form, or counts what a
    // reader calls a character. You need a Unicode library for that.
}
