# Retransmission and the Window

> A timeout recovers the messages that the network lost, and a window keeps traffic in motion during the recovery.

Retransmission sends a message again when its ack does not arrive before a
timeout. A sliding window keeps many messages in flight, thus one loss does
not stop the stream. Together with sequence numbers and cumulative acks, these
two methods are the core mechanism of TCP.

## The problem

The sender now knows which messages got no confirmation. The sender must
still recover these messages. Something must decide *when* to stop the wait
for an ack and send the message again. The data cannot make that decision.
Silence does not tell how long it will continue, thus the sender can only use
the clock. The sender waits a fixed time, then it sends again.

That fixes the delivery, but it causes a speed problem. If a sender sends one
message and waits for its ack, the sender spends most of its time in the wait.
The fix is a window: many messages in flight at the same time, each with its
own timer.

In this snippet, time is a counter that has the name tick. It is not a real
clock. The tick counter makes each run the same. The round trip of the ack
also costs no time. Thus the only delay in the trace comes from the timeout
policy.

## The plan

1. The scripted network drops transmissions by position: the 2nd and 4th data
   transmission, and the 4th ack. A retry is a new transmission, thus the
   network can also drop a retry.
2. The receiver is the receiver from the
   [previous chapter](https://www.ziglang.in/learn/networking/sequence-numbers/), with one change.
   It records what arrived and answers with a cumulative ack. It also keeps
   the arrivals that are out of order.
3. The sender records `base` (all messages below it have a confirmation) and
   `next`. It also records when it last sent each message in flight. After
   three ticks without an ack, the sender sends the message again.
4. Run the same 8 messages two times: first with a window of 1, then with a
   window of 4.

```zig
const std = @import("std");

const message_count = 8;
const timeout_ticks = 3;

/// The network, with a script by position. It drops the 2nd and 4th data
/// transmission and the 4th ack. The count starts at 1. It counts positions
/// because the network does not know which message a transmission carries.
/// A retry is a new transmission, thus the network can also drop a retry.
const Wire = struct {
    data_sent: usize = 0,
    acks_sent: usize = 0,

    fn deliverData(self: *Wire) bool {
        self.data_sent += 1;
        return self.data_sent != 2 and self.data_sent != 4;
    }

    fn deliverAck(self: *Wire) bool {
        self.acks_sent += 1;
        return self.acks_sent != 4;
    }
};

/// The receiver records what it has, and it answers each arrival with a
/// cumulative ack, as in the previous chapter. But this receiver also keeps
/// the arrivals that are out of order. Thus it does not need them again.
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

/// The state of the sender. All messages below `base` have a confirmation.
/// All messages from `base` to `next` are in flight. Each message in flight
/// records when the sender last sent it. Thus the clock can find a message
/// that is late.
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
        // First, the work of the clock: send again each message that is in
        // flight for too long.
        var seq = sender.base;
        while (seq < sender.next) : (seq += 1) {
            // An ack inside this loop can move `base` past a message that the
            // loop did not reach yet. That message has a confirmation now.
            if (seq < sender.base) continue;
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

/// One transmission and, if it arrives, the ack that comes directly back.
/// The full round trip is inside one tick. Only a loss makes it longer.
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

## The timeout is a guess

Message 1 is lost at tick 1, and the sender sends it again at tick 4, because
the rule is three ticks of silence. Nothing confirmed the loss. The sender
guessed that the ack was so late that it would never arrive.

The two traces also show that the guess can be wrong. In the first trace,
message 3 arrives correctly, but its *ack* is lost. Thus the sender sends
again a message that the receiver already has. The sender can never see the
difference between a lost message and a lost ack.

The second trace shows a different cause. Message 2 arrives at tick 1, but
message 1 does not arrive. A cumulative ack cannot confirm message 2 before
message 1 arrives. Then the ack for the resend of message 1 is lost. Thus
at tick 4, message 2 still has no confirmation, and the sender sends it
again.

A wrong guess is safe because of the duplicate check in the receiver, from the
last chapter. The receiver ignores the second copy and repeats the ack. Thus
retransmission does not need certainty. It needs a receiver that accepts
duplicates without harm.

If the timeout has a bad value, you pay one of two costs:

- If the timeout is too long, each loss stops the stream.
- If the timeout is too short, the network fills with copies of messages that
  arrived correctly.

Here, three ticks is a constant, because the delay of the network never
changes. On a real network, the delay changes all the time. Thus TCP measures
the round trip and calculates the timeout from it. The timeout is still a
guess.

## What the window gives

The messages, the network and the losses are the same in the two runs. A
window of 1 takes 10 ticks, and a window of 4 takes 4 ticks. The difference
is in the ticks around a loss. With one message in flight, the loss of
message 1 stops all traffic. The stream waits during ticks 2 and 3, and it
delivers nothing.

With four messages in flight, messages 2 and 4 arrive while message 1
waits for its timeout. Message 3 is also lost, and its timer expires at the
same tick as the timer of message 1. Thus one round of resends at tick 4
recovers the two losses.

The two runs use the same number of transmissions, 11. In this run, the
window does not save transmissions. The window saves time, because the two
losses overlap and one timeout recovers both of them.

At tick 4, the resend of message 3 gets the ack "have 0 through 4". The timer
of message 4 also expired at tick 4. But that ack confirms message 4, thus
the loop does not send message 4 again. For this reason, the loop compares
each message with `base` again before it sends the message. The loop starts
at the old `base`, and an ack inside the loop can move `base` forward.

TCP adjusts the window all the time. TCP makes the window larger while
messages arrive. TCP makes the window smaller when a loss shows that the
network is possibly full. The name of that policy is congestion control, and
the policy is sufficiently large to fill a book. The mechanism below it is
the dozen lines in this snippet.

## What you built

Sequence numbers, cumulative acks, duplicate detection, timeout
retransmission and a sliding window are the core mechanism of TCP. You built
them in three short chapters, on a protocol that promises nothing.

Each guarantee of TCP comes from records and waits: the timeout stops, the
resends and the management of the window. When a connection feels slow on a
bad link, this mechanism is the cause.

For some traffic, the loss of a message is better than a wait of three ticks.
A position update in a game has no value when a newer update exists. UDP
exists for this type of traffic, where the recovery of a message costs more
than its loss.

QUIC, the transport below HTTP/3, runs on UDP, thus QUIC can do this work
itself. It does not use the TCP of the kernel. The recovery decisions move
into the application, where you can tune them for each stream. At this
level, the protocol that carries most of the web today runs the loop that you
just read.

## Variations

- **Give the ack a travel time:** let an ack need one tick to travel. Then a
  window of 1 sends only one message for each round trip. This occurs also on
  a perfect network. The other function of the window is to keep the link
  full, and on long links that function is most important.
- **Make the timeout 1 tick:** the recovery becomes faster, and the number of
  transmissions increases. This is the cost of a timeout that is too short.
- **Drop more acks:** the stream still completes. With cumulative acks, each
  later ack repairs the loss of an earlier ack.
