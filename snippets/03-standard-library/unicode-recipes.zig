//! title: Unicode Recipes
//! Truncate on a character boundary, decode one codepoint, and cross to UTF-16.

const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "length from the first byte" {
    const s = "héllo";

    // The leading byte says how long the sequence is, so one character can be
    // decoded without scanning forward for the next boundary.
    try expect(try std.unicode.utf8ByteSequenceLength(s[0]) == 1);
    try expect(try std.unicode.utf8ByteSequenceLength(s[1]) == 2);

    // Decode with the function for that length. The slice-taking utf8Decode is
    // deprecated: it asserted the length matched and had no way to say so.
    try expect(try std.unicode.utf8Decode2(s[1..3].*) == 'é');

    // A continuation byte is not a start byte, and asking says so.
    try std.testing.expectError(error.Utf8InvalidStartByte, std.unicode.utf8ByteSequenceLength(s[2]));
}

test "how many bytes will this codepoint need" {
    // The encode-side mirror: ask before you size a buffer.
    try expect(try std.unicode.utf8CodepointSequenceLength('a') == 1);
    try expect(try std.unicode.utf8CodepointSequenceLength('é') == 2);
    try expect(try std.unicode.utf8CodepointSequenceLength('€') == 3);
}

/// Cut `s` to at most `max_bytes`, stopping at the last whole character rather
/// than in the middle of one. std has no function for this.
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

    // Byte 2 lands inside the e-acute. The naive cut produces invalid UTF-8.
    try expect(!std.unicode.utf8ValidateSlice(s[0..2]));

    // truncate backs up to the last whole character instead.
    try expectEqualStrings("h", truncate(s, 2));
    try expect(std.unicode.utf8ValidateSlice(truncate(s, 2)));

    try expectEqualStrings("hé", truncate(s, 3));
    try expectEqualStrings("héllo", truncate(s, 99));
}

test "find the character that contains byte 2" {
    const s = "héllo";

    // Continuation bytes are 0b10xxxxxx. Walk back while you are on one and you
    // land on the start byte of the character you are inside.
    var i: usize = 2;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;

    try expect(i == 1);
    try expect(try std.unicode.utf8ByteSequenceLength(s[i]) == 2);
    try expect(try std.unicode.utf8Decode2(s[i..][0..2].*) == 'é');
}

test "look ahead without consuming" {
    const view = try std.unicode.Utf8View.init("héllo");
    var it = view.iterator();

    // peek returns the bytes of the next n characters and leaves the cursor
    // where it was, so a parser can decide before it commits.
    try expectEqualStrings("hé", it.peek(2));
    try expect(it.i == 0);

    try expect(it.nextCodepoint().? == 'h');
    try expectEqualStrings("él", it.peek(2));
}

test "a comptime view cannot fail" {
    // initComptime validates during compilation, so a literal needs no try and
    // a malformed one is a compile error rather than a runtime branch.
    const view = comptime std.unicode.Utf8View.initComptime("héllo");
    var it = view.iterator();
    try expect(it.nextCodepoint().? == 'h');
}

test "print bytes you did not validate" {
    var buf: [64]u8 = undefined;

    // fmtUtf8 substitutes U+FFFD for ill-formed sequences instead of failing,
    // which is what a log line wants from untrusted input.
    const broken = [_]u8{ 'a', 0xff, 'b' };
    const shown = try std.mem.print(&buf, "{f}", .{std.unicode.fmtUtf8(&broken)});
    try expectEqualStrings("a\u{FFFD}b", shown);
}

test "cross to UTF-16 and back" {
    const gpa = std.testing.allocator;
    const s = "héllo";

    // Every Windows path goes through this. The unit counts differ: five UTF-16
    // units against six UTF-8 bytes.
    const wide = try std.unicode.utf8ToUtf16LeAlloc(gpa, s);
    defer gpa.free(wide);
    try expect(wide.len == 5);
    try expect(s.len == 6);

    const back = try std.unicode.utf16LeToUtf8Alloc(gpa, wide);
    defer gpa.free(back);
    try expectEqualStrings(s, back);
}

test "a combining mark is two codepoints" {
    // Both render as one character. The second spells it as e plus a combining
    // acute accent, so counting codepoints gives 2 where a reader sees 1.
    const composed = "é";
    const decomposed = "e\u{301}";

    try expect(try std.unicode.utf8CountCodepoints(composed) == 1);
    try expect(try std.unicode.utf8CountCodepoints(decomposed) == 2);
    try expect(!std.mem.eql(u8, composed, decomposed));

    // Nothing in std normalizes these to each other, or counts what a reader
    // would call a character. That is what a Unicode library is for.
}
