# Cookies and Sessions

> A cookie is a string the client stores and hands back. Everything else is policy.

HTTP has no memory. Each request arrives with no idea that another one came
before it, which is the property that lets a server be restarted, replicated
and load-balanced without anybody noticing.

A cookie is the smallest possible fix for that. The server sends
`Set-Cookie: session=abc`, and the client sends `Cookie: session=abc` on every
later request. That is the entire mechanism. The server is trusting a string
that the client stores and can edit.

So a session cookie holds an **identifier**, not information. If you put
`user=admin` in a cookie, anyone can log in as admin by editing the cookie.

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

/// Hex, because a cookie value cannot contain `;` or whitespace, and hex never
/// contains either. 16 bytes is 128 bits, which is too many to guess.
pub fn sessionId(random: std.Random, dest: *[32]u8) []const u8 {
    var raw: [16]u8 = undefined;
    random.bytes(&raw);
    return std.mem.print(dest, "{x}", .{&raw}) catch unreachable;
}

/// The attributes provide the security. Without them a session cookie is
/// readable by any script on the page, sent on every cross-site request, and
/// travels in clear text.
pub fn setCookie(out: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try out.print("Set-Cookie: {s}={s}", .{ name, value });
    try out.writeAll("; HttpOnly"); // no script can read it, so XSS cannot steal it
    try out.writeAll("; Secure"); // HTTPS only, so a network observer cannot read it
    try out.writeAll("; SameSite=Lax"); // not sent on cross-site POSTs, which blocks CSRF
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

    // A fixed seed, so this page prints the same thing every time. A real
    // server must not do this: anyone can take a session whose id they can
    // predict. `std.crypto.random` is the one to use.
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

**Parsing is a split on `;` and then on `=`.** There is no percent-decoding,
because cookies are not encoded. So a value cannot contain a semicolon or a
space. Session ids are hex for this reason: hex never contains those
characters, so the problem never comes up.

**`novalue` was skipped.** An item with no `=` is not a cookie. The parser
drops it and does not invent an empty value.

**The second line kept its inner spaces.** `  spaced = value ` produced a name
of `spaced ` and a value of ` value`, spaces included, because whitespace is
trimmed around each *pair* and not inside it. The grammar does not allow those
spaces at all and browsers never send them, so being strict here costs
nothing. A parser that trims inside the pair accepts input that a stricter
parser later in the chain will reject. When two parsers disagree about the
same bytes, an attacker can use the difference.

A fixed seed is what makes this output identical on every build. It is also
exactly what a real server must never do: predictable ids mean anyone can
compute a valid session. `std.Random.IoSource`, which fills bytes from the
operating system through the `Io` interface, is the one to reach for. Sixteen
bytes is 128 bits. That is too many possible ids for anyone to guess one.

**The security comes from the attributes on the cookie.** Each one blocks a
specific attack:

- `HttpOnly` stops JavaScript reading it, so a cross-site scripting bug cannot
  copy the id out. Script on the page can still act as the user while the page
  is open, so this is not a fix for XSS
- `Secure` stops it travelling over plain HTTP, where anything on the path can
  read it
- `SameSite=Lax` stops it being sent on cross-site POSTs, which is most of
  cross-site request forgery
- `Max-Age` gives the cookie an end, so the browser stops sending it. A stolen
  id stops working only when the server expires it, and that half is yours to
  build

Without these attributes, there are several well-known ways to steal the
session.

## Check yourself

The server stores the id and looks up the session in its own memory. What
breaks when you run a second copy of the server behind a load balancer?

Every request that lands on the other machine has a session id it has never
seen, so the user is logged out at random. So once there is more than one
process, session storage moves to a shared place, such as Redis or a database.

There is also another approach: put the data in the cookie itself and sign it.
Then any server can verify it without shared state. A signed cookie or a JWT
works this way. It removes the lookup but adds a new problem: you cannot
revoke something you are not storing.

## If you have written C

In C, this parsing is usually done with `strtok`, which has two flaws. It
writes `\0` over each delimiter, which destroys the header. And it collapses
runs of delimiters. Here that loses nothing, but in other formats it would.

The random number is the part C makes harder. The usual C random is `rand()`:
a linear congruential generator seeded with the clock. So anyone who knows roughly when
the session started can compute the id. This has been a real vulnerability in
real products more than once. The correct source is `/dev/urandom` or
`getrandom()`. People use `rand()` anyway because it is one call and needs no
error handling.

Zig does not offer that shortcut. `std.crypto.random` was removed, so the
secure source is passed in like any other capability: `std.Random.IoSource`
over the `Io` you already have. That costs a line of setup, and there is no
easy insecure option to use by mistake.

Next: [a template engine](https://www.ziglang.in/learn/web-server/templates/), so the HTML stops
living in string literals.
