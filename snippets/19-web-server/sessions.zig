//! title: Cookies and Sessions
//! A cookie is a string that the client stores and sends back. All the rest is policy.

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
