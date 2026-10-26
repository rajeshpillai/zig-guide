//! title: Slow Clients
//! A member that does not read fills its outbox. The hub drops that member,
//! and the room does not wait.

const std = @import("std");
const protocol = @import("chat-protocol.zig");
const chat = @import("chat-hub.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // Small outboxes, to make the problem visible in a few steps. A real
    // server selects the capacity from the memory that it can give to a
    // member that is behind.
    const capacity = 4;
    var storage: [3][capacity]chat.Outgoing = undefined;
    var peers: [3]chat.Peer = undefined;
    for (&peers, &storage) |*peer, *s| peer.* = .{ .outbox = .init(s) };
    const names = [_][]const u8{ "tejas", "vishaka", "shivam" };
    try out.print("outbox capacity: {d} lines of {d} bytes\n", .{ capacity, @sizeOf(chat.Outgoing) });

    var hub: chat.Hub = .{};
    for (&peers, names) |*peer, name| try hub.join(io, peer, name);

    // tejas and vishaka read each line at once. shivam reads nothing: the
    // network of shivam is slow, or a debugger stopped its process.
    var lines: [capacity]chat.Outgoing = undefined;
    _ = chat.drain(io, &peers[0].outbox, &lines);
    _ = chat.drain(io, &peers[1].outbox, &lines);
    try out.print("after the joins, shivam has 1 line waiting: its welcome\n\n", .{});

    const said = [_]struct { who: usize, text: []const u8 }{
        .{ .who = 0, .text = "hi" },
        .{ .who = 1, .text = "hello" },
        .{ .who = 0, .text = "shivam?" },
        .{ .who = 1, .text = "still there?" },
    };
    for (said) |s| {
        try hub.say(io, &peers[s.who], s.text);
        try out.print("{s} says \"{s}\"\n", .{ names[s.who], s.text });
        for (peers[0..2], names[0..2]) |*peer, name| {
            for (chat.drain(io, &peer.outbox, &lines)) |*item| {
                try out.print("  {s:<8} <- {s}\n", .{ name, item.line.bytes() });
            }
        }
        try out.print("  shivam is a member: {}\n", .{hub.isMember(&peers[2])});
    }

    // The slot of shivam is free again, and urvashi gets it. If the hub
    // used slot numbers as names, the reader task of shivam (still on the
    // old connection) could now speak as urvashi.
    var urvashi_storage: [capacity]chat.Outgoing = undefined;
    var urvashi: chat.Peer = .{ .outbox = .init(&urvashi_storage) };
    try hub.join(io, &urvashi, "urvashi");
    try out.print("\nurvashi joins, in the free slot\n", .{});
    if (hub.say(io, &peers[2], "i am back")) |_| {
        try out.print("  the old connection of shivam says \"i am back\": sent\n", .{});
    } else |err| {
        try out.print("  the old connection of shivam says \"i am back\": error.{t}\n", .{err});
    }

    // The writer task of shivam still gets the lines that are in the
    // outbox, then error.Closed. Then it sends the close code.
    try out.print("\nthe writer of shivam reads its outbox:\n", .{});
    while (true) {
        var one: [1]chat.Outgoing = undefined;
        if (peers[2].outbox.get(io, &one, 1)) |_| {
            try out.print("  {s}\n", .{one[0].line.bytes()});
        } else |err| {
            try out.print("  error.{t}: send close {d}\n", .{ err, peers[2].close_code });
            break;
        }
    }

    try out.flush();
}
