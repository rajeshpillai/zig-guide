//! title: Bytes Have No Edges
//! A read returning 7 bytes tells you nothing about where a message ends.

const std = @import("std");

/// Everything received so far, and how much of it has been handed out.
///
/// The two indices are the whole trick. `len` grows as the network delivers
/// bytes; `at` grows as complete messages are taken off the front. Nothing is
/// copied or shifted, so the slices `next` returns stay valid.
const Incoming = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    at: usize = 0,

    /// Whatever the last read produced. A socket hands you an arbitrary
    /// slice: it may be part of a message, or two messages, or both.
    fn feed(self: *Incoming, chunk: []const u8) void {
        @memcpy(self.buf[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
    }

    /// `null` means "not yet, read more". A parser that cannot say that has
    /// to assume the whole message arrived in one piece, which is the bug.
    fn next(self: *Incoming) ?[]const u8 {
        const avail = self.buf[self.at..self.len];
        if (avail.len < 2) return null;

        const want = std.mem.readInt(u16, avail[0..2], .big);
        if (avail.len < 2 + want) return null;

        self.at += 2 + want;
        return avail[2..][0..want];
    }
};

/// Frame a payload the way the sender would: length first, then the bytes.
fn frame(out: []u8, payload: []const u8) []u8 {
    std.mem.writeInt(u16, out[0..2], @intCast(payload.len), .big);
    @memcpy(out[2..][0..payload.len], payload);
    return out[0 .. 2 + payload.len];
}

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Three messages, back to back on the wire, exactly as the sender
    // would emit them. Nothing marks where one ends except its length.
    var wire: [64]u8 = undefined;
    var used: usize = 0;
    for ([_][]const u8{ "hello", "hi", "goodbye" }) |payload| {
        used += frame(wire[used..], payload).len;
    }
    try out.print("{d} bytes on the wire for 3 messages\n\n", .{used});

    // The worst case a real network can hand you, and a legal one: one
    // byte per read. Anything that works here works for any chunking.
    var incoming: Incoming = .{};
    for (wire[0..used], 1..) |byte, fed| {
        incoming.feed(&.{byte});
        while (incoming.next()) |message| {
            try out.print("after {d} bytes: \"{s}\"\n", .{ fed, message });
        }
    }

    // The same bytes delivered in one read produce the same messages. The
    // parser never learns which happened, which is the point of writing it
    // this way: chunking is not part of the protocol.
    var at_once: Incoming = .{};
    at_once.feed(wire[0..used]);
    var count: usize = 0;
    while (at_once.next()) |_| count += 1;
    try out.print("\none read of {d} bytes: {d} messages\n", .{ used, count });

    try out.flush();
}
