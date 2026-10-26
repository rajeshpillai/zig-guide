//! title: The Chat Server
//! native
//! The protocol, the hub and the frame reader on real sockets. Each
//! connection has a reader task and a writer task. Three clients chat.

const std = @import("std");
const Io = std.Io;
const WebSocket = std.http.Server.WebSocket;
const protocol = @import("chat-protocol.zig");
const chat = @import("chat-hub.zig");
const FrameReader = @import("chat-frames.zig").FrameReader;
const closeCodeFor = @import("chat-frames.zig").closeCodeFor;
const Client = @import("websocket-client.zig").Client;

// ------------------------------------------------------------------ server

/// The only code that writes to the socket of a connection. It sends each
/// frame from the outbox. When the hub or the reader closes the outbox, the
/// writer sends the close frame with the code that the closer set, and
/// ends. Code 1006 means that the connection is gone, and a close frame
/// must never carry it.
fn writeLoop(io: Io, peer: *chat.Peer, ws: *WebSocket) void {
    while (true) {
        const item = peer.outbox.getOne(io) catch break;
        ws.writeMessage(item.line.bytes(), item.opcode) catch return;
    }
    if (peer.close_code == 1006) return;
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, peer.close_code, .big);
    ws.writeMessage(&payload, .connection_close) catch {};
}

/// Put a reply to this client into its own outbox. Only this connection
/// waits if the outbox is full, thus a blocking put is correct here.
fn reply(io: Io, peer: *chat.Peer, opcode: WebSocket.Opcode, bytes: []const u8) void {
    var item: chat.Outgoing = .{ .opcode = opcode, .line = .{} };
    @memcpy(item.line.buf[0..bytes.len], bytes);
    item.line.len = @intCast(bytes.len);
    peer.outbox.putOne(io, item) catch {};
}

fn refuse(io: Io, peer: *chat.Peer, err: protocol.Refusal) void {
    reply(io, peer, .text, protocol.format(.{ .err = err }).bytes());
}

/// Read frames until the client closes or breaks the protocol. On return,
/// `leave` closes the outbox, and the writer sends the close frame.
fn readLoop(io: Io, in: *Io.Reader, peer: *chat.Peer, hub: *chat.Hub) void {
    defer hub.leave(io, peer) catch {};
    // "say " and the longest text fit. A larger message gets close 1009.
    var message: [4 + protocol.max_text]u8 = undefined;
    var frames: FrameReader = .{ .in = in, .buffer = &message };
    while (true) {
        const event = frames.next() catch |err| {
            peer.close_code = closeCodeFor(err);
            return;
        };
        switch (event) {
            .ping => |p| reply(io, peer, .pong, p),
            .pong => {},
            .binary => refuse(io, peer, error.UnknownCommand),
            .close => |c| {
                // Answer with the code of the client. 1005 means "no code",
                // and a close frame must not carry it.
                peer.close_code = if (c.code == 1005) 1000 else c.code;
                return;
            },
            .text => |t| {
                const command = protocol.parseCommand(t) catch |err| {
                    refuse(io, peer, err);
                    continue;
                };
                const result = switch (command) {
                    .nick => |nick| hub.join(io, peer, nick),
                    .say => |text| hub.say(io, peer, text),
                };
                result catch |err| switch (err) {
                    error.Canceled => return,
                    else => |refusal| refuse(io, peer, refusal),
                };
            },
        }
    }
}

/// One connection, as a task. The handshake is std. The frames are the
/// frame reader. The connection closes the TCP stream when both of its
/// tasks are complete. The frame reader reads each close frame to its
/// end, thus nothing is unread, and the server can close first.
fn connection(io: Io, stream: Io.net.Stream, hub: *chat.Hub) void {
    defer stream.close(io);
    var read_buf: [512]u8 = undefined;
    var write_buf: [512]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var http = std.http.Server.init(&reader.interface, &writer.interface);

    var request = http.receiveHead() catch return;
    const key = switch (request.upgradeRequested()) {
        .websocket => |k| k orelse return request.respond("", .{ .status = .bad_request }) catch {},
        .none, .other => return request.respond("a WebSocket chat\n", .{}) catch {},
    };
    var ws = request.respondWebSocket(.{ .key = key }) catch return;
    ws.flush() catch return;

    var storage: [16]chat.Outgoing = undefined;
    var peer: chat.Peer = .{ .outbox = .init(&storage) };
    // `concurrent`, not `async`: the writer blocks on the outbox until the
    // reader closes it. If `async` ran the writer on this thread, the
    // reader would never start.
    var writer_task = io.concurrent(writeLoop, .{ io, &peer, &ws }) catch return;
    readLoop(io, &reader.interface, &peer, hub);
    writer_task.await(io);
}

