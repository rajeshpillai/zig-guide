# A WebSocket Client

> A client that std does not have. It checks the handshake, masks each frame, puts fragments together, answers a ping, and closes correctly.

`std.http.Client` has no WebSocket support. Thus a Zig program that
connects to a WebSocket server needs its own client. The client is about 170
lines. It has five tasks:

1. Send the upgrade request with a random key, and check the answer.
2. Mask each frame with a new random mask.
3. Put a message in fragments together.
4. Answer each ping with a pong, also in the middle of a message.
5. Complete the close handshake.

The client reads from a `std.Io.Reader` and writes to a `std.Io.Writer`. It
never sees a socket. Thus the program below runs in your browser: it plays
the server in memory with `std.http.Server`, and you can see the bytes in
each direction.
[A WebSocket Server on a Socket](https://www.ziglang.in/learn/networking/websocket-server/)
imports this file and uses the same client over a real TCP connection.

```zig
const std = @import("std");
const Opcode = std.http.Server.WebSocket.Opcode;
const Header0 = std.http.Server.WebSocket.Header0;
const Header1 = std.http.Server.WebSocket.Header1;

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub fn acceptFor(key: []const u8) [28]u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    return accept;
}

pub const Client = struct {
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    /// The source of the key and of each mask. RFC 6455 requires a new,
    /// unpredictable mask for each frame.
    random: std.Random,
    key: [24]u8 = undefined,
    /// True after this side sends a close frame.
    closing: bool = false,
    /// The type of the message in fragments, and its bytes so far. These are
    /// fields, not locals: a ping can arrive between two fragments, and
    /// `receive` returns for the ping before the message is complete.
    fragment: ?Opcode = null,
    fragment_len: usize = 0,

    pub const Event = union(enum) {
        text: []const u8,
        binary: []const u8,
        /// The client answered the ping with a pong. The event is for the log.
        ping: []const u8,
        pong: []const u8,
        /// The status code of the close frame. 1005 means that it had none.
        close: u16,
    };

    pub const Error = error{
        UpgradeRefused,
        BadAccept,
        MaskedServerFrame,
        ProtocolError,
        MessageTooBig,
        InvalidUtf8,
    } || std.Io.Reader.DelimiterError || std.Io.Writer.Error;

    /// Send the HTTP request that asks for the upgrade. The key is 16
    /// random bytes in base64.
    pub fn sendHandshake(c: *Client, host: []const u8, path: []const u8) Error!void {
        var nonce: [16]u8 = undefined;
        c.random.bytes(&nonce);
        _ = std.base64.standard.Encoder.encode(&c.key, &nonce);
        try c.out.print(
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ path, host, &c.key },
        );
        try c.out.flush();
    }

    /// Read the answer of the server. Frames start after the empty line.
    pub fn finishHandshake(c: *Client) Error!void {
        const status = try c.in.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, status, "HTTP/1.1 101 ")) return error.UpgradeRefused;
        const expected = acceptFor(&c.key);
        var accept_ok = false;
        while (true) {
            const line = std.mem.trimEnd(u8, try c.in.takeDelimiterInclusive('\n'), "\r\n");
            if (line.len == 0) break;
            const colon = std.mem.findScalar(u8, line, ':') orelse return error.ProtocolError;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
                accept_ok = std.mem.eql(u8, value, &expected);
            }
        }
        if (!accept_ok) return error.BadAccept;
    }

    /// Send one frame. A client masks each frame with a new mask.
    pub fn send(c: *Client, opcode: Opcode, payload: []const u8) Error!void {
        var mask: [4]u8 = undefined;
        c.random.bytes(&mask);
        try c.out.writeByte(@bitCast(Header0{ .opcode = opcode, .fin = true }));
        if (payload.len <= 125) {
            try c.out.writeByte(@bitCast(Header1{ .payload_len = @enumFromInt(payload.len), .mask = true }));
        } else if (payload.len <= 0xffff) {
            try c.out.writeByte(@bitCast(Header1{ .payload_len = .len16, .mask = true }));
            try c.out.writeInt(u16, @intCast(payload.len), .big);
        } else {
            try c.out.writeByte(@bitCast(Header1{ .payload_len = .len64, .mask = true }));
            try c.out.writeInt(u64, payload.len, .big);
        }
        try c.out.writeAll(&mask);
        for (payload, 0..) |b, i| try c.out.writeByte(b ^ mask[i % 4]);
        try c.out.flush();
    }

    /// Start the close handshake. The server answers with its own close
    /// frame, which `receive` returns as `.close`.
    pub fn close(c: *Client, code: u16) Error!void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, code, .big);
        try c.send(.connection_close, &payload);
        c.closing = true;
    }

    /// Return the next event. A message in fragments is put together in
    /// `buffer`, thus give the same buffer to each call. A ping gets its pong
    /// here, also in the middle of a message.
    pub fn receive(c: *Client, buffer: []u8) Error!Event {
        while (true) {
            const header = try c.in.takeArray(2);
            const h0: Header0 = @bitCast(header[0]);
            const h1: Header1 = @bitCast(header[1]);
            // The mask is for frames from a client. A server must not mask.
            if (h1.mask) return error.MaskedServerFrame;
            const len: u64 = switch (h1.payload_len) {
                .len16 => try c.in.takeInt(u16, .big),
                .len64 => try c.in.takeInt(u64, .big),
                else => @intFromEnum(h1.payload_len),
            };

            switch (h0.opcode) {
                .ping, .pong, .connection_close => {
                    // A control frame is short and never in fragments.
                    if (len > 125 or !h0.fin) return error.ProtocolError;
                    const payload = try c.in.take(@intCast(len));
                    switch (h0.opcode) {
                        .ping => {
                            var copy: [125]u8 = undefined;
                            @memcpy(copy[0..payload.len], payload);
                            try c.send(.pong, copy[0..payload.len]);
                            return .{ .ping = payload };
                        },
                        .pong => return .{ .pong = payload },
                        else => {
                            const code: u16 = if (payload.len >= 2) std.mem.readInt(u16, payload[0..2], .big) else 1005;
                            // If the server closes first, send the same code back.
                            if (!c.closing) try c.close(code);
                            return .{ .close = code };
                        },
                    }
                },
                .text, .binary => {
                    if (c.fragment != null) return error.ProtocolError;
                    c.fragment = h0.opcode;
                    c.fragment_len = 0;
                },
                .continuation => if (c.fragment == null) return error.ProtocolError,
                _ => return error.ProtocolError,
            }

            const used = c.fragment_len;
            if (len > buffer.len - used) return error.MessageTooBig;
            try c.in.readSliceAll(buffer[used..][0..@intCast(len)]);
            c.fragment_len += @intCast(len);
            if (!h0.fin) continue;

            const data = buffer[0..c.fragment_len];
            const opcode = c.fragment.?;
            c.fragment = null;
            if (opcode == .binary) return .{ .binary = data };
            if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
            return .{ .text = data };
        }
    }
};

// Everything below is the demonstration. It plays the server in memory, so
// the bytes of each direction are visible.

/// A server frame that std cannot write: the first frame of a message, or a
/// continuation. std writes complete messages only.
fn writeServerFrame(w: *std.Io.Writer, opcode: Opcode, fin: bool, payload: []const u8) !void {
    try w.writeByte(@bitCast(Header0{ .opcode = opcode, .fin = fin }));
    try w.writeByte(@bitCast(Header1{ .payload_len = @enumFromInt(payload.len), .mask = false }));
    try w.writeAll(payload);
}

/// List the frames that the server wrote, after the HTTP head. All of them
/// are short and unmasked, thus each header is two bytes.
fn printServerFrames(out: *std.Io.Writer, bytes: []const u8) !void {
    const body = bytes[(std.mem.find(u8, bytes, "\r\n\r\n").? + 4)..];
    try out.print("server sends 101, then these frames:\n", .{});
    var i: usize = 0;
    while (i < body.len) {
        const h0: Header0 = @bitCast(body[i]);
        const len = body[i + 1];
        const payload = body[i + 2 ..][0..len];
        try out.print("  {t:<16} fin={d} ", .{ h0.opcode, @intFromBool(h0.fin) });
        if (h0.opcode == .connection_close) {
            try out.print("code {d}\n", .{std.mem.readInt(u16, payload[0..2], .big)});
        } else {
            try out.print("\"{s}\"\n", .{payload});
        }
        i += 2 + len;
    }
}

fn printEvent(out: *std.Io.Writer, event: Client.Event) !void {
    switch (event) {
        .text => |t| try out.print("  text \"{s}\"\n", .{t}),
        .binary => |b| try out.print("  binary, {d} bytes\n", .{b.len}),
        .ping => |p| try out.print("  ping \"{s}\", answered with a pong\n", .{p}),
        .pong => |p| try out.print("  pong \"{s}\"\n", .{p}),
        .close => |code| try out.print("  close {d}, answered with close {d}\n", .{ code, code }),
    }
}

/// Give the client a server answer, and print what the client decides.
fn clientRejects(out: *std.Io.Writer, name: []const u8, key: [24]u8, head: []const u8, frames: []const u8) !void {
    var answer: [256]u8 = undefined;
    @memcpy(answer[0..head.len], head);
    @memcpy(answer[head.len..][0..frames.len], frames);
    var in: std.Io.Reader = .fixed(answer[0 .. head.len + frames.len]);
    var unused: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&unused);
    var prng = std.Random.DefaultPrng.init(1);
    var c: Client = .{ .in = &in, .out = &sink, .random = prng.random(), .key = key };
    var buffer: [64]u8 = undefined;
    const result = if (c.finishHandshake()) c.receive(&buffer) else |err| err;
    if (result) |event| {
        try out.print("  {s:<24} -> accepted: ", .{name});
        try printEvent(out, event);
    } else |err| {
        try out.print("  {s:<24} -> error.{t}\n", .{ name, err });
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // A fixed seed gives the same key and masks on each run, thus CI can
    // compare the output. A real client takes its seed from `io.random`.
    var prng = std.Random.DefaultPrng.init(2026);

    // Two wires, one for each direction.
    var to_server_buf: [1024]u8 = undefined;
    var to_server: std.Io.Writer = .fixed(&to_server_buf);
    var to_client_buf: [1024]u8 = undefined;
    var to_client: std.Io.Writer = .fixed(&to_client_buf);
    var client_in: std.Io.Reader = .fixed("");

    var client: Client = .{ .in = &client_in, .out = &to_server, .random = prng.random() };

    // 1. The client asks for the upgrade.
    try client.sendHandshake("example.com", "/chat");
    try out.print("client key: {s}\n", .{&client.key});

    // 2. The server, with std. It answers 101, then sends four frames.
    var server_in: std.Io.Reader = .fixed(to_server.buffered());
    var http = std.http.Server.init(&server_in, &to_client);
    var request = try http.receiveHead();
    const key = request.upgradeRequested().websocket.?;
    var ws = try request.respondWebSocket(.{ .key = key });
    try ws.writeMessage("welcome", .text);
    try writeServerFrame(&to_client, .text, false, "Hel");
    try writeServerFrame(&to_client, .ping, true, "beat");
    try writeServerFrame(&to_client, .continuation, true, "lo");
    try ws.writeMessage(&.{ 0x03, 0xe8 }, .connection_close);
    try ws.flush();
    try printServerFrames(out, to_client.buffered());

    // 3. The client reads the answer and the frames.
    client_in = .fixed(to_client.buffered());
    to_server = .fixed(&to_server_buf);
    try client.finishHandshake();
    try out.print("\nclient: status 101 and accept ok\n", .{});
    try client.send(.text, "hi");
    try out.print("client sends \"hi\": ", .{});
    for (to_server.buffered(), 0..) |b, i| {
        if (i > 0) try out.writeByte(' ');
        try out.print("{x:0>2}", .{b});
    }
    try out.print("\nclient receives:\n", .{});
    var message_buf: [64]u8 = undefined;
    while (true) {
        const event = try client.receive(&message_buf);
        try printEvent(out, event);
        if (event == .close) break;
    }

    // 4. std reads what the client sent: the text, the pong, the close.
    var reply_in: std.Io.Reader = .fixed(to_server.buffered());
    ws.input = &reply_in;
    try out.print("\nstd reads the frames of the client:\n", .{});
    while (true) {
        if (ws.readSmallMessage()) |msg| {
            try out.print("  {t} \"{s}\"\n", .{ msg.opcode, msg.data });
        } else |err| {
            try out.print("  error.{t}\n", .{err});
            break;
        }
    }

    // 5. Server answers that the client must refuse.
    try out.print("\nthe client refuses:\n", .{});
    var head_buf: [128]u8 = undefined;
    const ok = try std.mem.print(&head_buf, "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{&acceptFor(&client.key)});
    const k = client.key;
    try clientRejects(out, "200 OK", k, "HTTP/1.1 200 OK\r\n\r\n", "");
    try clientRejects(out, "wrong accept", k, "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n", "");
    try clientRejects(out, "no accept", k, "HTTP/1.1 101 Switching Protocols\r\n\r\n", "");
    try clientRejects(out, "masked server frame", k, ok, "\x81\x82\x00\x00\x00\x00hi");
    try clientRejects(out, "continuation first", k, ok, "\x80\x02lo");
    try clientRejects(out, "ping of 126 bytes", k, ok, "\x89\x7e\x00\x7e");
    try clientRejects(out, "text that is not UTF-8", k, ok, "\x81\x02\xc3\x28");
    try clientRejects(out, "70 bytes, 64-byte buffer", k, ok, "\x82\x46");

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.websocket-client`)*

