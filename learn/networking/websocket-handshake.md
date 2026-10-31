# The WebSocket Handshake

> An HTTP request asks to upgrade, std.http.Server answers 101, and the checks that std leaves to your code.

HTTP is request and response. The client asks, the server answers, and the
server cannot speak first. A chat, a live score or a game needs messages in
both directions at any time. WebSocket gives a TCP connection to the two
sides for that purpose, and it starts as an ordinary HTTP request.

The client sends a `GET` with an `Upgrade: websocket` header. The server
answers `101 Switching Protocols`. After the empty line at the end of that
answer, the connection carries WebSocket frames, not HTTP. This chapter is
about the handshake. [WebSocket Frames](https://www.ziglang.in/learn/networking/websocket-frames/)
is about the frames.

The program below plays both sides in memory. The server is
`std.http.Server`, the same type as in
[An HTTP Round Trip](https://www.ziglang.in/learn/networking/http-roundtrip/).

```zig
const std = @import("std");

/// RFC 6455 fixes this string. Each server appends it to the key of the
/// client, so the answer proves that the server read the request.
const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// The value of `Sec-WebSocket-Accept` for a key: the SHA-1 of the key and
/// the GUID, encoded in base64. A client computes the same value to check
/// the answer of the server.
fn acceptFor(key: []const u8) [28]u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    return accept;
}

/// The value of one header in a request, or null.
fn header(request: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// What the server decides about one request. std finds the upgrade and the
/// key. The checks of the key and the version are for your code to do.
const Decision = union(enum) {
    upgrade: []const u8,
    refuse: std.http.Status,
    plain_http,
};

fn decide(request: *const std.http.Server.Request) Decision {
    switch (request.upgradeRequested()) {
        // HTTP lets a server ignore an upgrade that it does not support.
        .none, .other => return .plain_http,
        .websocket => |maybe_key| {
            const key = maybe_key orelse return .{ .refuse = .bad_request };
            const version = header(request, "sec-websocket-version") orelse "";
            if (!std.mem.eql(u8, version, "13")) return .{ .refuse = .upgrade_required };
            return .{ .upgrade = key };
        },
    }
}

/// Show the bytes of an HTTP head, one line for each header, with the CR LF
/// at the end of each line written out.
fn printHead(out: *std.Io.Writer, bytes: []const u8) !void {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    while (lines.next()) |line| {
        if (lines.peek() == null) break;
        try out.print("  {s}\\r\\n\n", .{line});
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // The worked example from section 1.3 of RFC 6455.
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    try out.print("key:    {s}\n", .{key});
    try out.print("accept: {s}\n\n", .{&acceptFor(key)});

    // The client sends an ordinary GET with four extra headers.
    const request_bytes =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: " ++ key ++ "\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    try out.print("client sends:\n", .{});
    try printHead(out, request_bytes);

    // The server reads from a Reader and writes to a Writer. Here both are
    // buffers in memory. Over a socket, they are the reader and the writer of
    // the stream, and nothing below changes.
    var in: std.Io.Reader = .fixed(request_bytes);
    var response_buf: [256]u8 = undefined;
    var response: std.Io.Writer = .fixed(&response_buf);
    var server = std.http.Server.init(&in, &response);

    var request = try server.receiveHead();
    const accepted_key = switch (decide(&request)) {
        .upgrade => |k| k,
        else => return error.NotAnUpgrade,
    };
    var ws = try request.respondWebSocket(.{ .key = accepted_key });
    try ws.flush();

    try out.print("\nserver answers:\n", .{});
    try printHead(out, response.buffered());

    // The client checks the status and the accept value. If either is wrong,
    // the client must close the connection and not send frames.
    const answer = response.buffered();
    const status_ok = std.mem.startsWith(u8, answer, "HTTP/1.1 101 ");
    const expected = acceptFor(key);
    const accept_ok = std.mem.find(u8, answer, &expected) != null;
    try out.print("\nclient checks: status 101 {s}, accept {s}\n", .{
        if (status_ok) "ok" else "WRONG",
        if (accept_ok) "ok" else "WRONG",
    });

    // The checks that std.http.Server leaves to you. Each request goes to a
    // new server, and `decide` gives the answer.
    try out.print("\nother requests:\n", .{});
    const cases = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "no key", .bytes = "GET / HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n\r\n" },
        .{ .name = "version 8", .bytes = "GET / HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: " ++ key ++ "\r\nSec-WebSocket-Version: 8\r\n\r\n" },
        .{ .name = "upgrade to h2c", .bytes = "GET / HTTP/1.1\r\nUpgrade: h2c\r\n\r\n" },
        .{ .name = "POST with upgrade", .bytes = "POST / HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: " ++ key ++ "\r\nContent-Length: 0\r\n\r\n" },
        .{ .name = "no upgrade", .bytes = "GET / HTTP/1.1\r\n\r\n" },
    };
    for (cases) |case| {
        var case_in: std.Io.Reader = .fixed(case.bytes);
        var sink_buf: [16]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&sink_buf);
        var case_server = std.http.Server.init(&case_in, &sink);
        const case_request = try case_server.receiveHead();
        switch (decide(&case_request)) {
            .upgrade => try out.print("  {s:<18} -> upgrade\n", .{case.name}),
            .refuse => |status| try out.print("  {s:<18} -> refuse with {d} {s}\n", .{
                case.name, @intFromEnum(status), status.phrase().?,
            }),
            .plain_http => try out.print("  {s:<18} -> ordinary HTTP request\n", .{case.name}),
        }
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.websocket-handshake`)*

## The request

```
client sends:
  GET /chat HTTP/1.1\r\n
  Host: example.com\r\n
  Upgrade: websocket\r\n
  Connection: Upgrade\r\n
  Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n
  Sec-WebSocket-Version: 13\r\n
  \r\n
```

Four headers make this request an upgrade request:

- `Upgrade: websocket` names the protocol that the client wants.
- `Connection: Upgrade` tells each proxy on the path that the `Upgrade`
  header is for this connection.
- `Sec-WebSocket-Key` is 16 random bytes in base64. The client makes a new
  key for each connection.
- `Sec-WebSocket-Version: 13` is the version from RFC 6455. No other version
  is in use.

The key is not a secret and it is not security. The key lets the client
check that the server read this request and understood it.

## The answer

The server appends a fixed GUID to the key. RFC 6455 defines the GUID. Then
the server computes the SHA-1 of the result and encodes the 20 bytes in
base64.

```zig
/// The value of `Sec-WebSocket-Accept` for a key: the SHA-1 of the key and
/// the GUID, encoded in base64. A client computes the same value to check
/// the answer of the server.
fn acceptFor(key: []const u8) [28]u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    return accept;
}
```

*Quoted from the source: `acceptFor` from `snippets/11-networking/websocket-handshake.zig`.*

The key in the program is the example from section 1.3 of RFC 6455. The RFC
gives the answer, and CI compares the output with it on each run:

```
key:    dGhlIHNhbXBsZSBub25jZQ==
accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
```

In std, `respondWebSocket` does this computation and writes the answer:

```
server answers:
  HTTP/1.1 101 Switching Protocols\r\n
  connection: upgrade\r\n
  upgrade: websocket\r\n
  sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n
  \r\n
```

`respondWebSocket` writes into the buffer of the writer. It does not send
the bytes. Call `flush` on the `WebSocket` value that it returns, as the
program does. Otherwise the client waits for an answer that is still in your
buffer.

The client must check two things:

1. The status is 101. Any other status means that the server refused, or
   that the server does not know WebSocket.
2. The `Sec-WebSocket-Accept` value is the value that the client computes
   from its own key.

If one check fails, the client closes the connection and sends no frames.

## What std checks, and what it does not

`request.upgradeRequested()` reads the headers and returns one of three
values:

- `.websocket` with the key, or with `null` if the request has no key.
- `.other` with the name of a different protocol, for example `h2c`.
- `.none` for an ordinary request. A `POST` and an HTTP/1.0 request always
  give `.none`, because RFC 6455 requires a `GET` on HTTP/1.1.

The function does not check the version, and it does not refuse a request
without a key. Those checks are for your code:

```zig
fn decide(request: *const std.http.Server.Request) Decision {
    switch (request.upgradeRequested()) {
        // HTTP lets a server ignore an upgrade that it does not support.
        .none, .other => return .plain_http,
        .websocket => |maybe_key| {
            const key = maybe_key orelse return .{ .refuse = .bad_request };
            const version = header(request, "sec-websocket-version") orelse "";
            if (!std.mem.eql(u8, version, "13")) return .{ .refuse = .upgrade_required };
            return .{ .upgrade = key };
        },
    }
}
```

*Quoted from the source: `decide` from `snippets/11-networking/websocket-handshake.zig`.*

```
other requests:
  no key             -> refuse with 400 Bad Request
  version 8          -> refuse with 426 Upgrade Required
  upgrade to h2c     -> ordinary HTTP request
  POST with upgrade  -> ordinary HTTP request
  no upgrade         -> ordinary HTTP request
```

The two refusals are different. A request without a key is not a valid
upgrade request, thus the answer is 400. A request with the wrong version is valid HTTP for a
version that the server does not speak. RFC 6455 tells the server to answer
426 with a `Sec-WebSocket-Version: 13` header, so that the client can try
again. Use the `extra_headers` option of `respond` to add the header.

An upgrade to a protocol that the server does not know is not an error.
HTTP lets a server ignore the `Upgrade` header and answer the request as
ordinary HTTP.

## The layers are the same

The server in the program reads from `std.Io.Reader.fixed` and writes to
`std.Io.Writer.fixed`. Over a socket, the reader and the writer come from
the stream, as in [A TCP Round Trip](https://www.ziglang.in/learn/networking/tcp-echo/). Nothing
else changes. [A WebSocket Server on a Socket](https://www.ziglang.in/learn/networking/websocket-server/)
runs the same handshake over a real connection.

`std.http.Client` has no WebSocket support. A client must write the request
and check the answer itself. [A WebSocket Client](https://www.ziglang.in/learn/networking/websocket-client/)
does that.
