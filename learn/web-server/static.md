# Serve Files Safely

> Decode first, then check. The opposite order is the bug.

A static file server has four steps of logic:

1. Take the request target.
2. Open that file under the document root.
3. Read the file.
4. Send the file.

A static file server is also a common way to give your `/etc/passwd` to an
attacker. The cause is a one-line mistake in the order of the steps.

The target comes percent-encoded. `%20` is a space, and `%2e` is a full stop.
Thus a check on the string `/%2e%2e/%2e%2e/etc/passwd` finds no `..` at all. A
moment later, the string decodes to `/../../etc/passwd`.

**Decode first, then check.** A guard that runs before the decode examines a
string that is different from the string that the filesystem gets.

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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`19-web-server.static`)*

## What the program did

**The guard refused three traversal attempts, and one attempt used percent-encoding.**
The three attempts are:

- The plain `/../etc/passwd`.
- The hidden `/static/../../etc/passwd`.
- The encoded `/%2e%2e/%2e%2e/etc/passwd`.

The third attempt is the one that gets through servers in production. The
guard refuses it here for one reason: `percentDecode` runs before any code
looks for `..`.

**Reject, and do not normalise.** You can change `a/../b` into `b`. But then you
must maintain a path normaliser.

A path normaliser is a second thing that you
must make exactly correct, and path normalisers have their own history of bugs.
A rule that refuses each `..` component is one rule with no edge cases. No
legitimate URL contains a `..` component, because the browser resolves `..`
before it sends the URL.

**The guard also refused the nul byte.** `/safe.txt%00.png` decodes to a name
that contains a zero byte. Code after the guard can use the name as a C string.
That code sees `/safe.txt` and stops. Thus a check on the extension can pass,
and the program opens a different file.

Zig strings have a length, thus the nul
byte has no effect here. But the program can give the path to a C library, and
the guard costs one comparison.

**The content type comes from the extension, not from the bytes.** A static
server knows only the extension. In the past, browsers guessed the type from
the content. Thus the browser *rendered* a `.txt` upload that contained HTML as
HTML. Each feature for user uploads became a stored XSS problem.

`X-Content-Type-Options: nosniff` tells the browser not to guess. Send this
header.

## Check yourself

The guard refuses `..`, but it accepts `/etc/passwd`, which has no dots. Why is
that correct, and when does it become incorrect?

The answer: the program joins the path to a document root. `www` +
`/etc/passwd` is `www/etc/passwd`, and that file almost certainly does not
exist. The slash at the start is part of the URL, not part of the filesystem.

The guard becomes incorrect when the join uses a function that keeps an
absolute path as absolute and discards the prefix. Several languages have a
`path.join` that does exactly this, for example Python `os.path.join` and Node
`path.resolve`. Then a "harmless" absolute path becomes a full filesystem read.

The guard must not be the only protection between a request and the disk. But a
directory handle is not a second guard:

- `openat` resolves `..` the same as any other path.
- `openat` ignores the directory completely when the path is absolute.

`std.Io.Dir` has `resolve_beneath` in its open options. The documentation says
that this option changes a path that escapes into `error.AccessDenied`. The
documentation also says that the option has no effect on an operating system
that does not support it.

Linux is one of those systems. The option uses a BSD `O_`
flag, and Linux has the same idea as an `openat2` resolve flag. Thus on Linux
the option silently does nothing. If you set the option and open
`../outside.txt`, the file opens.

## If you know C

The usual version of this bug is a check on the raw buffer:

```c
if (strstr(target, "..")) return forbidden();   /* runs before decoding */
url_decode(path, target);
int fd = open(path, O_RDONLY);
```

This code has two problems, and the order is only the first problem. The check
also matches the pattern in all positions. Thus it refuses a legitimate file
that has the pattern in its name. Then the maintainer usually makes the check
more complex, and more complex checks let the encoded variant through.

The other hazard that is specific to C: `open` takes a `char *`. Thus a nul in
the decoded path silently makes the path shorter. For this reason, the guard
above rejects a nul and does not ignore it. In Zig, the slice keeps its length.
But when the path goes into C code, the length does not go with it.

The usual design is `openat` with a directory handle. In Zig, this is
`dir.openFile`, which resolves the path relative to a `Dir`. It is not a
sandbox. A `..` can still climb out of the directory, and an absolute path
ignores the directory. Thus the check above must always run, on all platforms,
with or without `resolve_beneath`.

Next: [routes and query strings](https://www.ziglang.in/learn/web-server/routes/), which is the
other part of the meaning of a target.
