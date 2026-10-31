# Form Bodies

> The same encoding as a query string, but in the body, where it can be much larger.

A submitted HTML form comes as `name=Ada+Lovelace&role=engineer`. That text is
exactly a query string without the `?`. This is intentional. HTML specifies one
encoding. The method decides if the encoding goes in the URL or in the body.

Thus the parser is the parser from the last chapter. The new parts are around
the parser, because a body is not a URL. A body can be megabytes, and it comes
after the headers.

Also, **the client tells you the size of the body**. This chapter is about what
the server does with that number, because the client can lie.

## The program

```zig
const std = @import("std");
const routes = @import("routes.zig");

pub const Field = routes.Param;

/// A urlencoded body is a query string without the `?`. The HTML
/// specification gives forms one encoding. The method decides where that
/// encoding goes.
pub fn parseForm(body: []const u8, dest: []u8, out: []Field) ![]Field {
    var joined: [1024]u8 = undefined;
    if (body.len + 1 > joined.len) return error.TooLong;
    joined[0] = '?';
    @memcpy(joined[1..][0..body.len], body);
    return routes.parseQuery(joined[0 .. body.len + 1], dest, out);
}

/// The number of body bytes to read. If a server trusts this number without a
/// limit, the client decides how much memory the server uses.
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

## What the program did

**The program uses the same parser without a change.** `parseForm` puts a `?` at
the front and calls `parseQuery`. There is one encoding, thus there is one
parser. No second implementation exists that can become different from the
first.

**`100%25+done` became `100% done`.** The rules are the same as for a query
string: `+` is a space, and `%25` is a literal percent. A form that contains a
percent sign is a good test. If the code is incorrect, the value looks almost
correct.

**The program compared `Content-Length` with a ceiling.** The program refused
`99999999` before it read one byte of the body. Without that check, this
sequence occurs:

1. The client says that the body is 4 GB.
2. The server allocates or reads toward 4 GB.
3. The server stops with a failure.

The check costs nothing. Without the check, the client controls how much memory
the server uses.

A GET has no body and sends no length. Suppose the length is absent, and the
server uses "no limit" for it. Then the server waits forever on a connection that has no more data
to send.

**The program rejected `twelve`, and did not use zero for it.** A malformed
length is a malformed request. To use 0 as a default seems kind to the client.
But then the body that the client sent stays in the socket buffer. The next
request on a keep-alive connection reads that body as its own request line.

That is request smuggling. This is the second time in this section that bad
input, when accepted, causes the vulnerability.

## Check yourself

The parser handles `application/x-www-form-urlencoded`. What does a form with a
file upload send, and why can that form not use this encoding?

The answer: the form sends `multipart/form-data`, which is a completely
different format. Each field becomes a section. A boundary string separates the
sections. The client selects the boundary and gives it in the `Content-Type`
header.

The format exists for two reasons:

- The urlencoded form of a megabyte of binary is approximately three times
  larger. Each byte that is not a letter, a digit or one of `*-._` becomes
  three characters.
- A file has its own filename and content type, and the urlencoded format has
  no place for them.

Thus a server that supports uploads has two body parsers. The multipart parser
must handle these problems:

- A boundary that occurs inside the data.
- Sections that come split across reads.
- A filename that the server must never trust as a path.

Each of these problems caused real bugs. [File
Uploads](https://www.ziglang.in/learn/web-server/multipart/) is the chapter that builds this parser.

## If you know C

The body comes on the same descriptor as the headers. A common mistake in C is
to read the body with the same call:

```c
read(fd, buf, sizeof buf);   /* may return the headers AND part of the body */
```

When you find the blank line, you have probably already read some of the body.
Thus the parser must use the data that is in the buffer, and only then read
more. Some code expects "headers, then a new read for the body". That code is
correct on a fast loopback, and incorrect over a real network.

The other mistake is `atoi(content_length)`. It returns 0 for `"twelve"` and
also for `"0"`. It also cannot report overflow. `parseInt` returns an error.
Thus the compiler makes you handle the malformed case.

Next: [cookies and sessions](https://www.ziglang.in/learn/web-server/sessions/). With cookies and
sessions, the server knows who sent the form.
