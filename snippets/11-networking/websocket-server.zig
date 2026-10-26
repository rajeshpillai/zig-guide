//! title: A WebSocket Server on a Socket
//! native
//! std.http.Server upgrades a real TCP connection and echoes. The client is
//! the one from the client chapter, imported from its file.

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
