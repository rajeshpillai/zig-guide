# Cookies and Sessions

> A cookie is a string that the client stores and sends back. All the rest is policy.

HTTP has no memory. Each request comes with no information about the requests
before it. Because of this property, you can restart, replicate and
load-balance a server, and no user sees a difference.

A cookie is the smallest possible solution to this problem. The server sends
`Set-Cookie: session=abc`, and the client sends `Cookie: session=abc` on each
later request. That is the full mechanism. The server trusts a string that the
client stores and can edit.

Thus a session cookie holds an **identifier**, not information. If you put
`user=admin` in a cookie, any person can log in as admin if they edit the
cookie.

## The program

```zig
const std = @import("std");

pub const Cookie = struct { name: []const u8, value: []const u8 };

/// `Cookie: a=1; b=2`. One header, with semicolons between items, and no
/// encoding. A client cannot send a value that contains `;`. For this reason,
/// session ids are hex.
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
/// contains them. 16 bytes is 128 bits. No person can guess that many ids.
pub fn sessionId(random: std.Random, dest: *[32]u8) []const u8 {
    var raw: [16]u8 = undefined;
    random.bytes(&raw);
    return std.mem.print(dest, "{x}", .{&raw}) catch unreachable;
}

/// The attributes give the security. Without them, any script on the page can
/// read a session cookie. The browser sends the cookie on each cross-site
/// request, and the cookie goes in clear text.
pub fn setCookie(out: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try out.print("Set-Cookie: {s}={s}", .{ name, value });
    try out.writeAll("; HttpOnly"); // no script can read it, thus XSS cannot steal it
    try out.writeAll("; Secure"); // HTTPS only, thus a network observer cannot read it
    try out.writeAll("; SameSite=Lax"); // the browser does not send it on cross-site POSTs, to stop CSRF
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

    // A fixed seed, thus this page prints the same text each time. A real
    // server must not do this. If a person can predict a session id, that
    // person can take the session. Use `std.Random.IoSource` over the `Io`
    // that you already have. (Older code uses `std.crypto.random`. Zig
    // removed it.)
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

## What the program did

**The parse is a split on `;`, then on `=`.** There is no percent-decoding,
because cookies have no encoding. Thus a value cannot contain a semicolon or a
space. For this reason, session ids are hex. Hex never contains those
characters, thus the problem does not occur.

**The parser ignored `novalue`.** An item with no `=` is not a cookie. The
parser removes the item, and it does not make an empty value.

**The second line kept its inner spaces.** `  spaced = value ` gave the name
`spaced ` and the value ` value`, with the spaces. The parser removes
whitespace around each *pair*, not inside the pair. The grammar does not allow
those spaces, and browsers never send them. Thus a strict rule here costs
nothing.

A parser that removes spaces inside the pair accepts input that a stricter
parser later in the chain rejects. When two parsers do not agree about the same
bytes, an attacker can use the difference.

The program uses a fixed seed. Thus the output is the same on each build. A
real server must never do this.

If the ids are predictable, any person can
calculate a valid session. Use `std.Random.IoSource`, which gets bytes from the
operating system through the `Io` interface. Sixteen bytes is 128 bits. With
that many possible ids, no person can guess an id.

**The security comes from the attributes on the cookie.** Each attribute stops
a specific attack:

- With `HttpOnly`, JavaScript cannot read the cookie. Thus a cross-site
  scripting bug cannot copy the id. A script on the page can still act as the
  user while the page is open. Thus this attribute does not fix XSS.
- `Secure` stops the cookie on plain HTTP. On plain HTTP, any device on the path
  can read the cookie.
- With `SameSite=Lax`, the browser does not send the cookie on cross-site
  POSTs. This stops most cross-site request forgery.
- `Max-Age` gives the cookie an end. After that end, the browser does not send
  the cookie. A stolen id stops working only when the server expires the id. You
  must build that part.

Without these attributes, there are several well-known ways to steal the
session.

## Check yourself

The server stores the id and finds the session in its own memory. What breaks
when you run a second copy of the server behind a load balancer?

The answer: a request that goes to the other machine has a session id that the
other machine never saw. Thus the session of the user ends at random times. When there
is more than one process, the session storage must move to a shared place, for
example Redis or a database.

There is also a different method: put the data in the cookie and sign the
cookie. Then each server can verify the cookie without shared state. A signed
cookie or a JWT works this way. This method removes the lookup, but it adds a
new problem: you cannot revoke something that you do not store.

## If you know C

In C, programmers usually do this parsing with `strtok`. `strtok` has two
problems:

- It writes `\0` over each delimiter, and this destroys the header.
- It joins a sequence of delimiters into one. Here, this loses nothing, but in
  other formats it loses data.

C makes the random number more difficult. The usual random function in C is
`rand()`: a linear congruential generator, with the clock as the seed. Thus a
person who knows approximately when the session started can calculate the id.
This problem was a real vulnerability in real products more than one time. The
correct source is `/dev/urandom` or `getrandom()`. People use `rand()` anyway,
because it is one call and needs no error handling.

Zig does not give that easy path. Zig removed `std.crypto.random`. Thus you give
the secure source to the code as a parameter, the same as any other capability:
`std.Random.IoSource` over the `Io` that you already have. That costs one line
of setup, and there is no easy insecure option that you can use by mistake.

Next: [a template engine](https://www.ziglang.in/learn/web-server/templates/), so the HTML is not in
string literals.
