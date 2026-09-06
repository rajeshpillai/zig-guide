# Slugs Are Arithmetic

> Base62 over the row id, and the validation that keeps a redirect service honest.

## The problem

The service needs a short name for every stored URL. The tempting
design is a random string, checked against the database for collisions
and retried. The better design is no design at all: the database
already hands every row a unique integer, the `bigserial` id. A slug
that is just that integer written compactly is unique because ids are,
with no collision check anywhere.

Compact means a bigger base. Base 10 writes a billion as ten
characters; base 62, using the digits and both alphabets, writes it as
six.

## The plan

1. `encode`: divide the id by 62 repeatedly, emitting one character per
   remainder. The one-billionth link is still six characters.
2. `decode`: the reverse, for the redirect path, so the lookup can use
   the primary key. Reject anything outside the alphabet before it
   reaches a query.
3. `checkTarget`: what the service will agree to redirect to. This is
   security logic, not tidiness.

```zig
const std = @import("std");

// 62 characters that survive a URL untouched: no escaping, no lookalike
// punctuation, nothing a copy-paste can mangle.
const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// The row id, rewritten in base 62. The database already guarantees ids
/// are unique, so the slugs are too: no random draw, no collision check,
/// no retry loop. An id fits in 11 characters even at the u64 limit.
fn encode(id: u64, buf: *[11]u8) []const u8 {
    var rest = id;
    var i: usize = buf.len;
    while (true) {
        i -= 1;
        buf[i] = alphabet[@intCast(rest % 62)];
        rest /= 62;
        if (rest == 0) break;
    }
    return buf[i..];
}

/// The other direction, for the redirect handler: slug back to id, so
/// the database lookup can use the primary key. Anything outside the
/// alphabet is rejected here, before it gets near a query.
fn decode(slug: []const u8) !u64 {
    if (slug.len == 0 or slug.len > 11) return error.BadSlug;
    var id: u64 = 0;
    for (slug) |ch| {
        const digit = std.mem.findScalar(u8, alphabet, ch) orelse
            return error.BadSlug;
        id = try std.math.add(u64, try std.math.mul(u64, id, 62), digit);
    }
    return id;
}

/// What the service will shorten. The scheme check is not pedantry: a
/// redirect service that stores `javascript:` URLs hands every visitor
/// to whoever submitted one.
fn checkTarget(url: []const u8) !void {
    const has_scheme = std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://");
    if (!has_scheme) return error.SchemeNotAllowed;
    for (url) |ch| {
        // Control characters would let a stored URL smuggle bytes into
        // the HTTP response that redirects to it; a space is just broken.
        if (ch <= ' ' or ch == 0x7f) return error.BadCharacter;
    }
}

pub fn main(init: std.process.Init) !void {
    var out_buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const out = &file_writer.interface;

    var buf: [11]u8 = undefined;

    // The mapping, at the sizes a shortener actually sees.
    try out.writeAll("-- encode --\n");
    for ([_]u64{ 0, 7, 61, 62, 100_000, 1_000_000_000, std.math.maxInt(u64) }) |id| {
        try out.print("id {d} -> \"{s}\"\n", .{ id, encode(id, &buf) });
    }

    // Reversibility is the property the redirect route depends on, so
    // check it rather than trust it.
    for ([_]u64{ 0, 1, 61, 62, 3843, 1 << 20, 1 << 40, std.math.maxInt(u64) }) |sample| {
        if (try decode(encode(sample, &buf)) != sample) return error.RoundtripBroken;
    }
    try out.writeAll("\nroundtrip: decode(encode(id)) == id held for every size tried\n");

    try out.writeAll("\n-- decode rejects --\n");
    for ([_][]const u8{ "zig_1", "", "zzzzzzzzzzzz" }) |slug| {
        _ = decode(slug) catch |err| {
            try out.print("\"{s}\" -> {t}\n", .{ slug, err });
        };
    }

    try out.writeAll("\n-- target validation --\n");
    const targets = [_][]const u8{
        "https://ziglang.org/download/",
        "http://old-but-fine.example",
        "javascript:alert(1)",
        "https://zig lang.org",
        "ziglang.org",
    };
    for (targets) |t| {
        if (checkTarget(t)) {
            try out.print("ok      {s}\n", .{t});
        } else |err| {
            try out.print("{t}: {s}\n", .{ err, t });
        }
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`22-url-shortener.slugs`)*

## Why the scheme check is not pedantry

A shortener is an open redirect by design: it sends visitors wherever
its stored URLs point. The only thing keeping that from being a weapon
is what it agrees to store. A stored `javascript:` URL turns the
redirect into script execution in the visitor's browser. Control
characters could let a stored URL smuggle extra bytes into the HTTP
response that carries the redirect. So the check allows exactly two
schemes and refuses anything below a space, and the
[routes chapter](https://www.ziglang.in/learn/url-shortener/routes/) runs it on create and
update both, before anything touches storage.

## What the id leaks

Deriving slugs from the sequence has one honest cost: slugs are
guessable. `4c92` tells anyone that `4c91` probably exists, and roughly
how many links the service has issued. This project accepts that
because it is a demonstration, built to show the mechanism; a service
whose links must be unguessable, or that should not leak its own size,
encodes a permutation of the id rather than the id itself, keeping
uniqueness while scrambling the order. The seam stays exactly here, in
these two functions.

## Variations

- **Sixty-two, not sixty-four:** base64 needs `+` and `/` or their
  URL-safe stand-ins. Base62 spends two characters to produce slugs
  that survive any copy-paste untouched.
- **Case matters:** `q0U` and `Q0u` are different links. A shortener
  that wants to be shouted over a phone drops the uppercase half and
  pays with slugs a third longer.
