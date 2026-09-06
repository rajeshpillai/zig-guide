# Unicode Recipes

> Truncate on a character boundary, decode one codepoint, and cross to UTF-16.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.unicode-recipes`)*

## Length from the first byte

UTF-8 puts the sequence length in the leading byte, so one character can be
decoded without scanning forward to find where the next one starts.
`utf8ByteSequenceLength` reads it, and `utf8Decode2`, `utf8Decode3` or
`utf8Decode4` turns those bytes into a `u21`.

The length is in the name because each of those takes a fixed-size array.
There used to be one `utf8Decode` taking a slice, and it is deprecated. It
asserted that the length matched the leading byte, and had no way to tell you
when it did not. Asking for the length first and then decoding that many bytes
is the same work with the mistake designed out.

Handing it a continuation byte returns `error.Utf8InvalidStartByte`, which is
the check you want when an index came from arithmetic rather than an iterator.
`utf8CodepointSequenceLength` is the mirror on the encode side: ask how many
bytes a codepoint needs before you size the buffer.

## Cutting a string safely

The [Unicode](https://www.ziglang.in/learn/standard-library/unicode/) chapter says to iterate
codepoint slices and stop at the last full character. This is that function,
written out: walk `nextCodepointSlice`, keep a running end offset, and stop
before the first slice that would push you past the limit.

The naive `s[0..max]` produces invalid UTF-8 whenever the cut lands mid
character, and nothing about it fails at the time. It fails wherever the bytes
end up.

## Which character is byte 7 in

There is no std helper for this, so you write it. Continuation bytes all match
`0b10xxxxxx`, so walking back while `(b & 0xC0) == 0x80` lands on the start
byte of the character you were inside.

Worth knowing rather than looking up, because it is four bytes of the format
doing the work: UTF-8 was designed so this walk is always short and never
ambiguous.

## Peeking, and views that cannot fail

`Utf8Iterator.peek(n)` returns the bytes of the next `n` characters and leaves
the cursor where it was, which is what a parser needs before it commits to a
branch.

`Utf8View.initComptime` validates during compilation. A literal needs no
`try`, and a malformed one is a compile error rather than a runtime path you
have to handle.

## Bytes you did not validate

`std.unicode.fmtUtf8` prints ill-formed input with U+FFFD substituted for the
bad sequences instead of returning an error. That is almost always what a log
line wants: refusing to print the thing you are trying to debug is the wrong
failure mode.

## UTF-16 is the Windows story

Windows paths are UTF-16, so `utf8ToUtf16LeAlloc` and `utf16LeToUtf8Alloc` are
the boundary every cross-platform program crosses. The unit counts differ from
the byte counts, which is the whole reason the conversion is explicit rather
than automatic.

## What std does not do

There is no grapheme-cluster support, no display width, no case folding, no
normalization, and no case mapping past ASCII. This is not an oversight to
route around with a loop. `é` can be one codepoint or two, they compare
unequal, and deciding they are the same string needs the Unicode tables. Those
tables are large, they change with each Unicode revision, and they belong in a
library.

[zg](https://codeberg.org/atman/zg) by Sam Atman is the one to reach for. It
splits the work into separate modules (graphemes, display width, letter
casing, case folding, normalization, word breaks, scripts, emoji) so a program
only pays for the tables it actually uses. Codeberg is upstream, not a mirror.
