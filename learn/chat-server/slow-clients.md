# Slow Clients

> A member that does not read fills its outbox. The hub puts with a minimum of 0, drops the member when nothing fits, and the room does not wait.

A client can stop. It reads nothing more. Its network can be slow, its laptop can sleep,
or its process can stop in a debugger. The server still has lines for that
client, and the lines wait in its outbox. The outbox has a fixed capacity,
thus it fills.

When the outbox is full, the hub has three choices:

1. **Wait** until the writer takes a line out.
2. **Discard the line**, and keep the member.
3. **Drop the member.**

The first choice is the dangerous one. The hub holds its lock during a
broadcast. If the broadcast waits for one member, each other member that
talks waits for the lock. One laptop in sleep mode then stops the room.

The second choice keeps the room alive, but a member who misses lines has a
wrong view of the conversation, and nothing tells that member. This hub
uses the third choice.

## Put, and never wait

```zig
    /// Put one line into one outbox, and never wait. With `min` 0, `put`
    /// adds what fits now and returns. A return of 0 means that the outbox
    /// is full: the member reads slower than the room talks.
    fn deliver(hub: *Hub, io: std.Io, id: usize, line: Line) void {
        const m = &(hub.members[id] orelse return);
        const added = m.peer.outbox.put(io, &.{.{ .line = line }}, 0) catch 0;
        if (added == 0) m.peer.close_code = 1008;
    }
```

*Quoted from the source: `deliver` from `snippets/11-networking/chat-hub.zig`.*

The last argument of `put` is `min`, the number of elements that `put` must
add before it returns. With `min` set to 1, `put` waits for space. With
`min` set to 0, `put` adds what fits now and returns at once. A return of 0
means that the outbox is full.

`deliver` does not remove the member. It only marks the peer with close
code 1008. `deliver` runs inside the loop of `broadcast`, and that loop
reads `members`. A change to `members` inside the loop would skip a member
or visit one twice.

```zig
    /// Remove each member that `deliver` marked, and tell the others. The
    /// notice can fill another outbox, thus repeat until no member has the
    /// mark. Each pass removes a member, thus the loop ends.
    fn dropSlow(hub: *Hub, io: std.Io) void {
        while (true) {
            const id = for (hub.members, 0..) |slot, i| {
                if (slot) |m| if (m.peer.close_code == 1008) break i;
            } else return;
            const m = hub.members[id].?;
            hub.members[id] = null;
            m.peer.outbox.close(io);
            hub.broadcast(io, protocol.format(.{ .left = .{ .nick = m.nick(), .reason = .too_slow } }), null);
        }
    }
```

*Quoted from the source: `dropSlow` from `snippets/11-networking/chat-hub.zig`.*

`dropSlow` runs after the broadcast. It removes each member that `deliver` marked, closes
its outbox, and tells the others. The notice is a broadcast too, and it can
fill another outbox. Thus `dropSlow` repeats until no member has the mark.
Each pass removes one member, so the loop ends.

## A member that reads nothing

The program uses outboxes of 4 lines. tejas and vishaka read each line at
once. shivam reads nothing.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.chat-slow-client`)*

*Figure: Three outboxes of 4 lines. Two empty after each message. The outbox of shivam fills, and on the next message the hub drops shivam. The messages from the program above. The figure stops when the outbox of shivam is full and asks what the hub should do.*

The welcome of shivam and three messages fill its outbox. The fourth
message does not fit:

```
vishaka says "still there?"
  tejas    <- msg vishaka: still there?
  tejas    <- left shivam (too_slow)
  vishaka  <- msg vishaka: still there?
  vishaka  <- left shivam (too_slow)
  shivam is a member: false
```

tejas and vishaka get the message without delay, and then the notice. The
writer of shivam still has the four lines from before the drop. It sends
them, then gets `error.Closed`, and then it sends close code 1008:

```
the writer of shivam reads its outbox:
  welcome shivam (3 online)
  msg tejas: hi
  msg vishaka: hello
  msg tejas: shivam?
  error.Closed: send close 1008
```

Code 1008 is "policy violation" in RFC 6455. No code means "too slow"
exactly. 1008 is the general code for "the server ended the connection
because of a rule", and the rule here is the size of the outbox.

## The free slot

After the drop, the slot of shivam is free. urvashi joins and gets it. The
task of shivam on the old connection can still run, so the program makes it
talk:

```
urvashi joins, in the free slot
  the old connection of shivam says "i am back": error.NoNickYet
```

The hub finds members by their `*Peer`, as the
[last chapter](https://www.ziglang.in/learn/chat-server/hub/) explains. The old peer is not in
the room, thus the hub refuses. With slot numbers, the hub would send the line to the room as a message
from urvashi.

## How large is the outbox?

The capacity is the number of lines that a member can be behind before the
hub drops the member. Four lines makes the problem visible in a short trace. The
server in the last chapter uses 16. The program prints the size of one item:

```
outbox capacity: 4 lines of 162 bytes
```

Thus 16 items cost about 2.6 KB for each member: the 160-byte line, its
length and the opcode.

The outbox is not the only buffer. The kernel has a send buffer for each
TCP socket, and the writer task fills it before it waits. On Linux, the
kernel grows that buffer up to the maximum in `net.ipv4.tcp_wmem`, which
is 4 MB by default. A slow member first fills the
kernel buffer, then the outbox. The outbox decides what happens after the
kernel buffer is full.

A real server also needs a time limit on each write. A writer that waits
for a client that never reads would wait for ever, and the drop only closes
the outbox. The writer must still finish its write before it sees
`error.Closed`.