## The handshake

The key is 16 random bytes in base64. The client keeps the key, because it
needs the key again to check the answer.

```zig
    /// Send the HTTP request that asks for the upgrade. The key is 16
    /// random bytes in base64.
    pub fn sendHandshake(c: *Client, host: []const u8, path: []const u8) Error!void {
        var nonce: [16]u8 = undefined;
        c.random.bytes(&nonce);
        _ = std.base64.standard.Encoder.encode(&c.key, &nonce);
        try c.out.print(
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ path, host, &c.key },
        );
        try c.out.flush();
    }
```

*Quoted from the source: `sendHandshake` from `snippets/11-networking/websocket-client.zig`.*

The program makes the random numbers with `std.Random.DefaultPrng` and a
fixed seed. Thus the key is the same on each run, and CI can compare the
output. A real client takes the seed from `io.random`, as the server chapter
does. The RFC requires a key and masks that a script cannot predict.

The request and the answer are split into two functions, because a server
must read the request before it answers. Over a socket, call the two
functions one after the other.

```zig
    /// Read the answer of the server. Frames start after the empty line.
    pub fn finishHandshake(c: *Client) Error!void {
        const status = try c.in.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, status, "HTTP/1.1 101 ")) return error.UpgradeRefused;
        const expected = acceptFor(&c.key);
        var accept_ok = false;
        while (true) {
            const line = std.mem.trimEnd(u8, try c.in.takeDelimiterInclusive('\n'), "\r\n");
            if (line.len == 0) break;
            const colon = std.mem.findScalar(u8, line, ':') orelse return error.ProtocolError;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
                accept_ok = std.mem.eql(u8, value, &expected);
            }
        }
        if (!accept_ok) return error.BadAccept;
    }
```

