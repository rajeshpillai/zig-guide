# Crypto

> Hashes, MACs, and constant-time comparison.

In Zig, a SHA-256 digest is one call to `std.crypto.hash.sha2.Sha256.hash`. To compare secrets such as MACs and tokens, use `std.crypto.timing_safe.eql`, not `std.mem.eql`. For passwords, use `std.crypto.pwhash`, not a plain hash.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.crypto`)*

Zig includes a large crypto library in `std.crypto`. The library has hashes, AEADs, key exchange and signatures, and it has no external dependency.

In most languages, cryptography means that you link OpenSSL or a similar library. That adds a build dependency, a version to monitor, and a large quantity of C. In Zig, the crypto code is in the standard library, and the code is Zig code. It cross-compiles to each target that your program compiles to.

## Select the correct tool

The names are difficult to learn. This table shows which problem each tool solves.

| You want | Use | Do not use |
| --- | --- | --- |
| A fingerprint of some data | `Sha256`, `Blake3` | a hash with "MD" or "SHA1" in its name |
| Proof that the data came from a person with the key | `hmac`, or an AEAD | a plain hash of key ++ data |
| Encryption, *and* detection of changes to the data | `aead` (`ChaCha20Poly1305`, `Aes256Gcm`) | a bare cipher |
| A stored password | `pwhash` (argon2) | any of the tools above |
| A fast hash for a hash map | `std.hash` | `std.crypto` |

Be careful with the last row. `std.hash` holds non-cryptographic hashes, for example Wyhash. They are much faster, and a hash table needs them.

Use `std.crypto.hash` when an attacker must not find two inputs with the same output. A crypto hash in a hash table is slow. A non-cryptographic hash is unsafe when an attacker can affect the data.

## One-shot and incremental

```zig
Sha256.hash(data, &digest, .{});          // one-shot

var hasher = Sha256.init(.{});            // incremental
hasher.update(part1);
hasher.update(part2);
hasher.final(&digest);
```

The two forms make the same digest. Use the incremental form when the input arrives in parts, or when the input is too large to hold in memory.

The digest is an array of fixed size: `[32]u8` for SHA-256. It contains raw bytes, not hex. To print it, use `{x}` or `std.fmt.bytesToHex`. To compare it with a hex string from a different source, convert one side. Do not compare the two values by eye.

## Constant-time comparison

```zig
std.crypto.timing_safe.eql([32]u8, a, b)
```

`std.mem.eql` returns when it finds the first difference. Thus its duration shows how many bytes matched. For MACs, tokens, and password hashes, this is a real attack. Use the timing-safe form for all secret data.

The steps of the attack make the danger clear:

1. The attacker sends tokens, and measures the time of each response.
2. The tokens are different only in the first byte.
3. One token takes slightly longer. Thus the attacker knows the first byte.
4. The attacker does the same for the second byte, and then for each next byte.

Thus 256^32 guesses become 32 × 256 guesses, which is a few thousand. The timing-safe version compares each byte on each call, and combines the results. Thus the duration gives no information.

## Passwords are a different problem

Do not hash passwords with SHA-256. `std.crypto.pwhash` supplies argon2, bcrypt, and scrypt. These functions are slow on purpose, and they use a salt. The slow speed is the feature: it makes an offline attack with many guesses expensive.

SHA-256 is fast by design. Usual hardware calculates billions of SHA-256 hashes each second. If a table of SHA-256 password hashes leaks, an attacker can get the passwords in some hours.

Argon2 has settings so that one hash takes a measurable part of a second and a set quantity of memory. Your login endpoint calculates one hash for each login, thus the cost is small. An attacker needs millions of guesses, thus the attacker's cost is millions of times larger.

The salt is the other half. The program stores the salt next to the hash, in the clear. The salt makes sure that two users with the same password get different hashes. Thus one precomputed table cannot crack the two hashes. `pwhash` makes and encodes the salt. This is the main reason to use `pwhash` and not to assemble the parts yourself.

## The limits of this page

This page does not give you enough information to design a protocol. The API for an AEAD does not tell you how to select a nonce. A bad nonce breaks the full construction.

Use a reviewed protocol when one exists. `std.crypto` gives implementations of primitives. It does not tell you how to combine them.
