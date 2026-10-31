# Unicode Recipes

> Truncate on a character boundary, decode one codepoint, and convert to UTF-16.

To truncate a UTF-8 string in Zig without a cut through a character, walk `nextCodepointSlice`. Stop before the slice that goes past the limit. To convert to and from UTF-16, use `std.unicode.utf8ToUtf16LeAlloc` and `utf16LeToUtf8Alloc`.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.unicode-recipes`)*

## Length from the first byte

UTF-8 puts the sequence length in the lead byte. Thus you can decode one character, and you do not have to scan forward to find the start of the next character. `utf8ByteSequenceLength` reads the length. `utf8Decode2`, `utf8Decode3` or `utf8Decode4` changes those bytes into a `u21`.

The length is in the name because each of those functions takes an array of fixed size. An older version had one `utf8Decode` that took a slice, and that function is now deprecated. It asserted that the length matched the lead byte, and it could not tell you when the length did not match. The new way is to get the length first and then decode that number of bytes. It is the same work, and the design prevents the mistake.

If you give `utf8ByteSequenceLength` a continuation byte, it returns `error.Utf8InvalidStartByte`. You want this check when an index comes from arithmetic and not from an iterator. `utf8CodepointSequenceLength` does the opposite work for the encoder. Use it to get the number of bytes that a codepoint needs, before you calculate the size of the buffer.

## Cut a string safely

The [Unicode](https://www.ziglang.in/learn/standard-library/unicode/) chapter says to iterate over codepoint slices and stop at the last full character. This chapter shows that function:

1. Walk `nextCodepointSlice`.
2. Keep the end offset of the characters so far.
3. Stop before the first slice that would put the end past the limit.

The simple `s[0..max]` gives invalid UTF-8 when the cut is in the middle of a character. Nothing fails at the cut. The failure occurs where code decodes those bytes, possibly in a different program.

## Which character contains byte 7

The standard library has no helper for this, thus you must write it. All continuation bytes match `0b10xxxxxx`. Thus, walk back while `(b & 0xC0) == 0x80`. The walk stops on the start byte of the character that contains the byte.

You can remember this rule, and you do not need to look for it. A UTF-8 character is a maximum of four bytes. The design of the format makes sure that this walk is always short and never ambiguous.

## Look ahead, and views that cannot fail

`Utf8Iterator.peek(n)` returns the bytes of the next `n` characters, and does not move the cursor. A parser needs this before it selects a branch.

`Utf8View.initComptime` validates the bytes during compilation. A literal needs no `try`. A malformed literal is a compile error, not a runtime path that you must handle.

## Bytes that you did not validate

`std.unicode.fmtUtf8` prints ill-formed input with U+FFFD in place of the bad sequences. It does not return an error. A log line almost always needs this behaviour. When you debug bad input, you still need to see the input in the output.

## UTF-16 is for Windows

Windows paths are UTF-16. Thus each cross-platform program uses `utf8ToUtf16LeAlloc` and `utf16LeToUtf8Alloc` at that boundary. The counts of UTF-16 units are different from the byte counts. Because of that difference, the conversion is explicit and never automatic.

## What std does not do

The standard library has no support for grapheme clusters, no display width, no case folding, no normalization, and no case mapping above ASCII. A hand-written loop cannot solve this problem.

`é` can be one codepoint or two codepoints, and the two forms are not equal. To decide that they are the same string, you need the Unicode tables. Those tables are large, and they change with each Unicode revision. They belong in a library.

[zg](https://codeberg.org/atman/zg) by Sam Atman is the library to use. It divides the work into separate modules: graphemes, display width, letter case, case folding, normalization, word breaks, scripts, and emoji. Thus a program pays only for the tables that it uses. Codeberg is the upstream, not a mirror.
