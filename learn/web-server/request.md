# Parsing an HTTP Request

> A request line, some headers, a blank line. The blank line is the hard part.

An HTTP request is text, and small enough to read out loud:

```
POST /submit?id=7 HTTP/1.1
Host: example.com
Content-Length: 13

name=ada&ok=1
```

A request line, some headers, a blank line, and a body. That is the whole
format, and you can implement it without a library.

The part that is genuinely awkward is the blank line, because it is doing a
job that looks trivial and is not. HTTP sends **no length up front**. A server
reading from a socket has no idea how many bytes belong to this request, so it
cannot ask for them. It has to read until it sees the header section end, and
only then can `Content-Length` tell it how much body follows.

That is the framing problem from the [networking](https://www.ziglang.in/learn/networking/framing/)
section, and HTTP's answer is a delimiter: `\r\n\r\n`.

## The program

```zig
const std = @import("std");

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    version: []const u8,
    /// Slices into the original bytes; nothing is copied.
    headers: [][2][]const u8,
    body: []const u8,

    /// Header names are case-insensitive, which is not a detail you can skip:
    /// curl sends `Host`, some proxies send `HOST`, and a client written by
    /// hand sends `host`. Comparing them exactly works until it does not.
    pub fn header(r: Request, name: []const u8) ?[]const u8 {
        for (r.headers) |pair| {
            if (std.ascii.eqlIgnoreCase(pair[0], name)) return pair[1];
        }
        return null;
    }
};

pub const Error = error{ Malformed, TooManyHeaders };

pub fn parse(bytes: []const u8, storage: [][2][]const u8) Error!Request {
    // The header section ends at the first blank line. Everything after it is
    // body, and finding that boundary is the whole framing problem: HTTP has
    // no length up front, so the parser reads until it sees CRLF CRLF.
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
            // Optional whitespace after the colon, and only after it. A space
            // before the colon is malformed, and treating it as acceptable is
            // how request smuggling gets started.
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

    // Asked for with a different case than it was sent with.
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

## What just happened

**The parse is a split, then a split, then a loop.** Find the blank line to
separate head from body, split the head on `\r\n`, take the first line as the
request line, and treat the rest as `name: value`. No state machine and no
buffering, because the whole request is already in memory.

**`Content-Type` was found when it was sent as `content-type`.** Header names
are case-insensitive, and this is not a detail you can defer. `curl` sends
`Host`, HTTP/2 clients lower-case everything, and a hand-written client sends
whatever its author typed. A parser comparing exactly works perfectly against
the client you tested with.

**Whitespace is trimmed after the colon and not before it.** `Host: example.com`
and `Host:example.com` are both fine; `Host : example.com` is malformed. Being
lenient there sounds harmless and is not. When two systems in a chain disagree
about which requests are valid, one of them can be persuaded to see a request
the other did not. That is how request smuggling works. Strict parsing is a
security property, not fussiness.

**Nothing was copied.** Every field is a slice of the original bytes. The
request is a view over the buffer the socket filled, so parsing allocates
nothing and the whole thing is valid exactly as long as that buffer is.

**Four malformed requests were rejected.** A missing blank line, too many parts
in the request line, a header with no colon, and a truncated request. Each is
an error rather than a guess.

## Check yourself

The parser takes `[]const u8` and never mentions a socket. Why does that
matter more than it looks?

Because it means this page can run it. The same property is what lets the
parser be unit-tested without a network, fuzzed with a corpus of malformed
requests, and reused by a client to parse
*responses*, which have the same shape. A parser that reads from a socket can be tested only by starting a
server.

This is the rule [CLAUDE.md](https://github.com/rajeshpillai/zig-guide) states
for all the protocol code in this guide, and it is the reason most of the
networking chapters run in a browser. The next chapter puts a socket in front
of this one, and the parser does not change.

## If you have written C

The C version is `strstr` for the blank line and `strtok` for the rest, and
both of those choices cost you something.

`strtok` writes `\0` over each delimiter, destroying the buffer as it reads.
For a request that is often acceptable, since you are done with it. It also
collapses runs of delimiters, which means an empty header line, the very thing
marking the end of the headers, disappears. Parsers built on `strtok` usually
find the blank line separately for this reason.

And every field ends up as a `char *` into the buffer with no length, so
"header value" and "the rest of the request from here on" are the same type.
That is the class of bug that reads a request body as a header value.

Next: [the server](https://www.ziglang.in/learn/web-server/server/), which is this parser with a
socket in front of it.
