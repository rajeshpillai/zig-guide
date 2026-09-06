# An HTTP Server

> The parser from the last chapter, with a socket in front of it.

The parser takes bytes and returns a request. A server is that, plus somewhere
for the bytes to come from and somewhere for the answer to go. There is less
new code here than you might expect, which is the point of having built the
parser first.

## The program

This one has no Run button. It binds a listening socket, which the browser
sandbox has no notion of, so it is built for the host and executed there
instead. Our build runs it on every change, serving two real requests over a
real port and checking what the client received. The absence of a Run button
costs verification nothing.

```zig
const std = @import("std");
const http = @import("request.zig");

/// Serve exactly one connection, then return. A real server wraps this in a
/// loop and hands each connection to a thread or an event loop; the shape of
/// what happens per connection is unchanged, which is the point.
fn serve(server: *std.Io.net.Server, io: std.Io) void {
    var conn = server.accept(io) catch return;
    defer conn.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buf);

    // Read until the blank line. HTTP puts no length up front, so the server
    // cannot know how much to read: it reads until it sees the end of the
    // header section, and only then does Content-Length tell it about a body.
    var raw: [4096]u8 = undefined;
    var used: usize = 0;
    while (std.mem.find(u8, raw[0..used], "\r\n\r\n") == null) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch break;
        if (used + line.len > raw.len) break;
        @memcpy(raw[used..][0..line.len], line);
        used += line.len;
    }

    var storage: [16][2][]const u8 = undefined;
    const request = http.parse(raw[0..used], &storage) catch {
        respond(&conn, io, 400, "text/plain", "bad request\n");
        return;
    };

    if (std.mem.eql(u8, request.target, "/")) {
        respond(&conn, io, 200, "text/html", "<h1>hello</h1>\n");
    } else {
        respond(&conn, io, 404, "text/plain", "not found\n");
    }
}

/// A response is a status line, headers, a blank line, and the body. The
/// Content-Length is not optional politeness: without it the client cannot
/// know the body has ended, and waits.
fn respond(conn: *std.Io.net.Stream, io: std.Io, status: u16, content_type: []const u8, body: []const u8) void {
    var buf: [1024]u8 = undefined;
    var writer = conn.writer(io, &buf);
    const w = &writer.interface;

    const reason: []const u8 = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        else => "Not Found",
    };

    w.print("HTTP/1.1 {d} {s}\r\n", .{ status, reason }) catch return;
    w.print("Content-Type: {s}\r\n", .{content_type}) catch return;
    w.print("Content-Length: {d}\r\n", .{body.len}) catch return;
    w.writeAll("Connection: close\r\n\r\n") catch return;
    w.writeAll(body) catch return;
    w.flush() catch return;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // Port 0 asks the OS for a free one, so this cannot collide with whatever
    // is already running on the machine.
    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try any_port.listen(io, .{});
    defer server.deinit(io);
    const addr = server.socket.address;

    for ([_][]const u8{ "/", "/nope" }) |target| {
        const thread = try std.Thread.spawn(.{}, serve, .{ &server, io });

        var stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var write_buf: [512]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.print(
            "GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
            .{target},
        );
        try writer.interface.flush();

        var read_buf: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);

        // Read until the peer closes, rather than looping on lines. The server
        // said `Connection: close`, so end of stream is the end of the
        // response, and this is the one framing rule that needs no header.
        var response: [2048]u8 = undefined;
        var got: usize = 0;
        while (true) {
            const n = reader.interface.readSliceShort(response[got..]) catch break;
            if (n == 0) break;
            got += n;
        }

        try out.print("--- GET {s}\n", .{target});
        var lines = std.mem.splitSequence(u8, response[0..got], "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try out.print("{s}\n", .{line});
        }

        thread.join();
    }

    try out.flush();
}
```

*Binds a real socket, so it is built and run on the host by CI rather than in your browser. The output below is what CI checks on every build. (`19-web-server.server`)*

```
--- GET /
HTTP/1.1 200 OK
Content-Type: text/html
Content-Length: 15
Connection: close
<h1>hello</h1>

--- GET /nope
HTTP/1.1 404 Not Found
Content-Type: text/plain
Content-Length: 10
Connection: close
not found
```

## What just happened

**The server reads until it sees a blank line.** Not a fixed number of bytes,
and not one line: a loop that keeps taking lines until the accumulated bytes
contain `\r\n\r\n`. This is the framing rule from the last chapter arriving
where it actually hurts. The bytes are now trickling in from a socket, and
there is no way to know how many are coming.

**`Content-Length` on the response is not politeness.** Without it the client
has no idea the body ended, so it waits, and the request appears to hang. The
alternative is to close the connection and let end-of-stream mark the end,
which is what `Connection: close` announces and what the client here relies
on. Those two mechanisms are the only ways HTTP/1.1 has to end a body. Chunked
encoding is the third, and it exists because neither works for a response
whose length is not known when the headers are sent.

**The routing is one `eql`.** `/` gets HTML, everything else gets a 404. That
is genuinely all routing is at this level: a comparison against the target,
and everything a framework adds sits on top of this.

**The status line carries a number and a phrase.** The number is for programs
and the phrase is for people, and nothing reads the phrase. You can send
`HTTP/1.1 200 Fine` and every client will accept it.

**One connection per `serve` call, then it returns.** A real server wraps this
in a loop and hands each connection to a thread or an event loop, and the
[many clients](https://www.ziglang.in/learn/networking/many-clients/) chapter covers the shapes that
take. What happens *per connection* is unchanged, which is why this is worth
isolating.

## Check yourself

The server never checks the method. `POST /` gets the same HTML as `GET /`.
Beyond being wrong, why does that matter?

Because `GET` is defined to be safe and idempotent, and things you do not
control rely on it. Browsers prefetch links, proxies cache responses, and
crawlers follow every URL they find. A server that performs an action on `GET`
will have that action performed by a caching proxy, a browser's link preview,
and eventually a search engine. The classic version of this is an admin panel
with `GET /delete?id=5` links that a crawler dutifully visited.

Checking the method is one comparison, and the reason it matters is entirely
about what the rest of the world assumes.

## If you have written C

`socket`, `bind`, `listen`, `accept` in a loop, and `read`/`write` on the
returned descriptor. That is the same sequence here, with the difference that
a failed call is an error in the return type rather than `-1` plus `errno`.

Two C-specific hazards this sidesteps. The read into a fixed buffer has to
leave room for a terminator if the result is going to be treated as a string.
Forgetting that is the off-by-one from the strings chapter, on a buffer
holding attacker-controlled bytes. And `write` can be partial on a socket just
as on a pipe, so the C version needs its own loop around it; `writeAll` is
that loop.

The one thing the C version makes obvious that this hides is that a socket is
just a file descriptor. `read` and `write` work on it because they work on
everything, which is the point [file descriptors](https://www.ziglang.in/learn/os/file-descriptors/)
makes at length.

## Where this section goes next

What is here is the protocol and the socket. What a real server adds, in
roughly the order it becomes necessary: serving files from disk with a path
traversal guard, routing with query strings and percent-decoding, form bodies,
cookies and sessions, and a template engine so the HTML stops living inside
string literals. Each is a chapter, and each is mostly parsing, which means
most of them will run in the page.