*Quoted from the source: `finishHandshake` from `snippets/11-networking/websocket-client.zig`.*

`finishHandshake` reads the head line by line with
`takeDelimiterInclusive`. After the empty line, the next byte in the reader
is the first byte of the first frame. The reader can hold frames that came
in the same TCP packet as the answer, and the client keeps them for
`receive`.

## Send a frame

```zig
    /// Send one frame. A client masks each frame with a new mask.
    pub fn send(c: *Client, opcode: Opcode, payload: []const u8) Error!void {
        var mask: [4]u8 = undefined;
        c.random.bytes(&mask);
        try c.out.writeByte(@bitCast(Header0{ .opcode = opcode, .fin = true }));
        if (payload.len <= 125) {
            try c.out.writeByte(@bitCast(Header1{ .payload_len = @enumFromInt(payload.len), .mask = true }));
        } else if (payload.len <= 0xffff) {
            try c.out.writeByte(@bitCast(Header1{ .payload_len = .len16, .mask = true }));
            try c.out.writeInt(u16, @intCast(payload.len), .big);
        } else {
            try c.out.writeByte(@bitCast(Header1{ .payload_len = .len64, .mask = true }));
            try c.out.writeInt(u64, payload.len, .big);
        }
        try c.out.writeAll(&mask);
        for (payload, 0..) |b, i| try c.out.writeByte(b ^ mask[i % 4]);
        try c.out.flush();
    }
```

