//! title: Sequence Numbers and Acks
//! Put a number on each message, and silence becomes information.

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
