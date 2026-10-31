# Read the Frames Yourself

> A frame reader for the server. It joins fragments, returns the close code, checks UTF-8 and the size, and maps each failure to a close code.

[WebSocket Frames](https://www.ziglang.in/learn/networking/websocket-frames/) listed what
`readSmallMessage` in std refuses or leaves out. Two of those gaps matter
for this server:

- **Fragments.** A browser can split a message into frames. std returns
  `error.MessageOversize` for the first fragment.
- **The close frame.** std stops after the first two bytes. The server does
  not get the close code, and the rest of the frame stays unread in the
  stream.

The second gap has a cost that is easy to miss. If the server closes its
socket with unread bytes, the kernel sends a reset in place of a normal
close. Thus the server in
[A WebSocket Server on a Socket](https://www.ziglang.in/learn/networking/websocket-server/) had to
wait for the client to close first. RFC 6455 asks for the opposite order.

The client in [A WebSocket Client](https://www.ziglang.in/learn/networking/websocket-client/)
already reads frames itself. This reader is the server half of that code,
with three differences:

1. Each frame from a client **must** have the mask, and the reader removes
   it.
2. The reserved bits must be 0, because the server agreed to no extension.
3. The reader reads a close frame to its end, and returns the code and the
   reason.

```zig
const std = @import("std");
const WebSocket = std.http.Server.WebSocket;
const Opcode = WebSocket.Opcode;

/// Reads frames from a client. It does the work that `readSmallMessage`
/// leaves to you. It joins fragments and answers nothing by itself. It reads
/// each frame to its end, thus it never stops in the middle of a frame.
pub const FrameReader = struct {
    in: *std.Io.Reader,
    /// The message so far. Its length is the largest message accepted.
    buffer: []u8,
    fragment: ?Opcode = null,
    fragment_len: usize = 0,

    pub const Event = union(enum) {
        text: []const u8,
        binary: []const u8,
        ping: []const u8,
        pong: []const u8,
        /// 1005 if the frame had no code.
        close: struct { code: u16, reason: []const u8 },
    };

    pub const Error = error{
        UnmaskedFrame,
        ReservedBits,
        ProtocolError,
        MessageTooBig,
        InvalidUtf8,
    } || std.Io.Reader.Error;

    pub fn next(r: *FrameReader) Error!Event {
        while (true) {
            const header = try r.in.takeArray(2);
            const h0: WebSocket.Header0 = @bitCast(header[0]);
            const h1: WebSocket.Header1 = @bitCast(header[1]);
            // No extension is in use, thus each reserved bit must be 0.
            if (h0.rsv1 != 0 or h0.rsv2 != 0 or h0.rsv3 != 0) return error.ReservedBits;
            if (!h1.mask) return error.UnmaskedFrame;
            const len: u64 = switch (h1.payload_len) {
                .len16 => try r.in.takeInt(u16, .big),
                .len64 => try r.in.takeInt(u64, .big),
                else => @backingInt(h1.payload_len),
            };
            const control = switch (h0.opcode) {
                .ping, .pong, .connection_close => true,
                .text, .binary, .continuation => false,
                _ => return error.ProtocolError,
            };

            // Control frames are short and complete, and they can arrive
            // between two fragments. They use their own small buffer, so
            // the message in `buffer` stays as it is.
            if (control) {
                if (len > 125 or !h0.fin) return error.ProtocolError;
                const mask = (try r.in.takeArray(4)).*;
                const payload = try r.in.take(@intCast(len));
                unmask(payload, mask);
                switch (h0.opcode) {
                    .ping => return .{ .ping = payload },
                    .pong => return .{ .pong = payload },
                    else => return closeEvent(payload),
                }
            }

            switch (h0.opcode) {
                .continuation => if (r.fragment == null) return error.ProtocolError,
                else => {
                    if (r.fragment != null) return error.ProtocolError;
                    r.fragment = h0.opcode;
                    r.fragment_len = 0;
                },
            }
            // Refuse a frame that is too big before you read its payload.
            // The length is 8 bytes from the client, and it can be anything.
            if (len > r.buffer.len - r.fragment_len) return error.MessageTooBig;
            const mask = (try r.in.takeArray(4)).*;
            const part = r.buffer[r.fragment_len..][0..@intCast(len)];
            try r.in.readSliceAll(part);
            unmask(part, mask);
            r.fragment_len += part.len;
            if (!h0.fin) continue;

            const data = r.buffer[0..r.fragment_len];
            const opcode = r.fragment.?;
            r.fragment = null;
            if (opcode == .binary) return .{ .binary = data };
            if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
            return .{ .text = data };
        }
    }

    fn unmask(bytes: []u8, mask: [4]u8) void {
        for (bytes, 0..) |*b, i| b.* ^= mask[i % 4];
    }

    fn closeEvent(payload: []const u8) Error!Event {
        if (payload.len == 0) return .{ .close = .{ .code = 1005, .reason = "" } };
        // A close payload is a 2-byte code, then a UTF-8 reason.
        if (payload.len == 1) return error.ProtocolError;
        const reason = payload[2..];
        if (!std.unicode.utf8ValidateSlice(reason)) return error.InvalidUtf8;
        return .{ .close = .{ .code = std.mem.readInt(u16, payload[0..2], .big), .reason = reason } };
    }
};

/// The close code to send when `next` fails. RFC 6455, section 7.4.1.
pub fn closeCodeFor(err: FrameReader.Error) u16 {
    return switch (err) {
        error.UnmaskedFrame, error.ReservedBits, error.ProtocolError => 1002,
        error.InvalidUtf8 => 1007,
        error.MessageTooBig => 1009,
        error.ReadFailed, error.EndOfStream => 1006,
    };
}

// The demonstration. `frame` builds a client frame by hand.

fn frame(w: *std.Io.Writer, opcode: Opcode, fin: bool, payload: []const u8) !void {
    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    try w.writeByte(@bitCast(WebSocket.Header0{ .opcode = opcode, .fin = fin }));
    if (payload.len <= 125) {
        try w.writeByte(@bitCast(WebSocket.Header1{ .payload_len = @fromBackingInt(@intCast(payload.len)), .mask = true }));
    } else {
        try w.writeByte(@bitCast(WebSocket.Header1{ .payload_len = .len16, .mask = true }));
        try w.writeInt(u16, @intCast(payload.len), .big);
    }
    try w.writeAll(&mask);
    for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
}

fn printEvent(out: *std.Io.Writer, event: FrameReader.Event) !void {
    switch (event) {
        .text => |t| try out.print("text \"{s}\"\n", .{t}),
        .binary => |b| try out.print("binary, {d} bytes\n", .{b.len}),
        .ping => |p| try out.print("ping \"{s}\"\n", .{p}),
        .pong => |p| try out.print("pong \"{s}\"\n", .{p}),
        .close => |c| try out.print("close {d} \"{s}\"\n", .{ c.code, c.reason }),
    }
}

/// Give one stream to a new reader with a 64-byte limit. Print each event,
/// or the error and the close code that the server sends for it.
fn readAll(out: *std.Io.Writer, name: []const u8, bytes: []const u8) !void {
    var in: std.Io.Reader = .fixed(bytes);
    var message: [64]u8 = undefined;
    var r: FrameReader = .{ .in = &in, .buffer = &message };
    try out.print("{s}:\n", .{name});
    while (true) {
        const event = r.next() catch |err| {
            if (err == error.EndOfStream) break;
            try out.print("  error.{t} -> send close {d}\n", .{ err, closeCodeFor(err) });
            break;
        };
        try out.print("  ", .{});
        try printEvent(out, event);
        if (event == .close) {
            try out.print("  unread bytes after the close frame: {d}\n", .{in.bufferedLen()});
            break;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var wire: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&wire);

    try frame(&w, .text, false, "Hel");
    try frame(&w, .ping, true, "beat");
    try frame(&w, .continuation, false, "lo, ");
    try frame(&w, .continuation, true, "room");
    try frame(&w, .binary, true, &.{ 1, 2, 3 });
    try frame(&w, .connection_close, true, "\x03\xe9going home");
    try readAll(out, "a message in three fragments, a ping between", w.buffered());

    try out.print("\nframes that the server must refuse, limit 64 bytes:\n", .{});
    const cases = [_]struct { name: []const u8, opcode: Opcode, fin: bool, payload: []const u8, raw: ?[]const u8 = null }{
        .{ .name = "unmasked text", .opcode = .text, .fin = true, .payload = "", .raw = "\x81\x02hi" },
        .{ .name = "a reserved bit set", .opcode = .text, .fin = true, .payload = "", .raw = "\xc1\x80\x00\x00\x00\x00" },
        .{ .name = "opcode 3", .opcode = @fromBackingInt(@intCast(3)), .fin = true, .payload = "?" },
        .{ .name = "ping in fragments", .opcode = .ping, .fin = false, .payload = "beat" },
        .{ .name = "continuation first", .opcode = .continuation, .fin = true, .payload = "lo" },
        .{ .name = "200 bytes", .opcode = .binary, .fin = true, .payload = &@as([200]u8, @splat(0)) },
        .{ .name = "text that is not UTF-8", .opcode = .text, .fin = true, .payload = "\xc3\x28" },
        .{ .name = "close with 1 byte", .opcode = .connection_close, .fin = true, .payload = "\x03" },
    };
    for (cases) |case| {
        var case_w: std.Io.Writer = .fixed(&wire);
        if (case.raw) |raw| try case_w.writeAll(raw) else try frame(&case_w, case.opcode, case.fin, case.payload);
        var in: std.Io.Reader = .fixed(case_w.buffered());
        var message: [64]u8 = undefined;
        var r: FrameReader = .{ .in = &in, .buffer = &message };
        try out.print("  {s:<24} -> ", .{case.name});
        if (r.next()) |event| {
            try printEvent(out, event);
        } else |err| {
            try out.print("error.{t}, close {d}\n", .{ err, closeCodeFor(err) });
        }
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.chat-frames`)*

## The reader

```zig
/// Reads frames from a client. It does the work that `readSmallMessage`
/// leaves to you. It joins fragments and answers nothing by itself. It reads
/// each frame to its end, thus it never stops in the middle of a frame.
pub const FrameReader = struct {
    in: *std.Io.Reader,
    /// The message so far. Its length is the largest message accepted.
    buffer: []u8,
    fragment: ?Opcode = null,
    fragment_len: usize = 0,

    pub const Event = union(enum) {
        text: []const u8,
        binary: []const u8,
        ping: []const u8,
        pong: []const u8,
        /// 1005 if the frame had no code.
        close: struct { code: u16, reason: []const u8 },
    };

    pub const Error = error{
        UnmaskedFrame,
        ReservedBits,
        ProtocolError,
        MessageTooBig,
        InvalidUtf8,
    } || std.Io.Reader.Error;

    pub fn next(r: *FrameReader) Error!Event {
        while (true) {
            const header = try r.in.takeArray(2);
            const h0: WebSocket.Header0 = @bitCast(header[0]);
            const h1: WebSocket.Header1 = @bitCast(header[1]);
            // No extension is in use, thus each reserved bit must be 0.
            if (h0.rsv1 != 0 or h0.rsv2 != 0 or h0.rsv3 != 0) return error.ReservedBits;
            if (!h1.mask) return error.UnmaskedFrame;
            const len: u64 = switch (h1.payload_len) {
                .len16 => try r.in.takeInt(u16, .big),
                .len64 => try r.in.takeInt(u64, .big),
                else => @backingInt(h1.payload_len),
            };
            const control = switch (h0.opcode) {
                .ping, .pong, .connection_close => true,
                .text, .binary, .continuation => false,
                _ => return error.ProtocolError,
            };

            // Control frames are short and complete, and they can arrive
            // between two fragments. They use their own small buffer, so
            // the message in `buffer` stays as it is.
            if (control) {
                if (len > 125 or !h0.fin) return error.ProtocolError;
                const mask = (try r.in.takeArray(4)).*;
                const payload = try r.in.take(@intCast(len));
                unmask(payload, mask);
                switch (h0.opcode) {
                    .ping => return .{ .ping = payload },
                    .pong => return .{ .pong = payload },
                    else => return closeEvent(payload),
                }
            }

            switch (h0.opcode) {
                .continuation => if (r.fragment == null) return error.ProtocolError,
                else => {
                    if (r.fragment != null) return error.ProtocolError;
                    r.fragment = h0.opcode;
                    r.fragment_len = 0;
                },
            }
            // Refuse a frame that is too big before you read its payload.
            // The length is 8 bytes from the client, and it can be anything.
            if (len > r.buffer.len - r.fragment_len) return error.MessageTooBig;
            const mask = (try r.in.takeArray(4)).*;
            const part = r.buffer[r.fragment_len..][0..@intCast(len)];
            try r.in.readSliceAll(part);
            unmask(part, mask);
            r.fragment_len += part.len;
            if (!h0.fin) continue;

            const data = r.buffer[0..r.fragment_len];
            const opcode = r.fragment.?;
            r.fragment = null;
            if (opcode == .binary) return .{ .binary = data };
            if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
            return .{ .text = data };
        }
    }

    fn unmask(bytes: []u8, mask: [4]u8) void {
        for (bytes, 0..) |*b, i| b.* ^= mask[i % 4];
    }

    fn closeEvent(payload: []const u8) Error!Event {
        if (payload.len == 0) return .{ .close = .{ .code = 1005, .reason = "" } };
        // A close payload is a 2-byte code, then a UTF-8 reason.
        if (payload.len == 1) return error.ProtocolError;
        const reason = payload[2..];
        if (!std.unicode.utf8ValidateSlice(reason)) return error.InvalidUtf8;
        return .{ .close = .{ .code = std.mem.readInt(u16, payload[0..2], .big), .reason = reason } };
    }
};
```

*Quoted from the source: `FrameReader` from `snippets/11-networking/chat-frames.zig`.*

The structure is the same as the client: control frames first, then data
frames, with the state of a message in fragments in two fields.

**The size check comes before the payload.** The length field of a frame
can say 2<sup>63</sup> bytes. The reader compares the length with the space
left in `buffer` and refuses the frame before it reads one byte of payload.
The reader allocates nothing, thus a large length cannot make the server
use memory.

**Control frames use the buffer of the reader, not `buffer`.** A ping can
arrive between two fragments. If the ping used `buffer`, it would
overwrite the part of the message that is already there. `take` returns the
ping payload as a slice of the buffer in the `std.Io.Reader`, and `buffer`
stays as it is.

```
a message in three fragments, a ping between:
  ping "beat"
  text "Hello, room"
  binary, 3 bytes
  close 1001 "going home"
  unread bytes after the close frame: 0
```

The last line is the reason for this chapter. After the close frame,
nothing is unread. The server can send its close frame and then close the
TCP connection first, with a normal FIN and no reset.

## A close code for each failure

RFC 6455 gives a close code for each type of failure. One function maps
the errors of the reader to the codes:

```zig
/// The close code to send when `next` fails. RFC 6455, section 7.4.1.
pub fn closeCodeFor(err: FrameReader.Error) u16 {
    return switch (err) {
        error.UnmaskedFrame, error.ReservedBits, error.ProtocolError => 1002,
        error.InvalidUtf8 => 1007,
        error.MessageTooBig => 1009,
        error.ReadFailed, error.EndOfStream => 1006,
    };
}
```

*Quoted from the source: `closeCodeFor` from `snippets/11-networking/chat-frames.zig`.*

```
frames that the server must refuse, limit 64 bytes:
  unmasked text            -> error.UnmaskedFrame, close 1002
  a reserved bit set       -> error.ReservedBits, close 1002
  opcode 3                 -> error.ProtocolError, close 1002
  ping in fragments        -> error.ProtocolError, close 1002
  continuation first       -> error.ProtocolError, close 1002
  200 bytes                -> error.MessageTooBig, close 1009
  text that is not UTF-8   -> error.InvalidUtf8, close 1007
  close with 1 byte        -> error.ProtocolError, close 1002
```

The switch in `closeCodeFor` has no `else`. If a new error joins `FrameReader.Error`, the compiler requires a case for
it. Thus no failure can reach a client with a code that nobody selected.

Code 1006 is special. It means "the connection closed with no close frame",
and RFC 6455 forbids a close frame with that code. `closeCodeFor` returns
it for `ReadFailed` and `EndOfStream` so that the server can log one code
for each end of a connection. The writer in the last chapter checks for
1006 and sends no close frame.

After a protocol error, the stream is not trustworthy. The reader can stop
in the middle of a frame, for example after the header of a frame that is
too big. Thus after an error, the server sends its close frame and closes
the connection. It does not try to read more frames.
