# Retransmission and the Window

> A timeout recovers what the network lost, and a window keeps traffic moving while it does.

Retransmission resends a message when its ack has not arrived within a
timeout, and a sliding window keeps several messages in flight so one
loss does not stall the stream. With sequence numbers and cumulative
acks, they are the working core of TCP.

## The problem

The sender now knows which messages were never confirmed. It still has to
recover them. Something has to decide *when* to stop waiting for an ack and
send the message again. Nothing in the data can decide that. Silence does
not say how long it will last, so the sender can only use the clock. It
waits a fixed time, then resends.

That fixes delivery but causes a speed problem. A sender that transmits one
message and waits for its ack spends most of its time waiting. The fix is a
window: several messages in flight at once, each with its own timer.

Time in this snippet is a counter called a tick, not a real clock. The tick
counter makes every run the same. The ack's round trip also costs nothing,
so the only delay you see is the one the timeout policy adds.

## The plan

1. The scripted network drops by position: the 2nd and 7th data
   transmission, and the 4th ack. A retry is a new transmission, so it
   can be dropped too.
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
/// transmission and the 4th ack, counting from 1. It counts positions
/// because the network does not know which message a transmission
/// carries. A retry is a new transmission, so it can be dropped too.
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
/// remembers when it was last transmitted, so the clock can tell when it
/// is overdue.
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
/// The whole round trip fits inside one tick. Only a loss makes it longer.
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

Message 1 is lost at tick 1 and resent at tick 4, because the rule is three
ticks of silence. Nothing confirmed the loss. The sender guessed that an
ack this late was never coming.

Both traces also show that the guess can be wrong. In the first, message 3
arrives intact, but its *ack* is lost. So the sender resends a message the
receiver already has. In the second trace, the message whose ack goes
missing is 4. The sender can never tell these two cases apart. A wrong
guess is safe because of the receiver's duplicate check from the last
chapter. The receiver ignores the resent copy and repeats the ack. So
retransmission does not need certainty. It needs a receiver that accepts
duplicates without harm.

If the timeout is badly chosen, you pay one of two costs. Too long, and
every loss stalls the stream. Too short, and the network fills with copies
of messages that were fine. Here, three ticks is a constant because the
network's delay never changes. On a real network the delay changes all the
time, so TCP measures the round trip and computes the timeout from it. The
timeout is still a guess.

## What the window buys

The messages, network and losses are the same in both runs. A window of 1
takes 10 ticks, and a window of 4 takes 4 ticks. The difference is what
happens *around* a loss. With one message in flight, the loss of message 1
stops everything. The stream spends ticks 2 and 3 waiting and delivers
nothing. With four in flight, messages 2 through 4 keep moving while 1
waits out its timeout, and the recovery at tick 4 finds most of the work
already done.

The trace shows the cost too: 12 transmissions instead of 11. The sender
sent ahead, and one of the extra transmissions was lost. A window uses more
bandwidth to spend less time waiting. TCP adjusts this all the time. It
grows the window while messages arrive, and shrinks it when loss suggests
the network is full. That policy is called congestion control, and it is
large enough to fill a book. The mechanism under it is the dozen lines in
this snippet.

## What you just built

Sequence numbers, cumulative acks, duplicate detection, timeout
retransmission and a sliding window make up the working core of TCP. You
built them in three short chapters, on top of a protocol that promises
nothing.

Every guarantee TCP gives comes from bookkeeping and waiting: the timeout
stalls, the resends, the window management. When a connection feels slow on
a bad link, this machinery is the reason.

Some traffic would rather lose a message than wait three ticks for it. A
position update in a game is worthless once a newer one exists. UDP exists
for traffic like this, where recovering a message costs more than losing
it.

QUIC, the transport under HTTP/3, runs on UDP so it can do this work itself.
It does not use the kernel's TCP. Recovery decisions move into the
application, where they can be tuned for each stream. At this level, the
protocol that carries most of the web today runs the loop you just read.

## Variations

- **Make the ack pay for distance:** give acks a tick of travel time and
  a window of 1 drops to one message per round trip even on a perfect
  network. Keeping the link full is the window's other job, and on long
  links it matters most.
- **Shrink the timeout to 1 tick:** recovery gets faster and the
  transmission count climbs. This is the cost of a timeout that is too
  short.
- **Drop more acks:** the stream still completes. Cumulative acks mean
  any later ack repairs the loss of an earlier one.
