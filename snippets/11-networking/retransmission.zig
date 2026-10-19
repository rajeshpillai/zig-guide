//! title: Retransmission and the Window
//! A timeout changes a detected loss into a recovered loss. A window makes it fast.

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
