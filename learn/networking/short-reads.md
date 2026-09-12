# Bytes Have No Edges

> A read returning 7 bytes tells you nothing about where a message ends.

This is the chapter that decides whether your server works under load.

TCP is a byte stream. It preserves order and it preserves every byte, and it
promises nothing whatsoever about grouping. The three writes the sender made
can arrive as one read, or as seventeen. Nothing in the socket API tells you
which happened, because as far as TCP is concerned there was never anything
there to group.

Press Run. The same bytes are delivered one at a time and then all at once,
and the parser cannot tell the difference.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.short-reads`)*

## The bug this is about

```zig
// Wrong, and it works on your machine every time.
var buf: [256]u8 = undefined;
const n = try socket.read(&buf);
const message = parse(buf[0..n]);
```

That code is correct only when the whole message arrived in one read. On
loopback, with a small message and an idle machine, it always does. It stops
being true when the message crosses an MTU, when the network is busy, when the
sender uses two writes, or when a proxy sits in between. The failure arrives
in production and looks like corruption rather than truncation.

## Two indices, no copying

```zig
const Incoming = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,   // bytes received
    at: usize = 0,    // bytes handed out
};
```

`len` grows as the network delivers. `at` grows as complete messages are taken
off the front. Because nothing is shifted down, the slices `next` returns stay
valid, which means a message can be handed to a handler without copying it
first.

The alternative, compacting the buffer after every message, invalidates every
slice you already returned. That is a use-after-free that a `[256]u8` will
happily hide from you, because the memory is still there and still readable.

## `null` is the whole idea

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

Two `null` returns, for the two ways a message can be incomplete: not enough
bytes to know the length, and not enough bytes to satisfy it. A parser that
cannot say "not yet" has no choice but to assume, and assuming is the bug.

Note also the `while` in the caller. One read can complete more than one
message, so a handler that processes a single message per read will fall
steadily further behind a fast client and never catch up.

## What this gives you

The parser never learns how the bytes were chunked, so chunking stops being
part of your protocol. You can test it against a byte array, which is what
[Three Ways to Frame](https://www.ziglang.in/learn/networking/framing/) does next. The test is worth
something, because the delivery pattern it does not simulate is one the parser
cannot observe anyway.
