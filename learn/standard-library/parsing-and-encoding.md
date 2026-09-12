# Parsing and Encoding

> Text to numbers, and bytes to hex or base64.

```zig
const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

test "parseInt" {
    try expect(try std.fmt.parseInt(i32, "-42", 10) == -42);

    // Base 0 reads the prefix like a Zig literal: 0x, 0o, 0b, or decimal.
    try expect(try std.fmt.parseInt(u32, "0xff", 0) == 255);
    try expect(try std.fmt.parseInt(u32, "0b1010", 0) == 10);

    // Underscore separators are accepted, like Zig literals.
    try expect(try std.fmt.parseInt(u32, "1_000_000", 10) == 1_000_000);
}

test "parse failures are errors, not zeros" {
    try expectError(error.InvalidCharacter, std.fmt.parseInt(u8, "12a", 10));
    // The target type bounds the parse: 300 does not fit in a u8.
    try expectError(error.Overflow, std.fmt.parseInt(u8, "300", 10));
}

test "parseFloat" {
    try expect(try std.fmt.parseFloat(f64, "3.25") == 3.25);
    try expect(try std.fmt.parseFloat(f64, "-1e-3") == -0.001);
    try expect(std.math.isInf(try std.fmt.parseFloat(f32, "inf")));
}

test "hex" {
    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };

    // bytesToHex returns a fixed-size array: the length is known at
    // compile time from the input, so no allocator is needed.
    const hex = std.fmt.bytesToHex(bytes, .lower);
    try expectEqualStrings("deadbeef", &hex);

    var back: [4]u8 = undefined;
    _ = try std.fmt.hexToBytes(&back, "deadbeef");
    try expect(std.mem.eql(u8, &back, &bytes));
}

test "base64" {
    const codec = std.base64.standard;

    var enc_buf: [16]u8 = undefined;
    const encoded = codec.Encoder.encode(&enc_buf, "zig");
    try expectEqualStrings("emln", encoded);

    var dec_buf: [16]u8 = undefined;
    const n = try codec.Decoder.calcSizeForSlice(encoded);
    try codec.Decoder.decode(dec_buf[0..n], encoded);
    try expectEqualStrings("zig", dec_buf[0..n]);
}

test "url_safe base64 for tokens and file names" {
    // standard base64 emits + and /, which break URLs and paths.
    const bytes = [_]u8{ 0xfb, 0xff };
    var buf: [8]u8 = undefined;
    try expectEqualStrings("+/8=", std.base64.standard.Encoder.encode(&buf, &bytes));
    try expectEqualStrings("-_8=", std.base64.url_safe.Encoder.encode(&buf, &bytes));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.parsing-and-encoding`)*

## Parsing is fallible, and says so

`std.fmt.parseInt` returns an error union, so a bad character or an
out-of-range value is a value you handle, never a silent zero. The target type
is the bound: `parseInt(u8, "300", 10)` is `error.Overflow` because 300 does
not fit. Passing base `0` reads the prefix the way a Zig literal would: `0x`,
`0o`, `0b`, or decimal, underscores allowed.

The two errors are worth distinguishing when reporting to a user.
`error.InvalidCharacter` means the text was not a number at all;
`error.Overflow` means it was a number and the type is too small. A config
parser that says "port must be a number" for `70000` is unhelpful, and the
error already told you which it was.

The target type doing the bounds checking is the useful part. There is no
separate range validation to write and no chance of it disagreeing with the
field it feeds, because the field's type *is* the range. Parsing into `u16`
for a port number rejects 70000 without a line of code.

`parseFloat` accepts the usual decimal and scientific forms plus `inf` and
`nan`.

Both parse the *whole* string, so trailing whitespace or a stray newline is an
error rather than being ignored. Trim first with `std.mem.trim` when the input
comes from a file or a terminal, which is nearly always.

## Hex

`bytesToHex` returns a fixed-size array, not a slice, because the output
length is known from the input at compile time. That means no allocator and no
failure path. `hexToBytes` goes the other way into a caller-provided buffer.

It takes a case argument, `.lower` or `.upper`, so there is no ambiguity about
what a digest will look like. Decoding accepts either.

Because the return is an array rather than a slice, take a reference when
passing it somewhere that wants `[]const u8`. A temporary needs a `const`
binding first, since otherwise there is nothing to point at.

For formatting bytes inline rather than converting them, `{x}` on a byte slice
does the same job directly inside a `print`.

## base64: pick the alphabet for the destination

`std.base64.standard` uses `+` and `/`, which are fine in a MIME body and
wrong in a URL or a file name. `std.base64.url_safe` swaps them for `-` and
`_`. Both expose an `Encoder` and a `Decoder`; decoding is fallible because
the input might not be valid base64. Size the destination with
`Decoder.calcSizeForSlice` before decoding.

| Codec | Emits | Use for |
| --- | --- | --- |
| `standard` | `A-Za-z0-9+/` | MIME, email, data URIs |
| `url_safe` | `A-Za-z0-9-_` | URLs, file names, tokens |
| `*_no_pad` | above, no `=` | fixed-width IDs |

Sizing is the step people skip, and it does not fail loudly if you guess. On
the encoding side, `Encoder.calcSize(n)` gives the exact output length, which
is 4 bytes for every 3 input bytes, rounded up and padded. On the decoding
side, `calcSizeForSlice` inspects the padding to give the exact answer, and
`calcSizeUpperBound` gives a safe over-estimate when you want to allocate
before looking. Both return an error for input that cannot be valid base64 at
all.

`encodeWriter` writes straight to a `std.Io.Writer`, so encoding a large
payload into a response needs no intermediate buffer.

Base64 is not encryption and not compression. It makes arbitrary bytes safe to
put in a text field, and it costs a third more space to do it.
