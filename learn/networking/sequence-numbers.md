# Sequence Numbers and Acks

> One counter makes an invisible loss into a detected gap, and one reply gives the problem to the sender.

A sequence number on each message lets a receiver find loss and duplicates.
A cumulative ack ("I have everything through N") tells the sender what to send
again. The acks in TCP use the same design.

## The problem

At the end of the previous chapter, the receiver could not see the difference
between loss and silence. The fix costs one byte: put a number on each
message. If a receiver expects 2 and gets 3, the receiver now knows that a
message is lost. The network did not report the loss. If a receiver gets 4
two times, the receiver knows that the second 4 is a retry, not a new message.

Detection is only half of the work. The receiver knows about the gap, but the
sender has the lost message. Thus the receiver sends a report back. This
report is an acknowledgement in the other direction. It tells the sender how
much of the stream the receiver has. The reply gives the loss to the sender,
and only the sender can fix the loss.

## The plan

1. Use the same channel that operates incorrectly, but with a script. The
   channel drops datagram 2 and duplicates datagram 4. Thus you can check
   each line of the output by hand.
2. Make a `Watcher` with one field: the next number that it expects. A number
   below that value is a duplicate. An equal number is in order. A number
   above that value is a gap, and the gap has exact edges.
3. Make a receiver that sends acks. It answers each arrival with "I have
   everything through N". Make a sender that reads these answers.

```zig
const std = @import("std");

/// The network that operates incorrectly, with a script and not random. It
/// drops datagram 2 and duplicates datagram 4. It uses a script because
/// this chapter is about the logic of the receiver. You can check each line
/// of the output against these two rules.
fn transmit(seq: u8, out: *[2]u8) []const u8 {
    if (seq == 2) return out[0..0];
    out[0] = seq;
    if (seq == 4) {
        out[1] = seq;
        return out[0..2];
    }
    return out[0..1];
}

/// To find problems, the receiver needs only one number: the sequence number
/// that it expects next. Below it: seen before. Equal: in order. Above it:
/// the numbers between the two never arrived.
const Watcher = struct {
    next: u8 = 0,

    const Verdict = union(enum) { in_order, duplicate, gap_after: u8 };

    fn accept(self: *Watcher, seq: u8) Verdict {
        if (seq < self.next) return .duplicate;
        const expected = self.next;
        self.next = seq + 1;
        if (seq == expected) return .in_order;
        return .{ .gap_after = expected };
    }
};

/// For acks, the receiver records what it *has*, without gaps from the
/// start. It moves forward only on the exact next number. It answers each
/// arrival with that count. The answer is cumulative: "I have everything
/// through N" also confirms all that the earlier acks confirmed.
const AckSender = struct {
    have: ?u8 = null,

    fn accept(self: *AckSender, seq: u8) ?u8 {
        const want = if (self.have) |h| h + 1 else 0;
        if (seq == want) self.have = seq;
        return self.have;
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // First: the receiver names each failure when it occurs.
    try out.writeAll("-- numbering finds the failures --\n");
    var watcher = Watcher{};
    for (0..6) |i| {
        const seq: u8 = @intCast(i);
        try out.print("send {d}\n", .{seq});
        var slots: [2]u8 = undefined;
        for (transmit(seq, &slots)) |got| {
            switch (watcher.accept(got)) {
                .in_order => try out.print("  got {d}, in order\n", .{got}),
                .duplicate => try out.print("  got {d} again, dropped\n", .{got}),
                .gap_after => |from| if (from == got - 1) {
                    try out.print("  got {d}: gap, {d} never arrived\n", .{ got, from });
                } else {
                    try out.print(
                        "  got {d}: gap, {d} through {d} never arrived\n",
                        .{ got, from, got - 1 },
                    );
                },
            }
        }
    }

    // Second: the receiver sends a report, and the sender learns.
    try out.writeAll("\n-- acks tell the sender --\n");
    var acker = AckSender{};
    var acked_through: ?u8 = null;
    for (0..6) |i| {
        const seq: u8 = @intCast(i);
        var slots: [2]u8 = undefined;
        const arrivals = transmit(seq, &slots);
        if (arrivals.len == 0) {
            try out.print("send {d}: no ack came back\n", .{seq});
            continue;
        }
        for (arrivals) |got| {
            const ack = acker.accept(got);
            acked_through = ack;
            if (ack) |a| {
                try out.print("send {d}: ack \"have 0 through {d}\"\n", .{ seq, a });
            } else {
                try out.print("send {d}: ack \"have nothing\"\n", .{seq});
            }
        }
    }

    // The sender knows only the acks. The sender never saw the drop. It
    // sees only which of its messages got no confirmation.
    if (acked_through) |a| {
        try out.print("\nsender: confirmed through {d}, so {d} through 5 need resending\n", .{ a, a + 1 });
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.sequence-numbers`)*

## One counter, three verdicts

The `Watcher` is one `u8` and a comparison. Detection with sequence numbers
needs only these two things. Each result in the first half of the trace comes
from one rule: numbers arrive in order unless the network causes a problem.
The comparison that finds gaps also finds the duplicate of 4.

The last chapter said that retries cause duplicates. This receiver already
handles duplicates, one chapter before retries occur.

The scripted channel does not change the order of datagrams, by design. With
reordering, "3 arrived and 2 did not" can mean that 2 is lost or only late.
The receiver cannot know which yet. Sequence numbers find that a problem
exists. To decide that the problem is loss, you need a timeout. The timeout
is the first step of the next chapter.

## Acks are cumulative by design

The receiver that sends acks never says "I got 3". It says "I have everything through
1", also while 3, 4 and 5 arrive. These words have two effects:

- Acks repair themselves. If one ack is lost, the next arrival repeats all of
  the information in the lost ack.
- The sender must record only one number.

Look at the last line of the trace. The sender got "through 1" and decided
that it must send 2 through 5 again. The sender never saw the drop. It found the
loss from the replies only. TCP uses this design for acks. The version in
this snippet is different mainly in the byte layout.

The trace also shows the cost: 3, 4 and 5 arrived, but a simple sender like
this one sends them again. A real receiver keeps the out-of-order arrivals in
a buffer, thus the resends are cheap. A real sender also has better recovery.
The shape of the exchange does not change.

## Acks use the same network

In this snippet, the acks always arrive. This is the one simplification, and
it keeps the trace easy to read. On a real network, the ack for 2 can
disappear, as 2 can disappear. The sender cannot see a difference between
these two cases. The sender uses the same tool for the two cases. The
duplicate check in the receiver makes this safe: if the sender sends a
received message again, it wastes time but causes no harm.

The next chapter puts these parts in a loop, and the clock decides when to
use them.

## Variations

- **Change the script:** drop 0, not 2. Then the first ack becomes "have
  nothing". The sender gets the same quantity of information from that ack.
- **Wrap-around:** a `u8` sequence number gets to 255 and wraps. Real
  protocols select a counter size so that an old number cannot occur again while
  its datagram can still be on the network. TCP uses 32 bits.
- **Selective acks:** "I have 0 through 1, and also 3 through 5" names the
  exact hole, but the reply is more complex. TCP added this as the SACK
  option, fifteen years after the first release of cumulative acks.
