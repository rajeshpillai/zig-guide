//! title: Serving Files Safely
//! Decode first, then check. Doing it the other way round is the bug.

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

/// `%20` becomes a space, `+` stays a plus. (In a query string `+` means a
/// space; in a path it does not, and conflating the two is its own small bug.)
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

/// Turn a request target into a path under the document root, or refuse.
///
/// The order is the entire point. Decoding happens first, because a check that
/// runs before decoding is looking at `%2e%2e` and seeing something harmless,
/// and the byte that reaches the filesystem is `..` regardless. Every scanner
/// that has ever found a directory traversal has found it in code that checked
/// the wrong string.
pub fn safePath(dest: []u8, target: []const u8) Reject![]const u8 {
    // A query string is not part of the path.
    const raw = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;

    const decoded = try percentDecode(dest, raw);

    // A nul byte truncates the name for anything that later treats it as a C
    // string, so `/safe.txt\x00../../etc/passwd` can pass a suffix check and
    // still open something else.
    if (std.mem.findScalar(u8, decoded, 0) != null) return error.Traversal;

    // Reject rather than normalise. Collapsing `a/../b` into `b` is possible
    // and is a second thing to get right; refusing any `..` component is one
    // rule with no edge cases, and no legitimate URL needs one.
    var parts = std.mem.splitScalar(u8, decoded, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.Traversal;
    }

    if (decoded.len == 0 or std.mem.eql(u8, decoded, "/")) return "/index.html";
    return decoded;
}

/// Content-Type from the extension, because that is all a static server knows.
/// Guessing from the bytes is what browsers used to do and is the reason
/// `X-Content-Type-Options: nosniff` had to be invented.
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
        // The three that matter.
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