fn acceptLoop(io: Io, listener: *Io.net.Server, hub: *chat.Hub, group: *Io.Group) void {
    while (true) {
        const stream = listener.accept(io) catch return;
        group.concurrent(io, connection, .{ io, stream, hub }) catch stream.close(io);
    }
}

// ----------------------------------------------------------------- clients

/// One person: a connection, the client from the WebSocket chapter, and
/// a record of each line that the person sent and received.
const Person = struct {
    name: []const u8,
    stream: Io.net.Stream,
    read_buf: [1024]u8,
    write_buf: [1024]u8,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    client: Client,
    log_buf: [1024]u8,
    log: Io.Writer,
    message_buf: [256]u8,

    fn connect(p: *Person, io: Io, name: []const u8, addr: Io.net.IpAddress, random: std.Random) !void {
        p.name = name;
        p.stream = try addr.connect(io, .{ .mode = .stream });
        p.reader = p.stream.reader(io, &p.read_buf);
        p.writer = p.stream.writer(io, &p.write_buf);
        p.client = .{ .in = &p.reader.interface, .out = &p.writer.interface, .random = random };
        p.log = .fixed(&p.log_buf);
        try p.client.sendHandshake("127.0.0.1", "/chat");
        try p.client.finishHandshake();
    }

    fn send(p: *Person, text: []const u8) !void {
        try p.log.print("  -> {s}\n", .{text});
        try p.client.send(.text, text);
    }

    /// Read events until one prints as `expected`. Log each event.
    fn until(p: *Person, expected: []const u8) !void {
        while (true) {
            var line_buf: [192]u8 = undefined;
            const line = switch (try p.client.receive(&p.message_buf)) {
                .text => |t| t,
                .binary => "(binary)",
                .ping => |d| try std.mem.print(&line_buf, "ping {s}", .{d}),
                .pong => |d| try std.mem.print(&line_buf, "pong {s}", .{d}),
                .close => |code| try std.mem.print(&line_buf, "close {d}", .{code}),
            };
            try p.log.print("  <- {s}\n", .{line});
            if (std.mem.eql(u8, line, expected)) return;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [4096]u8 = undefined;
    var file_writer = Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    var hub: chat.Hub = .{};
    const any_port = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try any_port.listen(io, .{});
    defer listener.deinit(io);
    const addr = listener.socket.address;

    var connections: Io.Group = .init;
    var acceptor = try io.concurrent(acceptLoop, .{ io, &listener, &hub, &connections });

    var seed: [8]u8 = undefined;
    io.random(&seed);
    var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));

    // Each action waits until each person who must see the result sees
    // it. The threads of the server then cannot change the order of lines
    // that a person receives, and CI can compare the output.
    var people: [3]Person = undefined;
    const tejas = &people[0];
    const vishaka = &people[1];
    const shivam = &people[2];

    try tejas.connect(io, "tejas", addr, prng.random());
    try tejas.send("nick tejas");
    try tejas.until("welcome tejas (1 online)");

    try vishaka.connect(io, "vishaka", addr, prng.random());
    try vishaka.send("say hi");
    try vishaka.until("error NoNickYet");
    try vishaka.send("nick vishaka");
    try vishaka.until("welcome vishaka (2 online)");
    try tejas.until("joined vishaka");

    try shivam.connect(io, "shivam", addr, prng.random());
    try shivam.send("nick tejas");
    try shivam.until("error NickTaken");
    try shivam.send("nick shivam");
    try shivam.until("welcome shivam (3 online)");
    try tejas.until("joined shivam");
    try vishaka.until("joined shivam");

    try tejas.send("say hello, room");
    for (&people) |*p| try p.until("msg tejas: hello, room");

    try vishaka.log.print("  -> ping beat\n", .{});
    try vishaka.client.send(.ping, "beat");
    try vishaka.until("pong beat");

    try shivam.send("shout hi");
    try shivam.until("error UnknownCommand");

    try shivam.log.print("  -> close 1000\n", .{});
    try shivam.client.close(1000);
    try shivam.until("close 1000");
    try tejas.until("left shivam (quit)");
    try vishaka.until("left shivam (quit)");

    try tejas.send("say bye");
    try tejas.until("msg tejas: bye");
    try vishaka.until("msg tejas: bye");

    try vishaka.log.print("  -> close 1000\n", .{});
    try vishaka.client.close(1000);
    try vishaka.until("close 1000");
    try tejas.until("left vishaka (quit)");

    try tejas.log.print("  -> close 1000\n", .{});
    try tejas.client.close(1000);
    try tejas.until("close 1000");

    for (&people) |*p| p.stream.close(io);
    acceptor.cancel(io);
    connections.cancel(io);

    for (&people) |*p| try out.print("{s}:\n{s}", .{ p.name, p.log.buffered() });
    try out.flush();
}
