# When Datagrams Go Missing

> Loss, duplication and reordering, produced on demand so you can watch them.

A network carrying UDP datagrams does three things to them: it loses
some, delivers some twice, and delivers some out of order.

## The problem

UDP does not promise to deliver anything. The
[previous chapter](https://www.ziglang.in/learn/networking/udp-message/) sent datagrams over
loopback, where they always arrive, so none of these failures appeared.

It is hard to learn to handle failures you never see. So this chapter
creates them. The snippet is a channel that misbehaves on purpose. A seeded
random generator drives it, so every run has the same failures. The next two chapters send their traffic through the same kind of
channel while they fix each problem in turn.

## The plan

1. A `FlakyChannel` with one method: put a datagram in, see what comes
   out. Sometimes that is nothing, sometimes the datagram twice,
   sometimes an older datagram arriving late.
2. Send ten numbered datagrams through it.
3. Let the receiver tally what arrived and name each failure.

```zig
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
            // Dropped. The channel does not report the drop to anyone.
            0, 1 => {},
            // Duplicated: a retry in a lower layer sent it again.
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
    // way to tell "lost" from "not sent yet": in both cases nothing arrives.
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

## Silence looks the same as nothing

Datagram 0 was dropped, and the trace for it is empty. The receiver does
not see a gap where 0 should be. It sees nothing, and that is also what it
sees before any traffic starts and between datagrams. So loss is invisible
at the moment it happens. This receiver could name the missing datagram
afterwards only because the snippet numbered the datagrams and told it ten
were coming. A real receiver knows neither of these things until the
protocol tells it. The next chapter adds that to the protocol.

## Where duplicates come from

The channel duplicated datagram 1, even though the sender sent it once.
Real networks do this, but the far more common cause is the fix for loss. A sender that resends after silence cannot tell "my datagram
was lost" from "the reply was lost", and in the second case the receiver
gets the message twice. Any protocol that retries must expect its own
retries back. Chapter after next, the receiver handles this with the same
sequence numbers it uses to spot gaps.

## Reordering is just delay

Datagram 4 arrived after datagram 5. Nothing swapped them. Datagram 4 was
held back and 5 arrived before it. On real networks two datagrams can take
different routes, and the second one sent can arrive first. Reordering makes
loss detection harder: a gap in the numbers might be a lost datagram, or a
slow one that is still coming. TCP faces exactly this ambiguity, and its answer (wait a little,
then give up and resend) is the timeout logic this section builds in the
retransmission chapter.

## Variations

- **Turn the dials:** the fate roll gives each datagram a 2 in 10 chance
  of being dropped. Raise it and the summary grows; a channel that drops
  half of everything is what wifi looks like at the edge of range.
- **Change the seed:** a different seed is a different network. The
  failures happen to different datagrams, but the kinds of failure stay
  the same.
- **No corruption here:** real networks also flip bits, but UDP carries a
  checksum, so corrupted datagrams are discarded before your program
  sees them. Corruption reaches you as loss.
