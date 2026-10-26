//! title: Read the Frames Yourself
//! A frame reader for a server: fragments, the close code, UTF-8 and a size
//! limit, with the close code for each failure.

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
