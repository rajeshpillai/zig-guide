# Retransmission and the Window

> A timeout recovers what the network lost, and a window keeps traffic moving while it does.

## The problem

The sender now knows which messages were never confirmed. Knowing is not
recovering: something has to decide *when* to give up on an ack and send
the message again. Nothing in the data can decide that. Silence carries
no information about how long it will last, so the only judge left is
the clock. Wait a fixed time, then resend.

That fixes delivery and creates a speed problem. A sender that transmits
one message and waits for its ack spends most of its life waiting. The
fix is a window: several messages in flight at once, each on its own
clock.

Time in this snippet is a counter called a tick, not a real clock. That
is what makes the program a fair experiment: the same run every time,
and the ack's round trip costs nothing, so the only delay you see is
the one the timeout policy itself adds.

## The plan

1. The scripted network drops by position: the 2nd and 7th data
   transmission, and the 4th ack. A retry is a new transmission and
   rolls the dice again.
2. The receiver is the
   [previous chapter's](https://www.ziglang.in/learn/networking/sequence-numbers/), unchanged:
   mark what arrived, answer with a cumulative ack, keep out-of-order
   arrivals.
3. The sender tracks `base` (confirmed below this) and `next`, and
   remembers when each in-flight message was last sent. Three ticks
   with no ack means resend.
4. Run the same 8 messages twice: window of 1, then window of 4.

```zig
const std = @import("std");

const message_count = 8;
const timeout_ticks = 3;

/// The network, scripted by position: it drops the 2nd and 7th data
/// transmission and the 4th ack, counting from 1. Positional, because
/// the network does not know or care which message a transmission
/// carries; a retry rolls the dice again.
const Wire = struct {
    data_sent: usize = 0,
    acks_sent: usize = 0,

    fn deliverData(self: *Wire) bool {
        self.data_sent += 1;
        return self.data_sent != 2 and self.data_sent != 7;
    }

    fn deliverAck(self: *Wire) bool {
        self.acks_sent += 1;
        return self.acks_sent != 4;
    }
};

/// The receiver marks off what it has and answers every arrival with a
/// cumulative ack, exactly as in the previous chapter. Out-of-order
/// arrivals are kept, so a resend never has to repeat them.
const Receiver = struct {
    got: [message_count]bool = @splat(false),

    fn accept(self: *Receiver, seq: u8) ?u8 {
        self.got[seq] = true;
        var have: ?u8 = null;
        for (self.got, 0..) |g, i| {
            if (!g) break;
            have = @intCast(i);
        }
        return have;
    }
};

/// The sender's state: everything below `base` is confirmed, everything
/// from `base` to `next` is in flight, and each in-flight message
/// remembers when it was last transmitted so the clock can judge it.
const Sender = struct {
    base: u8 = 0,
    next: u8 = 0,
    sent_at: [message_count]usize = @splat(0),

    fn onAck(self: *Sender, have: ?u8) void {
        if (have) |h| {
            if (h + 1 > self.base) self.base = h + 1;
        }
    }
};

fn run(out: *std.Io.Writer, window: u8) !void {
    try out.print("-- window = {d} --\n", .{window});
    var wire = Wire{};
    var receiver = Receiver{};
    var sender = Sender{};

    var tick: usize = 1;
    while (sender.base < message_count and tick <= 40) : (tick += 1) {
        // First, the clock's job: anything in flight too long goes again.
        var seq = sender.base;
        while (seq < sender.next) : (seq += 1) {
            if (tick - sender.sent_at[seq] < timeout_ticks) continue;
            try out.print("tick {d:2}: {d} timed out, resend", .{ tick, seq });
            try transmit(out, &wire, &receiver, &sender, seq, tick);
        }
        // Then fill the window with new messages.
        while (sender.next < message_count and sender.next - sender.base < window) {
            const s = sender.next;
            sender.next += 1;
            try out.print("tick {d:2}: send {d}", .{ tick, s });
            try transmit(out, &wire, &receiver, &sender, s, tick);
        }
    }
    try out.print(
        "delivered {d} messages in {d} ticks, {d} transmissions\n\n",
        .{ sender.base, tick - 1, wire.data_sent },
    );
}

/// One transmission and, if it arrives, the ack coming straight back.
/// The whole round trip fits inside a tick; only loss stretches time.
fn transmit(
    out: *std.Io.Writer,
    wire: *Wire,
    receiver: *Receiver,
    sender: *Sender,
    seq: u8,
    tick: usize,
) !void {
    sender.sent_at[seq] = tick;
    if (!wire.deliverData()) {
        try out.writeAll(" .. lost\n");
        return;
    }
    const had_it = receiver.got[seq];
    const have = receiver.accept(seq);
    if (!wire.deliverAck()) {
        try out.writeAll(" .. delivered, ack lost\n");
        return;
    }
    sender.onAck(have);
    if (had_it) {
        try out.writeAll(" .. receiver had it already, ack repeated\n");
    } else if (have) |h| {
        try out.print(" .. ack: have 0 through {d}\n", .{h});
    } else {
        try out.writeAll(" .. ack: have nothing\n");
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try run(out, 1);
    try run(out, 4);

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.retransmission`)*

