# Parse an HTTP Request

> A request line, some headers, a blank line. The blank line is the difficult part.

An HTTP request is text. A request is small, and you can read it aloud:

```
POST /submit?id=7 HTTP/1.1
Host: example.com
Content-Length: 13

name=ada&ok=1
```

A request has a request line, some headers, a blank line, and a body. That is
the full format, and you can implement it without a library.

The difficult part is the blank line. The purpose of the blank line seems
simple, but it is not.

HTTP gives **no length at the start**. A server that
reads from a socket cannot know how many bytes are in this request. Thus the
server cannot ask for that number of bytes. The server must read until the
header section ends. After that, `Content-Length` tells the server the size of
the body.

This is the framing problem from the [networking](https://www.ziglang.in/learn/networking/framing/)
section. The HTTP solution is a delimiter: `\r\n\r\n`.

## The program

```zig
const std = @import("std");

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    version: []const u8,
    /// Slices into the original bytes. The parser copies nothing.
    headers: [][2][]const u8,
    body: []const u8,

    /// Header names are case-insensitive, and the parser must handle this.
    /// curl sends `Host`, some proxies send `HOST`, and a hand-written client
    /// sends `host`. An exact comparison fails when the case is different.
    pub fn header(r: Request, name: []const u8) ?[]const u8 {
        for (r.headers) |pair| {
            if (std.ascii.eqlIgnoreCase(pair[0], name)) return pair[1];
        }
        return null;
    }
};

pub const Error = error{ Malformed, TooManyHeaders };

pub fn parse(bytes: []const u8, storage: [][2][]const u8) Error!Request {
    // The header section ends at the first blank line. All bytes after it are
    // the body. To find that boundary is the framing problem. HTTP gives no
    // length at the start, thus the parser reads until it finds CRLF CRLF.
    const split = std.mem.find(u8, bytes, "\r\n\r\n") orelse return error.Malformed;
    const head = bytes[0..split];
    const body = bytes[split + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");

    const request_line = lines.next() orelse return error.Malformed;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.Malformed;
    const target = parts.next() orelse return error.Malformed;
    const version = parts.next() orelse return error.Malformed;
    if (parts.next() != null) return error.Malformed;

    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.Malformed;
        if (count == storage.len) return error.TooManyHeaders;
        storage[count] = .{
            line[0..colon],
            // Remove optional whitespace after the colon, and only after it. A
            // space before the colon is malformed. If the parser accepts that
            // space, request smuggling can occur.
            std.mem.trimStart(u8, line[colon + 1 ..], " \t"),
        };
        count += 1;
    }

    return .{
        .method = method,
        .target = target,
        .version = version,
        .headers = storage[0..count],
        .body = body,
    };
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const raw =
        "POST /submit?id=7 HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "content-type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: 13\r\n" ++
        "\r\n" ++
        "name=ada&ok=1";

    var storage: [16][2][]const u8 = undefined;
    const request = try parse(raw, &storage);

    try out.print("method  {s}\n", .{request.method});
    try out.print("target  {s}\n", .{request.target});
    try out.print("version {s}\n\n", .{request.version});

    for (request.headers) |pair| try out.print("  {s}: {s}\n", .{ pair[0], pair[1] });

    // The lookup uses a different case from the case that the client sent.
    try out.print("\nlookup \"Content-Type\" -> {s}\n", .{request.header("Content-Type").?});
    try out.print("lookup \"Missing\"      -> {s}\n\n", .{
        if (request.header("Missing") == null) "absent" else "present",
    });

    try out.print("body ({d} bytes) {s}\n", .{ request.body.len, request.body });
    const declared = request.header("content-length").?;
    try out.print("Content-Length says {s}, and it agrees: {}\n\n", .{
        declared,
        request.body.len == try std.fmt.parseInt(usize, declared, 10),
    });

    for ([_][]const u8{
        "GET /only-one-line\r\n\r\n",
        "GET /extra parts HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nBadHeader\r\n\r\n",
        "GET / HTTP/1.1\r\n",
    }) |bad| {
        if (parse(bad, &storage)) |_| {
            try out.writeAll("accepted, which is wrong\n");
        } else |err| {
            try out.print("rejected: {t}\n", .{err});
        }
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`19-web-server.request`)*

## What the program did

**The parse is a split, then a split, then a loop.** The parser does these
steps:

1. Find the blank line, to separate the head from the body.
2. Split the head on `\r\n`.
3. Use the first line as the request line.
4. Read each of the other lines as `name: value`.

The parser needs no state machine and no buffering, because the full request is
already in memory.

**The parser found `Content-Type`, but the client sent `content-type`.** Header
names are case-insensitive, and the parser must handle this from the start.
`curl` sends `Host`, HTTP/2 clients use lowercase for all names, and a
hand-written client sends the text that its author typed. A parser that
compares names exactly works with the client that you used for the test. It
fails with the other clients.

**The parser removes whitespace after the colon, but not before the colon.**
`Host: example.com` and `Host:example.com` are both correct.
`Host : example.com` is malformed. To accept it anyway seems safe, but it is
not safe.

Sometimes two systems in a chain do not agree about which requests
are valid. Then an attacker can make one system see a request that the other
system did not see. Request smuggling uses this problem. Strict parsing
prevents it.

**The parser copied nothing.** Each field is a slice of the original bytes.
The request is a view of the buffer that the socket filled. Thus parsing
allocates nothing. The request is valid for exactly as long as that buffer is
valid.

**The parser rejected four malformed requests:**

- A request line with no version.
- A request line with too many parts.
- A header with no colon.
- A request that stops before the blank line.

The parser returns an error for each request, and it does not guess.

## Check yourself

The parser takes `[]const u8` and has no socket. Why is this important?

The answer: because of this property, this page can run the parser. The same
property lets you do three more things without a network:

- Unit-test the parser.
- Fuzz the parser with a corpus of malformed requests.
- Use the parser again in a client. A *response* has the same shape: a status
  line, headers, a blank line, a body.

The status line needs its own split. This parser wants exactly three fields,
and a reason phrase such as `Not Found` contains a space. A parser that reads
from a socket is testable only when a server runs.

All protocol parsers in this guide use this design. Thus most of the networking
chapters run in a browser. The next chapter puts a socket in front of this
parser, and the parser does not change.

## If you know C

The C version uses `strstr` for the blank line and `strtok` for the other
parts. Both choices have a cost.

`strtok` writes `\0` over each delimiter, and thus it destroys the buffer while
it reads. For a request, this is frequently acceptable, because you do not need
the request again. But `strtok` also joins a sequence of delimiters into one.
Thus an empty header line disappears, and that empty line marks the end of the
headers. For this reason, parsers that use `strtok` usually find the blank line
in a separate step.

Also, each field is a `char *` into the buffer, with no length. Thus "header
value" and "the rest of the request after this point" have the same type. Because
of this, a bug can read a request body as a header value.

Next: [the server](https://www.ziglang.in/learn/web-server/server/), which is this parser with a
socket in front of it.
