# Sequence Numbers and Acks

> One counter turns invisible loss into a detected gap, and one reply turns it into the sender's problem.

## The problem

The previous chapter ended with a receiver that could not tell loss from
silence. The fix costs one byte: number every message. A receiver that
expects 2 and gets 3 now knows something the network never told it. A
receiver that gets 4 twice knows the second one is a retry, not news.

Detection is only half the job. The receiver knows about the gap, but
the sender is the one holding the missing message. So the receiver
reports back: an acknowledgement, going the other way, saying how much
of the stream it has. That single reply makes loss the sender's problem,
which is the only place it can be fixed.

## The plan

1. The same misbehaving channel, but scripted: it drops datagram 2 and
   duplicates datagram 4, so every line of output can be checked by hand.
2. A `Watcher` with one field, the next number it expects. Below it:
   duplicate. Equal: in order. Above it: a gap, and the gap has exact
   edges.
3. An acking receiver that answers every arrival with "I have everything
   through N", and a sender that reads those answers.

```zig
const std = @import("std");

/// The misbehaving network again, but scripted instead of random: it
/// drops datagram 2 and duplicates datagram 4. Scripted, because this
/// chapter is about the receiver's logic, and you should be able to
/// check every line of its output against these two rules.
fn transmit(seq: u8, out: *[2]u8) []const u8 {
    if (seq == 2) return out[0..0];
    out[0] = seq;
    if (seq == 4) {
        out[1] = seq;
        return out[0..2];
    }
    return out[0..1];
}

/// One number is the receiver's whole defence: the sequence number it
/// expects next. Below it: seen before. Equal: in order. Above it: the
/// numbers in between never arrived.
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

/// For acks the receiver tracks what it *has*, contiguously from the
/// start. It only advances on the exact next number, and answers every
/// arrival with that count. The answer is cumulative: "I have everything
/// through N" repeats all earlier acks for free.
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

    // First: the receiver names every failure as it happens.
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

    // Second: the receiver reports back, and the sender learns.
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

    // The sender's view is built from acks alone. It never saw the drop;
    // it only sees which of its messages were never confirmed.
    if (acked_through) |a| {
        try out.print("\nsender: confirmed through {d}, so {d} through 5 need resending\n", .{ a, a + 1 });
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.sequence-numbers`)*

## One counter, three verdicts

The `Watcher` is a single `u8` and a comparison, and that is genuinely
all sequence-number detection is. Everything it reports in the first
half of the trace follows from one rule: numbers arrive in order unless
the network interfered. The duplicate of 4 is caught by the same
comparison that catches gaps, which matters more than it looks. The last
chapter said retries create duplicates; this receiver is already immune
to them, one page before retries exist.

The scripted channel does not reorder, and that is deliberate. With
reordering, "3 arrived and 2 did not" might mean 2 is lost or merely
late, and the receiver cannot know which yet. Sequence numbers detect
that something is wrong; deciding it is loss takes a timeout, which is
the next chapter's first move.

## Acks are cumulative on purpose

The acking receiver never says "I got 3". It says "I have everything
through 1", even while 3, 4 and 5 are arriving. Two things fall out of
that phrasing. First, acks repair themselves: if one ack is lost, the
next arrival repeats everything it said. Second, the sender's
bookkeeping collapses to one number. Look at the final line of the
trace: the sender heard "through 1" and concluded that 2 through 5 need
resending. It never saw the drop. It reconstructed the damage entirely
from replies. That is TCP's ack design, and this snippet's version
differs mainly in byte layout.

The cost is also visible in the trace: 3, 4 and 5 did arrive, and a
sender this simple will send them again. A real receiver keeps the
out-of-order arrivals buffered so the resends can be cheap, and a real
sender has smarter recovery. The shape of the exchange does not change.

## Acks ride the same network

In this snippet the acks always arrive; that is the one concession to
keeping the trace readable. On a real network the ack for 2 can vanish
just like 2 itself, and the sender cannot distinguish the two cases at
all. It handles both with the same tool, and the receiver's duplicate
check is what makes that safe: resending something already received is
wasteful but harmless. The next chapter puts these pieces in a loop and
lets the clock decide when to use them.

## Variations

- **Move the script:** drop 0 instead of 2 and the first ack becomes
  "have nothing". The sender learns exactly as much from that.
- **Wrap-around:** a `u8` sequence number reaches 255 and wraps. Real
  protocols size the counter so old numbers cannot come back around
  while their datagrams could still be in flight; TCP uses 32 bits.
- **Selective acks:** "I have 0 through 1, and also 3 through 5" names
  the hole exactly at the price of a more complex reply. TCP grew this
  as the SACK option decades after cumulative acks shipped.
