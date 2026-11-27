# A WebSocket Server on a Socket

> std.http.Server upgrades a real TCP connection and echoes messages. The server answers pings, closes correctly, and refuses a message that is too big.

The last three chapters used buffers in memory. This chapter uses a real
TCP connection on loopback. The server is `std.http.Server` with its
WebSocket support. The client is the client from
[A WebSocket Client](https://www.ziglang.in/learn/networking/websocket-client/). The program
imports that file with `@import("websocket-client.zig")`.

The client runs here without a change. It reads from the reader of a TCP
stream in place of a fixed buffer. That is the purpose of the rule of this
section: parse from a `Reader`, never from a socket.

```zig
const std = @import("std");
const Client = @import("websocket-client.zig").Client;

/// The largest message this server accepts. readSmallMessage needs the
/// whole frame in the buffer of the reader, thus this buffer is the limit.
const max_message = 512;

/// One connection. The server thread writes what it decides into `log`,
/// and main prints the log after the thread ends. If both threads printed,
/// the order of the lines would change from run to run.
fn handle(conn: std.Io.net.Stream, io: std.Io, log: *std.Io.Writer) !void {
    var read_buf: [max_message]u8 = undefined;
    var write_buf: [max_message + 16]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    var writer = conn.writer(io, &write_buf);
    var http = std.http.Server.init(&reader.interface, &writer.interface);

    var request = try http.receiveHead();
    const key = switch (request.upgradeRequested()) {
        .websocket => |k| k orelse return request.respond("", .{ .status = .bad_request }),
        .none, .other => return request.respond("use a WebSocket client\n", .{}),
    };
    var ws = try request.respondWebSocket(.{ .key = key });
    try ws.flush();
    try log.print("upgraded {s}\n", .{request.head.target});

    while (true) {
        const msg = ws.readSmallMessage() catch |err| {
            const code: u16 = switch (err) {
                // The client started the close handshake.
                error.ConnectionClose => 1000,
                // 1009 means "message too big". A fragmented message gives
                // this error too, because std reads single frames only.
                error.MessageOversize => 1009,
                else => return err,
            };
            var payload: [2]u8 = undefined;
            std.mem.writeInt(u16, &payload, code, .big);
            try ws.writeMessage(&payload, .connection_close);
            try log.print("{t}: sent close {d}\n", .{ err, code });
            // std stops in the middle of the frame that caused the error,
            // thus the rest of the frame is unread. Read until the client
            // closes the TCP connection. If the server closed with unread
            // bytes, the kernel would send a reset to the client.
            _ = reader.interface.discardRemaining() catch {};
            return;
        };
        switch (msg.opcode) {
            .text, .binary => {
                try ws.writeMessage(msg.data, msg.opcode);
                try log.print("echo {t}, {d} bytes\n", .{ msg.opcode, msg.data.len });
            },
            .ping => {
                try ws.writeMessage(msg.data, .pong);
                try log.print("ping: sent pong\n", .{});
            },
            else => unreachable,
        }
    }
}

fn serve(listener: *std.Io.net.Server, io: std.Io, log: *std.Io.Writer) void {
    for (0..2) |_| {
        const conn = listener.accept(io) catch return;
        defer conn.close(io);
        handle(conn, io, log) catch |err| log.print("connection failed: {t}\n", .{err}) catch {};
    }
}

fn printEvent(out: *std.Io.Writer, event: Client.Event) !void {
    switch (event) {
        .text => |t| if (t.len <= 20)
            try out.print("  got text \"{s}\"\n", .{t})
        else
            try out.print("  got text, {d} bytes\n", .{t.len}),
        .binary => |b| try out.print("  got binary, {d} bytes\n", .{b.len}),
        .ping => |p| try out.print("  got ping \"{s}\"\n", .{p}),
        .pong => |p| try out.print("  got pong \"{s}\"\n", .{p}),
        .close => |code| try out.print("  got close {d}\n", .{code}),
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try any_port.listen(io, .{});
    defer listener.deinit(io);
    const addr = listener.socket.address;

    var log_buf: [512]u8 = undefined;
    var log: std.Io.Writer = .fixed(&log_buf);
    const thread = try std.Thread.spawn(.{}, serve, .{ &listener, io, &log });

    // The key and the masks are not in the output, thus a real seed is
    // correct here.
    var seed: [8]u8 = undefined;
    io.random(&seed);
    var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));

    var message_buf: [2048]u8 = undefined;

    // Connection 1: text, a ping, a long text, and a normal close.
    {
        var stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var read_buf: [2048]u8 = undefined;
        var write_buf: [2048]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var writer = stream.writer(io, &write_buf);
        var client: Client = .{ .in = &reader.interface, .out = &writer.interface, .random = prng.random() };

        try client.sendHandshake("127.0.0.1", "/echo");
        try client.finishHandshake();
        try out.print("connection 1:\n", .{});

        try client.send(.text, "hello");
        try printEvent(out, try client.receive(&message_buf));
        try client.send(.ping, "beat");
        try printEvent(out, try client.receive(&message_buf));
        const long: [400]u8 = @splat('z');
        try client.send(.text, &long);
        try printEvent(out, try client.receive(&message_buf));
        try client.close(1000);
        try printEvent(out, try client.receive(&message_buf));
    }

    // Connection 2: a message larger than the server accepts.
    {
        var stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var read_buf: [2048]u8 = undefined;
        var write_buf: [2048]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var writer = stream.writer(io, &write_buf);
        var client: Client = .{ .in = &reader.interface, .out = &writer.interface, .random = prng.random() };

        try client.sendHandshake("127.0.0.1", "/echo");
        try client.finishHandshake();
        try out.print("connection 2:\n", .{});

        const big: [1000]u8 = @splat(7);
        try client.send(.binary, &big);
        try printEvent(out, try client.receive(&message_buf));
    }

    thread.join();
    try out.print("server log:\n", .{});
    var lines = std.mem.splitScalar(u8, log.buffered(), '\n');
    while (lines.next()) |line| {
        if (line.len > 0) try out.print("  {s}\n", .{line});
    }
    try out.flush();
}
```

*CI builds and runs this snippet natively: the server and the client talk over a real loopback socket. Browser wasm has no sockets. (`11-networking.websocket-server`)*

The program makes two connections. The first sends a text, a ping and a
long text, and then closes normally. The second sends a message that is too
big for the server.

```
connection 1:
  got text "hello"
  got pong "beat"
  got text, 400 bytes
  got close 1000
connection 2:
  got close 1009
```

## One connection

```zig
/// One connection. The server thread writes what it decides into `log`,
/// and main prints the log after the thread ends. If both threads printed,
/// the order of the lines would change from run to run.
fn handle(conn: std.Io.net.Stream, io: std.Io, log: *std.Io.Writer) !void {
    var read_buf: [max_message]u8 = undefined;
    var write_buf: [max_message + 16]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    var writer = conn.writer(io, &write_buf);
    var http = std.http.Server.init(&reader.interface, &writer.interface);

    var request = try http.receiveHead();
    const key = switch (request.upgradeRequested()) {
        .websocket => |k| k orelse return request.respond("", .{ .status = .bad_request }),
        .none, .other => return request.respond("use a WebSocket client\n", .{}),
    };
    var ws = try request.respondWebSocket(.{ .key = key });
    try ws.flush();
    try log.print("upgraded {s}\n", .{request.head.target});

    while (true) {
        const msg = ws.readSmallMessage() catch |err| {
            const code: u16 = switch (err) {
                // The client started the close handshake.
                error.ConnectionClose => 1000,
                // 1009 means "message too big". A fragmented message gives
                // this error too, because std reads single frames only.
                error.MessageOversize => 1009,
                else => return err,
            };
            var payload: [2]u8 = undefined;
            std.mem.writeInt(u16, &payload, code, .big);
            try ws.writeMessage(&payload, .connection_close);
            try log.print("{t}: sent close {d}\n", .{ err, code });
            // std stops in the middle of the frame that caused the error,
            // thus the rest of the frame is unread. Read until the client
            // closes the TCP connection. If the server closed with unread
            // bytes, the kernel would send a reset to the client.
            _ = reader.interface.discardRemaining() catch {};
            return;
        };
        switch (msg.opcode) {
            .text, .binary => {
                try ws.writeMessage(msg.data, msg.opcode);
                try log.print("echo {t}, {d} bytes\n", .{ msg.opcode, msg.data.len });
            },
            .ping => {
                try ws.writeMessage(msg.data, .pong);
                try log.print("ping: sent pong\n", .{});
            },
            else => unreachable,
        }
    }
}
```

*Quoted from the source: `handle` from `snippets/11-networking/websocket-server.zig`.*

The function has three parts:

1. `receiveHead` reads the HTTP request, as in
   [An HTTP Round Trip](https://www.ziglang.in/learn/networking/http-roundtrip/).
2. `upgradeRequested` and `respondWebSocket` do the handshake. A request
   with no key gets a 400. An ordinary request gets an ordinary answer.
3. The loop reads messages with `readSmallMessage` and answers each one.

The [handshake chapter](https://www.ziglang.in/learn/networking/websocket-handshake/) also
checks the version header. This server does not, to keep the function
short.

## The size of the buffer is the limit

`readSmallMessage` returns the payload as a slice of the buffer of the
reader. Thus the whole frame must fit in that buffer, and `max_message` is
the largest message that the server accepts. Here it is 512 bytes. The
400-byte text fits. The 1000-byte binary message does not, and std returns
`error.MessageOversize`.

The server answers with close code 1009, "message too big". A message in
fragments gives the same error, because std reads single frames only. For
this server, a message in two fragments is too big. If your clients send
fragments, read the frames yourself, as the client does.

The limit has a second purpose. Without a limit, a client can announce a
length of 2<sup>63</sup> bytes, and a server that allocates for the length
fails. A fixed buffer refuses that frame before it reads the payload.

## Ping and close are your work

std returns a ping to your code, and the server answers with
`writeMessage(msg.data, .pong)`. A client can send pings to check
that the connection is alive. If no pong arrives, the client can close the
connection.

std returns a close frame as `error.ConnectionClose`. The server sends its
own close frame. The close handshake has one more problem: std stops after
the first two bytes of the close frame. Thus the mask and the status code of
the client are still unread in the stream.

If a TCP socket closes with unread bytes in its receive buffer, the kernel
sends a reset (RST) in place of a normal close. The client can then get
an error for a reset connection before it reads the close frame from the
server. Thus the server calls `discardRemaining` on its reader. The call
reads and discards bytes until the client closes the connection.

RFC 6455 says that the server should close the TCP connection first. This
server lets the client close first, because std does not give the length of
the rest of the frame. To close first, read the frame yourself and discard
exactly the rest of it.

## The log comes from the server thread

```
server log:
  upgraded /echo
  echo text, 5 bytes
  ping: sent pong
  echo text, 400 bytes
  ConnectionClose: sent close 1000
  upgraded /echo
  MessageOversize: sent close 1009
```

The server thread writes into a buffer, and `main` prints the buffer after
`thread.join()`. If both threads printed, the order of the lines could
change from run to run, and CI could not compare the output.

## One client at a time

This server serves one connection and then the next. A WebSocket
connection stays open for a long time, thus a real server needs a task for
each connection. [Serve Many Clients](https://www.ziglang.in/learn/networking/many-clients/) shows
the pattern with `std.Io`. Use it with the `handle` function above.

## When std is not enough

The WebSocket support in std is small. It exists for the web interface of
the Zig build system (`zig build --webui`). This list shows what a server
for the open internet needs in addition:

| Need | std.http.Server | What to do |
|---|---|---|
| Messages in fragments | refused | read the frames yourself |
| Large messages | refused | a larger buffer, or stream the frames |
| Answer to a ping | your code | `writeMessage(data, .pong)` |
| Close handshake | your code | send close, then drain |
| Compression | no | `permessage-deflate` |
| A client | no | [write one](https://www.ziglang.in/learn/networking/websocket-client/) |

[websocket.zig](https://github.com/karlseguin/websocket.zig) by Karl Seguin
is a complete library for Zig, under the MIT licence. It has a server and a
client. It answers ping and close frames, supports compression, and runs
connections on a thread pool. On 2026-10-26, its readme said that it is for
Zig 0.17.0, with branches for older versions. This guide tracks Zig master,
thus no snippet here depends on the library. Check the readme for the
version that it supports today.
