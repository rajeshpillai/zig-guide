//! title: When Datagrams Go Missing
//! A channel that loses, repeats and delays messages, so you can watch it.

const std = @import("std");

/// A channel that misbehaves the way a real network does. Each datagram
/// is one byte. A seeded generator decides each datagram's fate, so every
/// run of this program sees exactly the same network.
const FlakyChannel = struct {
    prng: std.Random.DefaultPrng,
    /// A datagram the channel is holding back, to deliver after a later one.
    delayed: ?u8 = null,

    fn init(seed: u64) FlakyChannel {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    /// Push one datagram in. Returns what comes out the far end right now:
    /// nothing, the datagram, the datagram twice, or an older one late.
    fn transmit(self: *FlakyChannel, datagram: u8, out: *[3]u8) []const u8 {
        var n: usize = 0;
        const fate = self.prng.random().uintLessThan(u8, 10);
        switch (fate) {
            // Dropped. The channel tells no one; that is the whole problem.
            0, 1 => {},
            // Duplicated: a retry somewhere below repeated it.
            2 => {
                out[n] = datagram;
                out[n + 1] = datagram;
                n += 2;
            },
            // Delayed: held back, it will arrive after a newer datagram.
            3 => self.delayed = datagram,
            else => {
                out[n] = datagram;
                n += 1;
            },
        }
        // Anything held back arrives now, after the newer datagram: reordering.
        if (fate != 3) {
            if (self.delayed) |old| {
                out[n] = old;
                n += 1;
                self.delayed = null;
            }
        }
        return out[0..n];
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var channel = FlakyChannel.init(4);

    // The receiver keeps a count per datagram and remembers the highest
    // number seen, which is enough to name every failure afterwards.
    var seen: [10]u8 = @splat(0);
    var highest: u8 = 0;
    var late: [10]bool = @splat(false);

    for (0..10) |i| {
        const seq: u8 = @intCast(i);
        try out.print("send {d}\n", .{seq});
        var slots: [3]u8 = undefined;
        for (channel.transmit(seq, &slots)) |got| {
            try out.print("  got {d}\n", .{got});
            if (got < highest) late[got] = true;
            if (got > highest) highest = got;
            seen[got] += 1;
        }
    }

    // What the receiver can say after the fact. During the run it had no
    // way to tell "lost" from "not sent yet": silence looks the same.
    try out.writeAll("\n");
    for (seen, 0..) |count, seq| {
        if (count == 0) try out.print("never arrived: {d}\n", .{seq});
        if (count > 1) try out.print("arrived twice: {d}\n", .{seq});
        if (late[seq]) try out.print("arrived late:  {d}\n", .{seq});
    }

    try out.flush();
}
