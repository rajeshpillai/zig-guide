//! title: Parsing and Encoding
//! Text to numbers, bytes to hex and base64, and back.

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
