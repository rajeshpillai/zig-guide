//! title: Crypto
//! Hashes, MACs, and constant-time comparison.

const std = @import("std");
const expect = std.testing.expect;

test "sha256" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abc", &digest, .{});

    // The SHA-256 of "abc", a well-known test value.
    var hex: [64]u8 = undefined;
    const text = try std.mem.print(&hex, "{x}", .{digest});
    try expect(std.mem.startsWith(u8, text, "ba7816bf"));
}

test "incremental hashing" {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("a");
    hasher.update("bc");

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var one_shot: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abc", &one_shot, .{});
    try expect(std.mem.eql(u8, &digest, &one_shot));
}

test "compare secrets in constant time" {
    const a = [_]u8{ 1, 2, 3 };
    const b = [_]u8{ 1, 2, 3 };
    // `std.mem.eql` stops at the first difference. Thus its duration shows
    // how many bytes matched.
    try expect(std.crypto.timing_safe.eql([3]u8, a, b));
}

test "hmac" {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, "message", "key");
    try expect(mac.len == 32);
}

test "password hashing is deliberately slow" {
    // Use bcrypt, scrypt or argon2 for passwords. Do not use a bare hash.
    // This example does not run them, because they are slow by design.
    try expect(@hasDecl(std.crypto.pwhash, "argon2"));
}
