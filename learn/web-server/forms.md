# Form Bodies

> The same encoding as a query string, arriving somewhere it can be much larger.

A submitted HTML form arrives as `name=Ada+Lovelace&role=engineer`, which is
exactly a query string with the `?` removed. That is not a coincidence: HTML
specified one encoding, and whether it travels in the URL or in the body is
the method's business rather than the format's.

So the parser is the one from the last chapter. What is new is everything
around it, because a body is not a URL. It can be megabytes, it arrives after
the headers, and the client tells you how much is coming.

That last part is the whole of this chapter. **The client tells you.**

## The program

```zig
const std = @import("std");
const routes = @import("routes.zig");

pub const Field = routes.Param;

/// A urlencoded body is a query string without the `?`. That is not a
/// coincidence: HTML forms were specified to produce one encoding, and where
/// it travels is the method's business rather than the format's.
pub fn parseForm(body: []const u8, dest: []u8, out: []Field) ![]Field {
    var joined: [1024]u8 = undefined;
    if (body.len + 1 > joined.len) return error.TooLong;
    joined[0] = '?';
    @memcpy(joined[1..][0..body.len], body);
    return routes.parseQuery(joined[0 .. body.len + 1], dest, out);
}

/// How many bytes of body to read. A server that trusts this number without a
/// ceiling has handed the client control of its memory.
pub fn bodyLength(declared: ?[]const u8, limit: usize) !usize {
    const text = declared orelse return 0;
    const n = std.fmt.parseInt(usize, text, 10) catch return error.Malformed;
    if (n > limit) return error.TooLarge;
    return n;
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var scratch: [512]u8 = undefined;
    var fields: [8]Field = undefined;

    const bodies = [_][]const u8{
        "name=Ada+Lovelace&role=engineer",
        "note=100%25+done&tags=a%26b",
        "consent=on&newsletter=",
        "",
    };

    for (bodies) |body| {
        const parsed = try parseForm(body, &scratch, &fields);
        try out.print("\"{s}\"\n", .{body});
        for (parsed) |f| try out.print("  {s} = \"{s}\"\n", .{ f.name, f.value });
        if (parsed.len == 0) try out.writeAll("  (no fields)\n");
    }

    try out.writeAll("\nContent-Length, with a ceiling of 1 MB\n");
    for ([_]?[]const u8{ "13", null, "99999999", "twelve" }) |declared| {
        const label = declared orelse "(absent)";
        if (bodyLength(declared, 1 << 20)) |n| {
            try out.print("  {s: <10} -> read {d} bytes\n", .{ label, n });
        } else |err| {
            try out.print("  {s: <10} -> {t}\n", .{ label, err });
        }
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`19-web-server.forms`)*

## What just happened

**The parsing is reused verbatim.** `parseForm` puts a `?` on the front and
calls `parseQuery`. That looks like a trick and is actually the point: one
encoding, one parser, and no second implementation to drift.

**`100%25+done` became `100% done`.** Same rules as a query string: `+` is a
space, `%25` is a literal percent. A form containing a percent sign is a good
test, because getting it wrong produces a value that looks almost right.

**`Content-Length` was checked against a ceiling.** `99999999` was refused
before a single byte of body was read. Without that check the sequence is:
client claims a 4 GB body, server allocates or reads toward it, server dies.
It costs nothing to ask, and a server that does not ask has handed the client
control of its memory.

A GET has no body and sends no length. Treating absence as unbounded is how a
server ends up waiting forever on a connection that has nothing more to say.

**`twelve` was rejected rather than treated as zero.** A malformed length is a
malformed request. Defaulting it to 0 sounds forgiving. What it means is that
the body which was sent stays in the socket buffer, where the next request on
a keep-alive connection reads it as its own request line. That is request
smuggling, and this is the second time in this section that leniency has been
the vulnerability.

## Check yourself

The parser handles `application/x-www-form-urlencoded`. What does a form with
a file upload send instead, and why can it not use this encoding?

`multipart/form-data`, which is a completely different format: each field
becomes a section separated by a boundary string the client chooses and
announces in the `Content-Type` header. It exists because urlencoding a
megabyte of binary would inflate it by roughly a third. And because a file has
a filename and a content type of its own, which the encoding has nowhere to
put.

The practical consequence is that a server supporting uploads has two body
parsers, not one. The multipart one has to handle a boundary appearing inside
the data, sections arriving split across reads, and a filename that must never
be trusted as a path. Every one of those has its own history, and [File
Uploads](https://www.ziglang.in/learn/web-server/multipart/) is the chapter that builds it.

## If you have written C

The body arrives on the same descriptor as the headers, and the C-shaped
mistake is reading it with the same call:

```c
read(fd, buf, sizeof buf);   /* may return the headers AND part of the body */
```

By the time you have found the blank line you have probably already read some
of the body. So the parser has to work with what is in the buffer, and only
then read more. Any code that assumes "headers, then a fresh read for the
body" is correct on a fast loopback and wrong over a real network.

The other one is `atoi(content_length)`, which returns 0 for `"twelve"` and
for `"0"` alike, and has no way to report overflow. `parseInt` returns an
error, so the malformed case is one the compiler makes you handle.

Next: [cookies and sessions](https://www.ziglang.in/learn/web-server/sessions/), which is how the
server remembers who sent the form.
