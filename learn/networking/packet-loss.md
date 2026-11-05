# Lost Datagrams

> Loss, duplication and reordering, made on demand so that you can see them.

A network that carries UDP datagrams does three things to them. It loses some
datagrams, it delivers some datagrams two times, and it delivers some
datagrams in the wrong order.

## The problem

UDP does not promise to deliver anything. The
[previous chapter](https://www.ziglang.in/learn/networking/udp-message/) sent datagrams over
loopback. On loopback, datagrams always arrive, thus none of these failures
occurred.

It is difficult to learn how to handle failures that you never see. Thus this
chapter makes the failures. The snippet is a channel that operates
incorrectly by design. A seeded random generator controls the channel, thus
each run has the same failures. The next two chapters send their traffic
through the same type of channel, and they fix each problem in turn.

## The plan

1. Make a `FlakyChannel` with one method: put a datagram in, and see what
   comes out. Sometimes nothing comes out. Sometimes the datagram comes out
   two times. Sometimes an older datagram arrives late.
2. Send ten numbered datagrams through the channel.
3. Let the receiver count what arrived and name each failure.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.packet-loss`)*

## Silence looks the same as no traffic

The channel dropped datagram 0, and the trace for datagram 0 is empty. The
receiver does not see a gap at the position of datagram 0. The receiver sees
nothing. The receiver also sees nothing before the traffic starts and between
datagrams. Thus the receiver cannot see a loss at the time of the loss.

After the run, this receiver can name the lost datagram. There are two
reasons for this:

- The snippet numbered the datagrams.
- The snippet told the receiver that ten datagrams will arrive.

A real receiver does not know these two facts until the
protocol tells it. The next chapter adds these facts to the protocol.

## The cause of duplicates

The channel duplicated datagram 1, but the sender sent it one time only. Real
networks do this, but the fix for loss is a much more frequent cause. If a
sender sends a message again after a silence, the sender cannot know which
of these two conditions is true:

- The datagram of the sender was lost.
- The reply was lost.

In the second condition, the receiver gets the message two times. Thus each
protocol that tries again must expect its own retries to arrive. Two chapters
after this one, the receiver handles this problem. It uses the same sequence
numbers that it uses to find gaps.

## Reordering is only delay

Datagram 4 arrived after datagram 5. Nothing exchanged the two datagrams. The
channel kept datagram 4, and datagram 5 arrived before it. On real networks,
two datagrams can use different routes, and the second datagram can arrive
first.

Reordering makes the detection of loss more difficult. A gap in the numbers
can be a lost datagram, or a slow datagram that is still on the way. TCP has
exactly this problem. The TCP solution is to wait a short time, then stop the
wait and send again. The retransmission chapter of this section adds this
timeout logic.

## Variations

- **Change the probability:** the fate roll gives each datagram a 2 in 10
  probability that the channel drops it. Increase the value, and the summary
  becomes longer. A channel that drops half of all datagrams is similar to
  wifi at the edge of its range.
- **Change the seed:** a different seed is a different network. The failures
  occur to different datagrams, but the types of failure stay the same.
- **No corruption here:** real networks also change bits. But UDP carries a
  checksum, thus the network stack discards corrupted datagrams before your
  program sees them. Corruption arrives at your program as loss.
