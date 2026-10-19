//! title: Serving Files Safely
//! Decode first, then check. The opposite order is the bug.

const std = @import("std");

pub const Reject = error{ Traversal, BadEncoding, TooLong };

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// `%20` becomes a space, and `+` stays a plus. (In a query string, `+` means
/// a space. In a path, `+` does not. If you mix the two rules, you get a
/// separate small bug.)
pub fn percentDecode(dest: []u8, src: []const u8) Reject![]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (n == dest.len) return error.TooLong;
        if (src[i] == '%') {
            if (i + 2 >= src.len) return error.BadEncoding;
            const hi = hexValue(src[i + 1]) orelse return error.BadEncoding;
            const lo = hexValue(src[i + 2]) orelse return error.BadEncoding;
            dest[n] = hi * 16 + lo;
            i += 3;
        } else {
            dest[n] = src[i];
            i += 1;
        }
        n += 1;
    }
    return dest[0..n];
}

/// Change a request target into a path under the document root, or refuse.
///
/// The order is important. The decode occurs first. A check that runs before
/// the decode sees `%2e%2e`, which looks harmless. But the filesystem still
/// gets `..`. Directory traversal bugs occur in code that checked the
/// incorrect string.
pub fn safePath(dest: []u8, target: []const u8) Reject![]const u8 {
    // A query string is not part of the path.
    const raw = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;

    const decoded = try percentDecode(dest, raw);

    // A nul byte makes the name shorter for code that later uses it as a C
    // string. Thus `/safe.txt\x00../../etc/passwd` can pass a suffix check
    // and still open a different file.
    if (std.mem.findScalar(u8, decoded, 0) != null) return error.Traversal;

    // Reject, and do not normalise. You can change `a/../b` into `b`, but
    // that is a second thing to make correct. A rule that refuses each `..`
    // component has no edge cases, and no legitimate URL needs `..`.
    var parts = std.mem.splitScalar(u8, decoded, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.Traversal;
    }

    if (decoded.len == 0 or std.mem.eql(u8, decoded, "/")) return "/index.html";
    return decoded;
}

/// Get the Content-Type from the extension. A static server knows only the
/// extension. In the past, browsers guessed the type from the bytes. For that
/// reason, people invented `X-Content-Type-Options: nosniff`.
pub fn mimeFor(path: []const u8) []const u8 {
    const dot = std.mem.findScalarLast(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    const table = .{
        .{ "html", "text/html; charset=utf-8" },
        .{ "css", "text/css" },
        .{ "js", "text/javascript" },
        .{ "json", "application/json" },
        .{ "png", "image/png" },
        .{ "txt", "text/plain; charset=utf-8" },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var scratch: [256]u8 = undefined;

    const targets = [_][]const u8{
        "/",
        "/index.html",
        "/style.css?v=3",
        "/a%20file.txt",
        // The three traversal attempts.
        "/../etc/passwd",
        "/static/../../etc/passwd",
        "/%2e%2e/%2e%2e/etc/passwd",
        // Encoded nul.
        "/safe.txt%00.png",
        // Malformed encoding.
        "/bad%zz",
    };

    for (targets) |target| {
        if (safePath(&scratch, target)) |path| {
            try out.print("ok       {s: <28} -> {s: <18} {s}\n", .{ target, path, mimeFor(path) });
        } else |err| {
            try out.print("refused  {s: <28} -> {t}\n", .{ target, err });
        }
    }

    try out.flush();
}