## The timeout is a bet

Message 1 is lost at tick 1 and resent at tick 4, because three ticks of
silence was the deal. Nothing confirmed the loss; the sender bet that an
ack this late was never coming. Both traces also show the bet's other
face: message 3 arrives intact, its *ack* is lost, and the sender resends
a message the receiver already has. The sender cannot tell those two
stories apart, ever. What makes the bet safe to lose is the receiver's
duplicate check from the last chapter: the resend is shrugged off and
the ack repeated. Retransmission does not need certainty, only a
receiver that forgives.

Pick the timeout badly and the cost shows up on one side or the other:
too long and every loss stalls the stream; too short and the network
fills with copies of messages that were fine. Three ticks here is a
constant because the network's delay never changes. TCP's delay changes
constantly, so it measures the round trip and derives the timeout from
that, but it is still the same bet.

## What the window buys

Same messages, same network, same losses: 10 ticks with a window of 1,
4 ticks with a window of 4. The difference is what happens *around* a
loss. With one message in flight, the loss of message 1 stops
everything; the stream spends ticks 2 and 3 waiting, delivering
nothing. With four in flight, messages 2 through 4 keep moving while 1
waits out its timeout, and the recovery at tick 4 finds most of the work
already done.

The price is on the trace too: 12 transmissions instead of 11, because
the sender charged ahead and one of the extra transmissions was lost.
A window trades bandwidth for waiting. TCP spends its whole life
tuning that trade: grow the window while things arrive, shrink it when
loss suggests the network is full. That policy is congestion control,
and it is a book of its own; the mechanism underneath it is the dozen
lines in this snippet.

## What you just built

Sequence numbers, cumulative acks, duplicate detection, timeout
retransmission, a sliding window: that is the working core of TCP,
built in three short chapters on top of a protocol that promises
nothing. The point of building it is what it explains.

It explains what TCP costs. Every guarantee came from bookkeeping and
waiting: the timeout stalls, the resends, the window management. When a
connection feels slow on a bad link, this machinery is what slow looks
like from the inside.

It explains why UDP exists. Some traffic would rather lose a message
than wait three ticks for it: a position update in a game is worthless
once a newer one exists. UDP is not TCP with the safety removed; it is
the escape hatch for traffic where recovery costs more than loss.

And it explains a modern choice. QUIC, the transport under HTTP/3, runs
on UDP precisely so it can own this machinery itself instead of
inheriting the kernel's TCP, moving recovery decisions into the
application where they can be tuned per stream. The protocol carrying
most of the web today is, at this level, the loop you just read.

## Variations

- **Make the ack pay for distance:** give acks a tick of travel time and
  a window of 1 drops to one message per round trip even on a perfect
  network. That is the window's other job, filling the pipe, and it is
  the one that dominates on long links.
- **Shrink the timeout to 1 tick:** recovery gets faster and the
  transmission count climbs, the too-short side of the bet.
- **Drop more acks:** the stream still completes. Cumulative acks mean
  any later ack repairs the loss of an earlier one.
