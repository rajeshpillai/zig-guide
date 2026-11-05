# An HTTP Server

> The parser from the last chapter, with a socket in front of the parser.

The parser takes bytes and returns a request. A server is the parser, plus a
source for the bytes and a destination for the answer. This chapter has little
new code, because the parser is already complete.

## The program

This program has no Run button. The program binds a listening socket, and the
browser sandbox has no sockets. Thus the build makes the program for the host
and runs the program there. CI runs the program on each change. The program
serves two real requests over a real port, and CI checks what the client
received. Without the Run button, the verification is the same.

```zig
const std = @import("std");
const http = @import("request.zig");

/// Serve exactly one connection, then return. A real server puts this function
/// in a loop, and gives each connection to a thread or to an event loop. The
/// work for each connection does not change.
fn serve(server: *std.Io.net.Server, io: std.Io) void {
    var conn = server.accept(io) catch return;
    defer conn.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buf);

    // Read until the blank line. HTTP does not give a length at the start.
    // Thus the server cannot know how much to read. The server reads until it
    // finds the end of the header section. After that, Content-Length gives
    // the size of a body.
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
/// Content-Length is necessary. Without it, the client cannot know that the
/// body ended, and the client waits.
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

    // Port 0 asks the OS for a free port. Thus the server cannot use the same
    // port as a different program on the machine.
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

        // Read until the peer closes the connection. Do not read line by line.
        // The server sent `Connection: close`, thus the end of the stream is
        // the end of the response. Only this framing rule needs no header.
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

*This program binds a real socket. Thus CI builds and runs the program on the host, not in your browser. CI checks the output below on each build. (`19-web-server.server`)*

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

## What the program did

**The server reads until it finds a blank line.** The server does not read a
fixed number of bytes, and it does not read only one line. A loop reads lines
until the collected bytes contain `\r\n\r\n`. This is the framing rule from the
last chapter, and here the rule is important in practice. The bytes now come
slowly from a socket, and the server cannot know how many bytes will come.

**`Content-Length` on the response has a purpose.** Without the header, the
client cannot know that the body ended. Thus the client waits, and the request
seems to stop.

The alternative is to close the connection. Then the end of the stream marks
the end of the body. `Connection: close` tells the client about this choice,
and the client in this program uses it. Chunked encoding is the third way.
Chunked encoding exists for a response with a length that is not known when the
server sends the headers. The other two ways do not work for that response.

**The routing is one `eql`.** The target `/` gets HTML, and all other targets
get a 404. At this level, routing is only a comparison with the target.

**The status line has a number and a phrase.** The number is for programs, and
the phrase is for people. No program reads the phrase. You can send
`HTTP/1.1 200 Fine`, and all clients will accept it.

**Each `serve` call handles one connection, then returns.** A production server
puts this function in a loop. The loop gives each connection to a thread or to
an event loop. The [many clients](https://www.ziglang.in/learn/networking/many-clients/) chapter shows
these designs. The work for each connection does not change, thus you can study
that work alone.

## Check yourself

The server does not check the method. `POST /` gets the same HTML as `GET /`.
This behaviour is incorrect, but why is it also a risk?

The answer: the HTTP rules define `GET` as safe and idempotent, and software
that you do not control relies on this rule. Browsers prefetch links, proxies
cache responses, and crawlers follow each URL that they find. Suppose a server
does an action on `GET`. Then a caching proxy, the link preview in a browser,
and at some time a search engine will do that action. The usual example is an
admin panel with `GET /delete?id=5` links, and a crawler that visited those
links.

A check of the method is one comparison. The check is important because of what
other software expects from `GET`.

## If you know C

In C, the sequence is `socket`, `bind`, `listen`, then `accept` in a loop, and
`read`/`write` on the returned descriptor. The sequence here is the same. The
difference is that a failed call is an error in the return type, not `-1` plus
`errno`.

This version prevents two hazards that are specific to C:

- A read into a fixed buffer must keep space for a terminator if the program
  uses the result as a string. If you forget the space, you get the off-by-one
  error from the strings chapter, on a buffer that holds bytes from an
  attacker.
- On a socket, `write` can write only part of the data, the same as on a pipe.
  Thus the C version needs its own loop around `write`. `writeAll` is that loop.

The C version shows one thing clearly that this version hides: a socket is
only a file descriptor. `read` and `write` work on a socket because they work
on all file descriptors. The [file descriptors](https://www.ziglang.in/learn/os/file-descriptors/)
chapter gives the details.

## The next chapters in this section

This chapter has the protocol and the socket. A production server adds more
parts. In approximately the order that a server needs them, the parts are:

1. Files from disk, with a guard against path traversal.
2. Routing with query strings and percent-decoding.
3. Form bodies.
4. Cookies and sessions.
5. A template engine, so the HTML is not in string literals.

Each part is a chapter. Each part is mostly parsing, thus most of the chapters
will run in the page.
