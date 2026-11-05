# Parsing and Encoding

> Text to numbers, and bytes to hex or base64.

In Zig, `std.fmt.parseInt(T, text, base)` changes a string into an integer. It returns an error when the text is not a number, or when the number is too large for `T`. `std.fmt.bytesToHex` changes bytes into hex, and the codecs in `std.base64` change bytes into base64.

```zig
const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

test "parseInt" {
    try expect(try std.fmt.parseInt(i32, "-42", 10) == -42);

    // Base 0 reads the prefix as a Zig literal does: 0x, 0o, 0b, or decimal.
    try expect(try std.fmt.parseInt(u32, "0xff", 0) == 255);
    try expect(try std.fmt.parseInt(u32, "0b1010", 0) == 10);

    // The function accepts underscore separators, as Zig literals do.
    try expect(try std.fmt.parseInt(u32, "1_000_000", 10) == 1_000_000);
}

test "parse failures are errors, not zeros" {
    try expectError(error.InvalidCharacter, std.fmt.parseInt(u8, "12a", 10));
    // The target type sets the limit: 300 is too large for a u8.
    try expectError(error.Overflow, std.fmt.parseInt(u8, "300", 10));
}

test "parseFloat" {
    try expect(try std.fmt.parseFloat(f64, "3.25") == 3.25);
    try expect(try std.fmt.parseFloat(f64, "-1e-3") == -0.001);
    try expect(std.math.isInf(try std.fmt.parseFloat(f32, "inf")));
}

test "hex" {
    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };

    // bytesToHex returns an array of fixed size. The input gives the length
    // at compile time, thus the function needs no allocator.
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
    // Standard base64 emits + and /. These characters break URLs and paths.
    const bytes = [_]u8{ 0xfb, 0xff };
    var buf: [8]u8 = undefined;
    try expectEqualStrings("+/8=", std.base64.standard.Encoder.encode(&buf, &bytes));
    try expectEqualStrings("-_8=", std.base64.url_safe.Encoder.encode(&buf, &bytes));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.parsing-and-encoding`)*

## A parse can fail, and the type shows it

`std.fmt.parseInt` returns an error union. Thus a bad character or a value out of range is a value that you must handle. It is never a silent zero.

The target type sets the limit. `parseInt(u8, "300", 10)` gives `error.Overflow`, because 300 is too large for a `u8`. With base `0`, the function reads the prefix as a Zig literal does: `0x`, `0o`, `0b`, or decimal. The function also accepts underscores.

Give a user a different report for each of the two errors:

- `error.InvalidCharacter` means that the text was not a number.
- `error.Overflow` means that the text was a number, but the type is too small.

A config parser that says "port must be a number" for `70000` does not help the user. The error already told you which problem occurred.

The target type does the bounds check, thus you do not write a separate range check. The check cannot disagree with the field that gets the value, because the type of the field *is* the range. A parse into `u16` for a port number rejects 70000, and you write no code for that check.

`parseFloat` accepts the usual decimal and scientific forms. It also accepts `inf` and `nan`.

The two functions parse the *full* string. Thus whitespace at the end or an unwanted newline causes an error. The function does not ignore the whitespace. When the input comes from a file or a terminal, remove the whitespace first with `std.mem.trim`. Input usually comes from one of these two places.

## Hex

`bytesToHex` returns an array of fixed size, not a slice. The reason is that the input gives the output length at compile time. Thus the function needs no allocator, and it cannot fail. `hexToBytes` does the opposite operation into a buffer that the caller supplies.

The function takes a case argument, `.lower` or `.upper`. Thus the format of a digest is always clear. The decoder accepts the two cases.

The return value is an array and not a slice. Thus, when a function needs a `[]const u8`, give it a reference to the array. A temporary value needs a `const` binding first, because without the binding there is nothing for the pointer to point at.

If you want to format the bytes in the output and not change them into a different value, use `{x}` on a byte slice. The format specifier does the same work directly in a `print`.

## base64: select the alphabet for the destination

`std.base64.standard` uses `+` and `/`. These characters are correct in a MIME body, but they are incorrect in a URL or a file name. `std.base64.url_safe` uses `-` and `_` in place of them.

Each codec has an `Encoder` and a `Decoder`. The decoder can fail, because the input can be invalid base64. Before you decode, calculate the size of the destination with `Decoder.calcSizeForSlice`.

| Codec | Emits | Use for |
| --- | --- | --- |
| `standard` | `A-Za-z0-9+/` | MIME, email, data URIs |
| `url_safe` | `A-Za-z0-9-_` | URLs, file names, tokens |
| `*_no_pad` | above, no `=` | fixed-width IDs |

People frequently do not calculate the size, and an incorrect guess does not cause a clear failure. Use these functions:

- To encode, use `Encoder.calcSize(n)`. It gives the exact output length: 4 bytes for each 3 input bytes, rounded up and padded.
- To decode, use `calcSizeForSlice`. It examines the padding and gives the exact answer.
- To allocate before you examine the input, use `calcSizeUpperBound`. It gives a safe value that can be too large.

The two decoder functions return an error for input that cannot be valid base64.

`encodeWriter` writes directly to a `std.Io.Writer`. Thus, when you encode a large payload into a response, you need no buffer between the two steps.

Base64 is not encryption, and it is not compression. It makes any bytes safe in a text field, and the result is one third larger.
