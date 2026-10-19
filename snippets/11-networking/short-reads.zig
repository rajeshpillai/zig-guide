//! title: Bytes Have No Edges
//! A read that returns 7 bytes does not tell you where a message ends.

const std = @import("std");

/// All the bytes that arrived, and the quantity that the parser gave out.
///
/// Two indices do all the work. `len` increases when the network delivers
/// bytes. `at` increases when the parser removes a complete message from the
/// front. No bytes move, thus the slices that `next` returns stay valid.
const Incoming = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    at: usize = 0,

    /// The bytes from the last read. A socket gives you a slice of any size.
    /// The slice can be a part of a message, or two messages, or both.
    fn feed(self: *Incoming, chunk: []const u8) void {
        @memcpy(self.buf[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
    }

    /// `null` means "not yet, read more". If a parser cannot say that, the
    /// parser must think that the full message arrived in one part. That
    /// assumption is the bug.
    fn next(self: *Incoming) ?[]const u8 {
        const avail = self.buf[self.at..self.len];
        if (avail.len < 2) return null;

        const want = std.mem.readInt(u16, avail[0..2], .big);
        if (avail.len < 2 + want) return null;

        self.at += 2 + want;
        return avail[2..][0..want];
    }
};

/// Frame a payload as the sender does: first the length, then the bytes.
fn frame(out: []u8, payload: []const u8) []u8 {
    std.mem.writeInt(u16, out[0..2], @intCast(payload.len), .big);
    @memcpy(out[2..][0..payload.len], payload);
    return out[0 .. 2 + payload.len];
}

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Three messages, one after the other on the wire, as the sender sends
    // them. Only the length of a message shows where the message ends.
    var wire: [64]u8 = undefined;
    var used: usize = 0;
    for ([_][]const u8{ "hello", "hi", "goodbye" }) |payload| {
        used += frame(wire[used..], payload).len;
    }
    try out.print("{d} bytes on the wire for 3 messages\n\n", .{used});

    // One byte for each read. This is the worst case that a real network
    // can make, and a real network can do it. If a parser works
    // here, the parser works for all sizes of parts.
    var incoming: Incoming = .{};
    for (wire[0..used], 1..) |byte, fed| {
        incoming.feed(&.{byte});
        while (incoming.next()) |message| {
            try out.print("after {d} bytes: \"{s}\"\n", .{ fed, message });
        }
    }

    // The same bytes in one read make the same messages. The parser does
    // not know which of the two cases occurred. The parser has this design
    // because the size of the parts is not a part of the protocol.
    var at_once: Incoming = .{};
    at_once.feed(wire[0..used]);
    var count: usize = 0;
    while (at_once.next()) |_| count += 1;
    try out.print("\none read of {d} bytes: {d} messages\n", .{ used, count });

    try out.flush();
}
