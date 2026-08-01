//! title: Cookies and Sessions
//! A cookie is a string the client stores and hands back. Everything else is policy.

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
