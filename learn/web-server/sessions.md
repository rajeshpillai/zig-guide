# Cookies and Sessions

> A cookie is a string the client stores and hands back. Everything else is policy.

HTTP has no memory. Each request arrives with no idea that another one came
before it, which is the property that lets a server be restarted, replicated
and load-balanced without anybody noticing.

A cookie is the smallest possible patch over that. The server sends
`Set-Cookie: session=abc`, and the client sends `Cookie: session=abc` on every
subsequent request. That is the entire mechanism, and it is worth being clear
that the server is trusting a string the client stores and can edit.

Which is why a session cookie holds an **identifier**, not information. Put
`user=admin` in a cookie and you have built an authentication system whose
security depends on the client not typing.

## The program

```zig
const std = @import("std");

pub const Cookie = struct { name: []const u8, value: []const u8 };

/// `Cookie: a=1; b=2`. One header, semicolon separated, and no encoding: a
/// value containing `;` cannot be sent, which is why session ids are hex.
pub fn parseCookies(header: []const u8, out: []Cookie) ![]Cookie {
    var n: usize = 0;
    var parts = std.mem.splitScalar(u8, header, ';');
    while (parts.next()) |part| {
        const item = std.mem.trim(u8, part, " \t");
        if (item.len == 0) continue;
        const eq = std.mem.findScalar(u8, item, '=') orelse continue;
        if (n == out.len) return error.TooManyCookies;
        out[n] = .{ .name = item[0..eq], .value = item[eq + 1 ..] };
        n += 1;
    }
    return out[0..n];
}

pub fn find(cookies: []const Cookie, name: []const u8) ?[]const u8 {
    for (cookies) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.value;
    }
    return null;
}

/// Hex, because a cookie value cannot contain `;` or whitespace and hex avoids
/// the question entirely. 16 bytes is 128 bits, which is the point at which
/// guessing stops being a strategy.
pub fn sessionId(random: std.Random, dest: *[32]u8) []const u8 {
    var raw: [16]u8 = undefined;
    random.bytes(&raw);
    return std.mem.print(dest, "{x}", .{&raw}) catch unreachable;
}

/// The attributes are the security. Without them a session cookie is readable
/// by any script on the page, sent on every cross-site request, and travels in
/// clear text.
pub fn setCookie(out: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try out.print("Set-Cookie: {s}={s}", .{ name, value });
    try out.writeAll("; HttpOnly"); // no script can read it, so XSS cannot steal it
    try out.writeAll("; Secure"); // HTTPS only, so a network observer cannot
    try out.writeAll("; SameSite=Lax"); // not sent on cross-site POSTs, which is CSRF
    try out.writeAll("; Path=/");
    try out.writeAll("; Max-Age=3600\r\n");
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var storage: [8]Cookie = undefined;

    const headers = [_][]const u8{
        "session=deadbeef; theme=dark",
        "  spaced = value ; other=1",
        "novalue; session=abc",
        "",
    };

    for (headers) |header| {
        const cookies = try parseCookies(header, &storage);
        try out.print("\"{s}\"\n", .{header});
        for (cookies) |c| try out.print("  {s} -> \"{s}\"\n", .{ c.name, c.value });
        if (cookies.len == 0) try out.writeAll("  (none)\n");
    }

    const cookies = try parseCookies("session=deadbeef; theme=dark", &storage);
    try out.print("\nlookup session -> {s}\n", .{find(cookies, "session").?});
    try out.print("lookup missing -> {s}\n\n", .{
        if (find(cookies, "missing") == null) "absent" else "present",
    });

    // A fixed seed, so this page prints the same thing every time. That is
    // exactly what a real server must not do: a predictable session id is a
    // session anyone can take. `std.crypto.random` is the one to use.
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    var hex: [32]u8 = undefined;
    try out.print("a session id (seeded, therefore insecure)\n  {s}\n\n", .{
        sessionId(prng.random(), &hex),
    });

    try setCookie(out, "session", "0123456789abcdef0123456789abcdef");

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`19-web-server.sessions`)*

## What just happened

**Parsing is a split on `;` and then on `=`.** No percent-decoding, because
cookies are not encoded, which is why a value cannot contain a semicolon or a
space. That constraint is why session ids are hex: it sidesteps the question
rather than answering it.

**`novalue` was skipped.** An item with no `=` is not a cookie, and the parser
drops it rather than inventing an empty value.

**The second line kept its inner spaces.** `  spaced = value ` produced a name
of `spaced ` and a value of ` value`, spaces included, because whitespace is
trimmed around each *pair* and not inside it. That is what the specification
says, browsers never send it, and being strict here is deliberate. A parser
that trims inside the pair accepts things a stricter one downstream will not.
Two parsers disagreeing about the same bytes is the shape of a security bug
that has appeared in this section twice already.

A fixed seed is what makes this output identical on every build. It is also
exactly what a real server must never do: predictable ids mean anyone can
compute a valid session. `std.crypto.random` is the one to reach for. Sixteen
bytes is 128 bits, which is the point at which guessing stops being a strategy
rather than a number chosen for looking large.

**The attributes are the security, not the cookie.** Each one closes something
specific:

- `HttpOnly` stops JavaScript reading it, so a cross-site scripting bug cannot
  steal the session
- `Secure` stops it travelling over plain HTTP, where anything on the path can
  read it
- `SameSite=Lax` stops it being sent on cross-site POSTs, which is most of
  cross-site request forgery
- `Max-Age` gives the thing an end, so a stolen cookie stops working

A cookie without them is not a weaker session, it is a session with several
well-known ways to take it.

## Check yourself

The server stores the id and looks up the session in its own memory. What
breaks when you run a second copy of the server behind a load balancer?

Every request that lands on the other machine has a session id it has never
seen, so the user is logged out at random. That is why session storage becomes
shared, in Redis or a database, the moment there is more than one process. It
is also why the alternative exists: put the data in the cookie itself and sign
it, so any server can verify it without shared state. That is what a signed
cookie or a JWT is, and it trades the lookup for a new problem, which is that
you cannot revoke something you are not storing.

## If you have written C

The parsing has the same two flaws as everywhere else in this section. It
destroys the header, and it collapses runs of delimiters, which loses nothing
here but would elsewhere.

The part C makes genuinely harder is the random. It is a linear congruential
generator seeded with the clock, which means the id is computable by anyone
who knows roughly when the session started. That has been a real vulnerability
in real products more than once. The correct source is `/dev/urandom` or
`getrandom()`, and the reason people reach for `rand()` anyway is that it is
one call and needs no error handling.

`std.crypto.random` is the same one call, and it is the cryptographic one by
default, which is the useful direction for a default to point.

Next: [a template engine](https://www.ziglang.in/learn/web-server/templates/), so the HTML stops
living in string literals.
