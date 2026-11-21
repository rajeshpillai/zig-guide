# Slugs Are Arithmetic

> Base62 over the row id, and the validation that a redirect service needs.

The slug of a URL shortener can be the database row id in base62. Then each
slug is unique, and the service needs no collision check. The service must
check the target URL before it stores the URL, because a shortener is an open
redirect by design.

## The problem

The service needs a short name for each stored URL. One attractive design is a
random string. The service checks the string against the database for
collisions, and tries again if necessary.

A simpler design uses a value that the database already has. The database
gives each row a unique integer, the `bigserial` id. A slug that is only that
integer in a compact form is unique, because the ids are unique.

A compact form needs a larger base. Base 10 writes a billion as ten
characters. Base 62 uses the digits and both alphabets, and it writes a
billion as six characters.

## The plan

1. `encode`: divide the id by 62 again and again. Write one character for each
   remainder. The one-billionth link is still six characters.
2. `decode`: the opposite operation, for the redirect path. With the id, the
   lookup can use the primary key. Reject all characters outside the alphabet
   before they get to a query.
3. `checkTarget`: the targets that the service accepts for a redirect. This is
   security logic.

```zig
const std = @import("std");

// 62 characters that go through a URL without a change. They need no
// escaping, and they include no punctuation that looks like another
// character. Copy and paste does not change them.
const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// The row id, written in base 62. The database already makes sure that ids
/// are unique, thus the slugs are also unique. The code needs no random
/// value, collision check or retry loop. An id fits in 11 characters, also at
/// the u64 limit.
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

/// The opposite direction, for the redirect handler: from slug to id. With
/// the id, the database lookup can use the primary key. This function rejects
/// all characters outside the alphabet, before they get to a query.
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

/// The URLs that the service accepts. The scheme check is necessary. If a
/// redirect service stores `javascript:` URLs, it sends each visitor to code
/// from the person who sent the URL.
fn checkTarget(url: []const u8) !void {
    const has_scheme = std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://");
    if (!has_scheme) return error.SchemeNotAllowed;
    for (url) |ch| {
        // Control characters can let a stored URL smuggle bytes into the
        // HTTP response that redirects to it. A space makes the URL
        // invalid.
        if (ch <= ' ' or ch == 0x7f) return error.BadCharacter;
    }
}

pub fn main(init: std.process.Init) !void {
    var out_buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const out = &file_writer.interface;

    var buf: [11]u8 = undefined;

    // The mapping, at the sizes that a shortener actually gets.
    try out.writeAll("-- encode --\n");
    for ([_]u64{ 0, 7, 61, 62, 100_000, 1_000_000_000, std.math.maxInt(u64) }) |id| {
        try out.print("id {d} -> \"{s}\"\n", .{ id, encode(id, &buf) });
    }

    // The redirect route needs the encoding to be reversible. Thus the test
    // checks this property, and does not assume it.
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

## Why the scheme check is necessary

A shortener sends visitors to the targets of its stored URLs. Only the check
on the stored URLs stops attackers from the misuse of the shortener.

- A stored `javascript:` URL changes the redirect into script execution in the
  browser of the visitor.
- Control characters can let a stored URL smuggle extra bytes into the HTTP
  response that carries the redirect.

Thus the check allows exactly two schemes. It refuses the space, all characters
below the space, and DEL. The [routes chapter](https://www.ziglang.in/learn/url-shortener/routes/)
runs the check on create and also on update, before any code touches storage.

## What the id shows

If the slugs come from the sequence, there is one cost: a person can guess the
slugs. `4c92` tells any person that `4c91` probably exists. It also tells them
approximately how many links the service gave.

This project accepts that cost, because it is a demonstration of the
mechanism. Some services must have links that no person can guess, or must not
show their size. Such a service encodes a permutation of the id, not the id
itself. A permutation keeps the slugs unique and mixes the order. The change
stays inside these two functions.

## Variations

- **Sixty-two, not sixty-four:** base64 needs `+` and `/`, or the URL-safe
  replacements for them. Base62 uses two fewer characters, and its slugs stay
  correct after any copy and paste.
- **Case is important:** `q0U` and `Q0u` are different links. Suppose people
  read the links aloud on a phone. Then the shortener must not use the
  uppercase letters, and its slugs become approximately 15 percent longer.
