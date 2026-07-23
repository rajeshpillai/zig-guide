//! title: Parsing and Encoding
//! Text to numbers, bytes to hex and base64, and back.

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
