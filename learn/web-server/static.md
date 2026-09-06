# Serving Files Safely

> Decode first, then check. Doing it the other way round is the bug.

A static file server is four lines of logic: take the request target, open
that file under the document root, read it, send it. It is also the single
most reliable way to hand an attacker your `/etc/passwd`, and the reason is a
one-line mistake in an ordering.

The target arrives percent-encoded. `%20` is a space, and `%2e` is a full
stop. So the string `/%2e%2e/%2e%2e/etc/passwd` contains no `..` at all as far
as any check looking at it can tell, and decodes to `/../../etc/passwd` a
moment later.

**Decode first, then check.** A guard that runs before decoding is inspecting a
string that is not the one the filesystem will see.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`19-web-server.static`)*

## What just happened

**Three traversal attempts, all refused, including the encoded one.** The plain
`/../etc/passwd`, the buried `/static/../../etc/passwd`, and the encoded
`/%2e%2e/%2e%2e/etc/passwd`. The third is the one that gets through real
servers, and it is refused here for one reason: `percentDecode` runs before
anything looks for `..`.

**Reject rather than normalise.** Collapsing `a/../b` into `b` is possible, and
then you own a path normaliser, which is a second thing to get exactly right
and has its own history of bugs. Refusing any `..` component is one rule with
no edge cases, and no legitimate URL contains one, because the browser
resolves them before sending.

**The nul byte was refused too.** `/safe.txt%00.png` decodes to a name
containing a zero byte, and anything downstream that treats it as a C string
sees `/safe.txt` and stops. That lets a check on the extension pass while a
different file gets opened. Zig's strings carry a length so this is inert
here, but the path may be handed to a C library, and the guard costs one
comparison.

**The content type comes from the extension, not the bytes.** That is all a
static server knows. Browsers used to guess by sniffing the content, which
meant a file uploaded as `.txt` containing HTML would be *rendered* as HTML,
turning any user-upload feature into stored XSS. `X-Content-Type-Options:
nosniff` exists to tell the browser to stop doing that, and it is a header you
should be sending.

## Check yourself

The guard refuses `..` but happily accepts `/etc/passwd` with no dots at all.
Why is that fine, and when would it stop being fine?

Because the path is joined to a document root: `www` + `/etc/passwd` is
`www/etc/passwd`, which almost certainly does not exist. The leading slash is
part of the URL, not the filesystem.

It stops being fine the moment the join is done with something that treats an
absolute path as absolute and discards the prefix. That is exactly what
`path.join` does in several languages, including Python's `os.path.join` and
Node's `path.resolve`, and it turns a "harmless" absolute path into a full
filesystem read. The guard should not be the only thing standing between a
request and the disk. Opening relative to a directory handle, so the kernel
enforces the boundary, is the belt to this braces.

## If you have written C

The classic version of this bug is a check against the raw buffer:

```c
if (strstr(target, "..")) return forbidden();   /* runs before decoding */
url_decode(path, target);
int fd = open(path, O_RDONLY);
```

Two problems, and the ordering is only the first. It also matches the pattern
anywhere, so a legitimate file whose name contains it is refused. That pushes
whoever maintains it toward a cleverer check, and cleverer checks are how the
encoded variant gets through.

The other C-specific hazard is that `open` takes a `char *`, so a nul in the
decoded path silently truncates it. That is the reason the guard above rejects
a nul rather than shrugging at it. In Zig the slice keeps its length, but the
moment the path crosses into C the length stops travelling with it.

`openat` with a directory handle is the structural fix, and it is available in
Zig as `dir.openFile`, which resolves relative to a `Dir` rather than the
process's whole filesystem.

Next: [routing and query strings](https://www.ziglang.in/learn/web-server/routes/), which is the
other half of what a target means.
