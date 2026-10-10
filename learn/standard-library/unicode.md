# Unicode

> A string is bytes until you opt in to UTF-8.

In Zig, a string is a slice of bytes, and UTF-8 handling is opt-in through
`std.unicode`, where `Utf8View` validates the bytes and iterates code points.
Grapheme clusters, case folding and normalisation are not in the standard
library.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.unicode`)*

## `len` is bytes

`"héllo".len` is 6, not 5, because `é` encodes to two bytes. Nothing in the
language layer knows about UTF-8. Source files are required to be valid UTF-8,
but a `[]const u8` at runtime is just bytes. When you need character counts,
`std.unicode.utf8CountCodepoints` walks the encoding.

This is a design decision rather than an omission. Most code that handles text
never needs to know where the character boundaries are. Copying, hashing,
comparing for equality, writing to a socket and searching for a substring all
work on bytes, and are faster and simpler for it. The cases that really need
characters are a minority, and they ask for the UTF-8 code explicitly.

## Three different lengths

The word "length" has three answers. Confusing them is a common source of
bugs.

- **Bytes.** What `.len` gives you. This is what you need for buffers, offsets
  and anything written to a file.
- **Code points.** What `utf8CountCodepoints` gives you. One Unicode value,
  encoded in one to four bytes.
- **Grapheme clusters.** What a person calls a character. A letter plus its
  combining accent is two code points and one character, and an emoji with a
  skin-tone modifier can be several.

The standard library gives you the first two. Grapheme clustering needs
Unicode tables that `std` does not ship. So "how many characters will this
occupy on screen" is a question for a library. Terminal width is a fourth,
separate answer.

## Validate once, then iterate

`Utf8View.init` checks the whole slice up front and returns an error for
malformed input. After that, its iterator cannot fail, so the loop body stays
clean. `nextCodepoint` yields `u21` values. `nextCodepointSlice` yields the
raw bytes of each character. Use it when you are slicing the original string
at character boundaries.

For input you do not control (network data, file contents), run
`utf8ValidateSlice` before treating bytes as text.

Validate once, then iterate with no error path. Copy this pattern elsewhere.
The alternative is to check for malformed input at every step. That puts an
error path in the middle of every loop, for a condition that was already
decided when the bytes arrived.

`utf8ByteSequenceLength` reads the first byte and tells you how many bytes the
code point occupies. All of the above is built on it, and sometimes you want
it directly when scanning backwards.

## Slicing can cut a character in half

`s[0..2]` on `"héllo"` produces one valid byte followed by half of `é`. Byte
indices from `std.mem.find` (`indexOf` in older code) are always safe cut
points when the needle itself is valid UTF-8, but arbitrary arithmetic on
indices is not. If you truncate strings for display, iterate codepoint slices
and stop at the last full character.

[Unicode Recipes](https://www.ziglang.in/learn/standard-library/unicode-recipes/) writes that
function out, and covers finding the character that contains a given byte,
which std has no helper for.

## What is not in std

There is no case folding, no locale-aware comparison, no normalisation and no
collation in the standard library. `std.ascii.toLower` exists and does exactly
what its name says: ASCII only. That is correct for protocol keywords and
wrong for text in most languages.

The reason is size. Doing case conversion properly means shipping Unicode
tables. The rules also depend on the language, in unexpected ways: Turkish
dotless i, German sharp s, Greek final sigma. Zig's position is that a
program which needs this should depend on a library that keeps the tables
current. The alternative is a stale copy inside every binary that links `std`.

For comparing user-supplied text, that means deciding what you actually need.
Byte equality is right for identifiers and tokens. Anything involving "the
same word typed differently" needs normalisation, and that needs a library.
