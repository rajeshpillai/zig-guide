# Bytes Have No Edges

> A read that returns 7 bytes does not tell you where a message ends.

If a server ignores the subject of this chapter, the server can work in tests
and fail under load.

TCP is a byte stream. TCP keeps the bytes in order and delivers all of the
bytes. TCP does not make a promise about how it groups the bytes. The sender
made three writes, and these writes can arrive as one read or as seventeen
reads. The socket API does not tell you which of these occurred. TCP does not
record where one write ended and where the next write started.

Press Run. The program delivers the same bytes one byte at a time, and then
all together. The parser cannot see a difference.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.short-reads`)*

## The bug

```zig
// Wrong, and it works on your machine every time.
var buf: [256]u8 = undefined;
const n = try socket.read(&buf);
const message = parse(buf[0..n]);
```

This code is correct only when the full message arrives in one read. On
loopback, with a small message and a computer that has no other load, the
full message always arrives in one read. In these conditions, the full
message possibly does not arrive in one read:

- The message is larger than one packet (the MTU).
- The network has a high load.
- The sender uses two writes.
- The connection uses a proxy.

The failure occurs in production. It looks like data corruption, not like a
message that is too short.

## Two indices and no copies

```zig
const Incoming = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,   // bytes received
    at: usize = 0,    // bytes handed out
};
```

`len` increases when the network delivers bytes. `at` increases when the
parser removes a complete message from the front. The parser does not move
bytes, thus the slices that `next` returns stay valid. You can give a message
to a handler and not copy the message first.

The other method is to compact the buffer after each message: you move the
other bytes to the front. Then each slice that the parser returned before
points at the wrong bytes. This is a use-after-free. A `[256]u8` hides the
error from you, because the memory is still there and you can still read it.

## `null` means "not yet"

```zig
fn next(self: *Incoming) ?[]const u8 {
    const avail = self.buf[self.at..self.len];
    if (avail.len < 2) return null;

    const want = std.mem.readInt(u16, avail[0..2], .big);
    if (avail.len < 2 + want) return null;

    self.at += 2 + want;
    return avail[2..][0..want];
}
```

The function has two `null` returns, for the two ways that a message can be
incomplete:

- There are not sufficient bytes to know the length.
- There are not sufficient bytes for that length.

If a parser cannot say "not yet", the parser must think that the message is
complete. That assumption is the bug from the start of this chapter.

Also look at the `while` in the caller. One read can complete more than one
message. If a handler processes only one message for each read, a fast
client makes the number of messages in the buffer increase. Then the handler
never gets to the end of the buffer.

## The result

The parser does not know how the bytes arrived in parts. Thus the size of the
parts is not a part of your protocol. You can test the parser with a byte
array, and [Three Ways to Frame](https://www.ziglang.in/learn/networking/framing/) does that next.
That test has value. The parser cannot see the delivery patterns that the
test does not simulate.