*Quoted from the source: `send` from `snippets/11-networking/websocket-client.zig`.*

`send` is `writeClientFrame` from
[WebSocket Frames](https://www.ziglang.in/learn/networking/websocket-frames/), with a random mask
for each frame. The program prints one frame. The mask is the four bytes
after `81 82`:

```
client sends "hi": 81 82 cd 0a 77 67 a5 63
```

## Receive: fragments and control frames

A sender can split one message into frames. The first frame has the opcode
`text` or `binary` and no `fin` bit. Each next frame has the opcode
`continuation`. The last frame has the `fin` bit. The server in the program
sends a message in two fragments, with a ping between them:

```
server sends 101, then these frames:
  text             fin=1 "welcome"
  text             fin=0 "Hel"
  ping             fin=1 "beat"
  continuation     fin=1 "lo"
  connection_close fin=1 code 1000
```

RFC 6455 lets a control frame (ping, pong or close) arrive between two
fragments. A server that sends a large message must still answer a ping from
the client. Control frames have two rules of their own: the payload is 125
bytes or fewer, and a control frame is never in fragments.

*Figure: 5 frames from a server, including a text message in two fragments with a ping between them, and what the client does for each frame. The frames and the events from the program above, one step for each frame.*

```zig
    /// Return the next event. A message in fragments is put together in
    /// `buffer`, thus give the same buffer to each call. A ping gets its pong
    /// here, also in the middle of a message.
    pub fn receive(c: *Client, buffer: []u8) Error!Event {
        while (true) {
            const header = try c.in.takeArray(2);
            const h0: Header0 = @bitCast(header[0]);
            const h1: Header1 = @bitCast(header[1]);
            // The mask is for frames from a client. A server must not mask.
            if (h1.mask) return error.MaskedServerFrame;
            const len: u64 = switch (h1.payload_len) {
                .len16 => try c.in.takeInt(u16, .big),
                .len64 => try c.in.takeInt(u64, .big),
                else => @intFromEnum(h1.payload_len),
            };

            switch (h0.opcode) {
                .ping, .pong, .connection_close => {
                    // A control frame is short and never in fragments.
                    if (len > 125 or !h0.fin) return error.ProtocolError;
                    const payload = try c.in.take(@intCast(len));
                    switch (h0.opcode) {
                        .ping => {
                            var copy: [125]u8 = undefined;
                            @memcpy(copy[0..payload.len], payload);
                            try c.send(.pong, copy[0..payload.len]);
                            return .{ .ping = payload };
                        },
                        .pong => return .{ .pong = payload },
                        else => {
                            const code: u16 = if (payload.len >= 2) std.mem.readInt(u16, payload[0..2], .big) else 1005;
                            // If the server closes first, send the same code back.
                            if (!c.closing) try c.close(code);
                            return .{ .close = code };
                        },
                    }
                },
                .text, .binary => {
                    if (c.fragment != null) return error.ProtocolError;
                    c.fragment = h0.opcode;
                    c.fragment_len = 0;
                },
                .continuation => if (c.fragment == null) return error.ProtocolError,
                _ => return error.ProtocolError,
            }

            const used = c.fragment_len;
            if (len > buffer.len - used) return error.MessageTooBig;
            try c.in.readSliceAll(buffer[used..][0..@intCast(len)]);
            c.fragment_len += @intCast(len);
            if (!h0.fin) continue;

            const data = buffer[0..c.fragment_len];
            const opcode = c.fragment.?;
            c.fragment = null;
            if (opcode == .binary) return .{ .binary = data };
            if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
            return .{ .text = data };
        }
    }
```

*Quoted from the source: `receive` from `snippets/11-networking/websocket-client.zig`.*

The state of the message in fragments is in two fields of `Client`:
`fragment` and `fragment_len`. The first version of this client kept that
state in local variables of `receive`. That version failed on this exact
input. `receive` returned for the ping, the locals were lost, and the next
call saw a `continuation` with no message open. It returned
`error.ProtocolError`.

The bug gives a rule. If a function can return in the middle of
a message, keep the state of the message outside the function.

The client prints each event:

```
client receives:
  text "welcome"
  ping "beat", answered with a pong
  text "Hello"
  close 1000, answered with close 1000
```

A text message must be valid UTF-8, and the client checks it after the last
fragment. The check must wait for the last fragment, because a fragment
boundary can split one character.

## The close handshake

A close is a handshake too. One side sends a close frame with a 2-byte
status code. The other side answers with a close frame, and then the TCP
connection closes. 1000 is a normal close. 1009 means that a message was too
big. The client reports a close frame with no code as 1005.

If the server closes first, `receive` answers with the same code. If the
client calls `close`, the `closing` field stops a second close frame, and
`receive` returns the answer of the server.

std reads the frames of the client and confirms the order:

```
std reads the frames of the client:
  text "hi"
  error.ConnectionClose
```

The pong for "beat" is between those two frames. std skips pong frames, thus
it does not show in the list.

## What the client refuses

```
the client refuses:
  200 OK                   -> error.UpgradeRefused
  wrong accept             -> error.BadAccept
  no accept                -> error.BadAccept
  masked server frame      -> error.MaskedServerFrame
  continuation first       -> error.ProtocolError
  ping of 126 bytes        -> error.ProtocolError
  text that is not UTF-8   -> error.InvalidUtf8
  70 bytes, 64-byte buffer -> error.MessageTooBig
```

The "wrong accept" line uses the accept value from the RFC example. That
value is correct for the key in the RFC, and wrong for the key of this
client. Thus a server that sends a fixed answer fails the check.

After an error, the client must close the TCP connection. The RFC calls this
"fail the WebSocket connection". A real client also sends a close frame
first, with code 1002 for a protocol error or 1007 for text that is not
UTF-8.

## What this client does not do

- **TLS.** A `wss://` URL is WebSocket over TLS. Connect with TLS first,
  then give the reader and the writer of the TLS stream to the client.
  Nothing in the client changes.
- **Compression.** The `permessage-deflate` extension sets a reserved bit
  and compresses each message. The client does not ask for it in the
  handshake, thus a correct server does not use it.
- **Large messages.** The caller supplies the buffer, and a message larger
  than the buffer gives `error.MessageTooBig`. A client that streams a large
  message must return each fragment to the caller.
