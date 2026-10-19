//! title: When Datagrams Go Missing
//! A channel that loses, repeats and delays messages, so that you can see it.

const std = @import("std");

/// A channel that operates incorrectly, as a real network does. Each
/// datagram is one byte. A seeded generator decides the fate of each
/// datagram. Thus each run of this program sees exactly the same network.
const FlakyChannel = struct {
    prng: std.Random.DefaultPrng,
    /// A datagram that the channel keeps, to deliver after a later datagram.
    delayed: ?u8 = null,

    fn init(seed: u64) FlakyChannel {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    /// Put one datagram in. Returns the output at the far end now: nothing,
    /// the datagram, the datagram two times, or an older datagram late.
    fn transmit(self: *FlakyChannel, datagram: u8, out: *[3]u8) []const u8 {
        var n: usize = 0;
        const fate = self.prng.random().uintLessThan(u8, 10);
        switch (fate) {
            // Dropped. The channel does not report the drop.
            0, 1 => {},
            // Duplicated: a retry in a lower layer sent the datagram again.
            2 => {
                out[n] = datagram;
                out[n + 1] = datagram;
                n += 2;
            },
            // Delayed: the channel keeps the datagram. It will arrive after a
            // newer datagram.
            3 => self.delayed = datagram,
            else => {
                out[n] = datagram;
                n += 1;
            },
        }
        // A datagram that the channel kept arrives now, after the newer
        // datagram. This is reordering.
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

    // The receiver keeps a count for each datagram, and it records the
    // highest number. This data is sufficient to name each failure later.
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

    // What the receiver can say after the run. During the run, the receiver
    // cannot know "lost" from "not sent yet". In the two cases, nothing
    // arrives.
    try out.writeAll("\n");
    for (seen, 0..) |count, seq| {
        if (count == 0) try out.print("never arrived: {d}\n", .{seq});
        if (count > 1) try out.print("arrived twice: {d}\n", .{seq});
        if (late[seq]) try out.print("arrived late:  {d}\n", .{seq});
    }

    try out.flush();
}
