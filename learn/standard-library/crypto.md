# Crypto

> Hashes, MACs, and constant-time comparison.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "sha256" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abc", &digest, .{});

    // The well-known SHA-256 of "abc".
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
    // `std.mem.eql` short-circuits, which leaks how much matched via timing.
    try expect(std.crypto.timing_safe.eql([3]u8, a, b));
}

test "hmac" {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, "message", "key");
    try expect(mac.len == 32);
}

test "password hashing is deliberately slow" {
    // bcrypt/scrypt/argon2 are the right tools for passwords; a bare hash
    // is not. They are omitted from this runnable example precisely because
    // they are designed to take a long time.
    try expect(@hasDecl(std.crypto.pwhash, "argon2"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.crypto`)*

Zig ships a substantial crypto library in `std.crypto` (hashes, AEADs, key
exchange, signatures) with no external dependency.

That last part matters more than it sounds. In most languages, doing anything
cryptographic means linking OpenSSL or an equivalent, which is a build
dependency, a version to track, and a large amount of C. Here it is in the
standard library, written in Zig, and it cross-compiles wherever your program
does.

## Picking the right tool

The names are dense, so it is worth being clear about which problem each
solves.

| You want | Use | Not |
| --- | --- | --- |
| A fingerprint of some data | `Sha256`, `Blake3` | anything with "MD" or "SHA1" in it |
| To prove data came from someone with the key | `hmac`, or an AEAD | a plain hash of key ++ data |
| To encrypt *and* detect tampering | `aead` (`ChaCha20Poly1305`, `Aes256Gcm`) | a bare cipher |
| To store a password | `pwhash` (argon2) | any of the above |
| Fast hashing for a hash map | `std.hash` | `std.crypto` |

The last row is a real distinction. `std.hash` holds non-cryptographic hashes
like Wyhash, which are much faster and are what a hash table wants.
`std.crypto.hash` is for when an attacker must not be able to find two inputs
with the same output. Using the wrong one is slow in one direction and unsafe
in the other.

## One-shot and incremental

```zig
Sha256.hash(data, &digest, .{});          // one-shot

var hasher = Sha256.init(.{});            // incremental
hasher.update(part1);
hasher.update(part2);
hasher.final(&digest);
```

Both produce the same digest; use the incremental form when the input arrives
in pieces or is too large to hold at once.

The digest is a fixed-size array, `[32]u8` for SHA-256, and it is raw bytes
rather than hex. Printing it needs `{x}` or `std.fmt.bytesToHex`, and
comparing it against a hex string from elsewhere means converting one side,
not eyeballing the two.

## Constant-time comparison

```zig
std.crypto.timing_safe.eql([32]u8, a, b)
```

`std.mem.eql` returns as soon as it finds a difference, so how long it took
reveals how many bytes matched. For MACs, tokens, and password hashes that is
a real attack. Use the timing-safe form for anything secret.

The attack is easier to believe once you see the shape of it. An attacker who
can submit guesses and measure the response time submits tokens differing in
the first byte. When one takes marginally longer, they have learned that byte,
and they move to the second. That turns 256^32 guesses into 32 × 256, which is
a few thousand. The timing-safe version compares every byte every time and
combines the results, so the duration says nothing.

## Passwords are a different problem

Do not hash passwords with SHA-256. `std.crypto.pwhash` provides argon2,
bcrypt, and scrypt, which are deliberately slow and salted. That slowness is
the feature: it is what makes an offline guessing attack expensive.

SHA-256 is designed to be fast, and commodity hardware computes billions per
second. A leaked table of SHA-256 password hashes is a table of passwords
within hours. Argon2 is tuned so that one hash takes a measurable fraction of
a second and a set amount of memory. That costs your login endpoint nothing.
It costs an attacker running millions of guesses everything.

The salt is the other half. It is stored next to the hash, in the clear. Its
job is to make sure two users with the same password get different hashes, so
one precomputed table cannot crack both. `pwhash` handles generating and
encoding it, which is the main reason to use it rather than assembling the
pieces.

## What this page is not

Enough to design a protocol. Knowing the API for an AEAD does not tell you how
to choose a nonce, and choosing one badly breaks the whole construction. Use a
reviewed protocol where one exists, and treat `std.crypto` as the
implementation of primitives rather than as advice about how to combine them.
