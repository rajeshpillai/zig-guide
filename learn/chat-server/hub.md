# The Hub

> One writer for each socket. The hub keeps the members, copies each line into a bounded outbox, and never touches a socket.

Each connection in the server has its own task, which reads from its
socket. When tejas says something, the task of tejas must send a line to
vishaka and to shivam. The simple design is to write to their sockets
directly. That design has a race.

A WebSocket frame is a header and a payload, and a large frame can need
more than one write. Two tasks can write to the socket of shivam at the same
time, for example the tasks of tejas and vishaka. Then the bytes of the two
frames can mix.
Then shivam gets a frame that is not valid, and closes the connection.

A lock for each socket would prevent the mix. But a task that holds that
lock waits for the network of shivam, and a slow network then stops each
member who talks.

## One writer for each socket

The hub uses a different design:

1. Each connection has an **outbox**, a bounded queue of lines.
2. Each connection has one **writer task**. Only the writer task writes to
   the socket. It takes a line from the outbox and sends it.
3. The hub puts lines into outboxes. It never touches a socket.

Thus no two tasks write to one socket. A task that talks only puts lines into
queues, and a queue operation is short.

```zig
/// One connection, as the hub sees it. The hub never writes to a socket.
/// It puts lines into the outbox, and one writer task for the connection
/// takes them out and sends them. Thus only one task writes to a socket.
pub const Peer = struct {
    outbox: Outbox,
    /// The code of the close frame that the writer sends after somebody
    /// closes the outbox. The hub sets it before `close`, and the writer
    /// reads it after `error.Closed`. The lock in the queue orders the two.
    close_code: u16 = 1000,
};
```

*Quoted from the source: `Peer` from `snippets/11-networking/chat-hub.zig`.*

The outbox is `std.Io.Queue`, the bounded channel from
[Queues](https://www.ziglang.in/learn/concurrency/queues/). Its capacity comes from the buffer
that you give to `init`. A `Peer` belongs to the connection, and the hub
keeps a pointer to it.

The program below plays three members in memory. After each action, it
takes the lines out of each outbox, as a writer task would, and prints
them.

```zig
const std = @import("std");
const protocol = @import("chat-protocol.zig");
const Line = protocol.Line;
const Event = protocol.Event;

/// One frame for the writer task. Chat lines are text frames. The pong
/// for a ping goes through the outbox too, because only the writer task
/// may write to the socket.
pub const Outgoing = struct {
    opcode: std.http.Server.WebSocket.Opcode = .text,
    line: Line,
};

pub const Outbox = std.Io.Queue(Outgoing);

/// One connection, as the hub sees it. The hub never writes to a socket.
/// It puts lines into the outbox, and one writer task for the connection
/// takes them out and sends them. Thus only one task writes to a socket.
pub const Peer = struct {
    outbox: Outbox,
    /// The code of the close frame that the writer sends after somebody
    /// closes the outbox. The hub sets it before `close`, and the writer
    /// reads it after `error.Closed`. The lock in the queue orders the two.
    close_code: u16 = 1000,
};

pub const max_members = 8;

const Member = struct {
    peer: *Peer,
    nick_buf: [protocol.max_nick]u8,
    nick_len: u8,

    fn nick(m: *const Member) []const u8 {
        return m.nick_buf[0..m.nick_len];
    }
};

pub const Hub = struct {
    mutex: std.Io.Mutex = .init,
    members: [max_members]?Member = @splat(null),

    /// Find a member by its peer, never by its slot. The hub can drop a
    /// member and give the slot to a new member. A slot number that the old
    /// connection kept would then point at the new member.
    fn find(hub: *Hub, peer: *const Peer) ?usize {
        for (hub.members, 0..) |slot, i| {
            if (slot) |m| if (m.peer == peer) return i;
        }
        return null;
    }

    /// Add a member, send the welcome to that member, and tell the others.
    pub fn join(hub: *Hub, io: std.Io, peer: *Peer, nick: []const u8) (protocol.Refusal || std.Io.Cancelable)!void {
        try hub.mutex.lock(io);
        defer hub.mutex.unlock(io);

        if (hub.find(peer) != null) return error.AlreadyJoined;
        var free: ?usize = null;
        var online: u8 = 1;
        for (&hub.members, 0..) |*slot, i| {
            if (slot.*) |*m| {
                if (std.mem.eql(u8, m.nick(), nick)) return error.NickTaken;
                online += 1;
            } else if (free == null) {
                free = i;
            }
        }
        const id = free orelse return error.RoomFull;
        var m: Member = .{ .peer = peer, .nick_buf = undefined, .nick_len = @intCast(nick.len) };
        @memcpy(m.nick_buf[0..nick.len], nick);
        hub.members[id] = m;

        hub.deliver(io, id, protocol.format(.{ .welcome = .{ .nick = nick, .online = online } }));
        hub.broadcast(io, protocol.format(.{ .joined = nick }), id);
        hub.dropSlow(io);
    }

    /// A message from a member goes to each member, the sender too. The
    /// sender sees its own line in the same order as everybody else.
    pub fn say(hub: *Hub, io: std.Io, peer: *const Peer, text: []const u8) (protocol.Refusal || std.Io.Cancelable)!void {
        try hub.mutex.lock(io);
        defer hub.mutex.unlock(io);
        const m = &hub.members[hub.find(peer) orelse return error.NoNickYet].?;
        hub.broadcast(io, protocol.format(.{ .msg = .{ .nick = m.nick(), .text = text } }), null);
        hub.dropSlow(io);
    }

    /// The member closed the connection. Close its outbox, so that the
    /// writer task sends what is left and ends.
    /// If the hub already dropped the member, `leave` only closes the outbox.
    pub fn leave(hub: *Hub, io: std.Io, peer: *Peer) std.Io.Cancelable!void {
        try hub.mutex.lock(io);
        defer hub.mutex.unlock(io);
        const id = hub.find(peer) orelse return peer.outbox.close(io);
        const m = hub.members[id].?;
        hub.members[id] = null;
        m.peer.outbox.close(io);
        hub.broadcast(io, protocol.format(.{ .left = .{ .nick = m.nick(), .reason = .quit } }), null);
        hub.dropSlow(io);
    }

    pub fn isMember(hub: *Hub, peer: *const Peer) bool {
        return hub.find(peer) != null;
    }

    fn broadcast(hub: *Hub, io: std.Io, line: Line, except: ?usize) void {
        for (hub.members, 0..) |slot, i| {
            if (slot == null or (except != null and i == except.?)) continue;
            hub.deliver(io, i, line);
        }
    }

    /// Put one line into one outbox, and never wait. With `min` 0, `put`
    /// adds what fits now and returns. A return of 0 means that the outbox
    /// is full: the member reads slower than the room talks.
    fn deliver(hub: *Hub, io: std.Io, id: usize, line: Line) void {
        const m = &(hub.members[id] orelse return);
        const added = m.peer.outbox.put(io, &.{.{ .line = line }}, 0) catch 0;
        if (added == 0) m.peer.close_code = 1008;
    }

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
};

/// Take each line that is in an outbox now. Do not wait for more.
pub fn drain(io: std.Io, outbox: *Outbox, lines: []Outgoing) []Outgoing {
    const n = outbox.get(io, lines, 0) catch 0;
    return lines[0..n];
}

// The demonstration: three members, and the lines that each outbox holds
// after each action. A writer task would send those lines.

const names = [_][]const u8{ "tejas", "vishaka", "shivam" };

fn report(out: *std.Io.Writer, io: std.Io, action: []const u8, peers: []Peer) !void {
    try out.print("{s}\n", .{action});
    var lines: [8]Outgoing = undefined;
    for (peers, names) |*peer, name| {
        for (drain(io, &peer.outbox, &lines)) |*item| {
            try out.print("  {s:<8} <- {s}\n", .{ name, item.line.bytes() });
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    var storage: [3][8]Outgoing = undefined;
    var peers: [3]Peer = undefined;
    for (&peers, &storage) |*peer, *s| peer.* = .{ .outbox = .init(s) };

    var hub: Hub = .{};
    try hub.join(io, &peers[0], "tejas");
    try report(out, io, "tejas joins", &peers);
    try hub.join(io, &peers[1], "vishaka");
    try report(out, io, "vishaka joins", &peers);
    try hub.join(io, &peers[2], "shivam");
    try report(out, io, "shivam joins", &peers);

    var extra_storage: [8]Outgoing = undefined;
    var extra: Peer = .{ .outbox = .init(&extra_storage) };
    if (hub.join(io, &extra, "tejas")) |_| {} else |err| {
        try out.print("a second tejas joins\n  refused: error.{t}\n", .{err});
    }

    try hub.say(io, &peers[1], "hello, room");
    try report(out, io, "vishaka says \"hello, room\"", &peers);
    try hub.leave(io, &peers[0]);
    try report(out, io, "tejas leaves", &peers);

    // `leave` closed the outbox of tejas. Its writer task reads
    // the rest of the lines, then gets error.Closed and ends.
    var lines: [1]Outgoing = undefined;
    const closed = peers[0].outbox.get(io, &lines, 1);
    try out.print("\nthe outbox of tejas after leave: {s}\n", .{if (closed) |_| "a line" else |err| @errorName(err)});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.chat-hub`)*

*Figure: Three outboxes, for tejas, vishaka and shivam, and the lines that the hub puts into each one for each action. The actions and deliveries from the program above, one step for each action.*

## Join

```zig
    /// Add a member, send the welcome to that member, and tell the others.
    pub fn join(hub: *Hub, io: std.Io, peer: *Peer, nick: []const u8) (protocol.Refusal || std.Io.Cancelable)!void {
        try hub.mutex.lock(io);
        defer hub.mutex.unlock(io);

        if (hub.find(peer) != null) return error.AlreadyJoined;
        var free: ?usize = null;
        var online: u8 = 1;
        for (&hub.members, 0..) |*slot, i| {
            if (slot.*) |*m| {
                if (std.mem.eql(u8, m.nick(), nick)) return error.NickTaken;
                online += 1;
            } else if (free == null) {
                free = i;
            }
        }
        const id = free orelse return error.RoomFull;
        var m: Member = .{ .peer = peer, .nick_buf = undefined, .nick_len = @intCast(nick.len) };
        @memcpy(m.nick_buf[0..nick.len], nick);
        hub.members[id] = m;

        hub.deliver(io, id, protocol.format(.{ .welcome = .{ .nick = nick, .online = online } }));
        hub.broadcast(io, protocol.format(.{ .joined = nick }), id);
        hub.dropSlow(io);
    }
```

*Quoted from the source: `join` from `snippets/11-networking/chat-hub.zig`.*

`join` holds the `std.Io.Mutex` of the hub from the check to the last
delivery. Two clients can ask for the same nickname at the same
time. Only one gets it: the second client waits for the lock, and then the
hub finds the first.

The order inside `join` is important. The new member gets the welcome
first, then the others get `joined`. Each member sees the room in one
order, and the order is the same for each member.

```
shivam joins
  tejas    <- joined shivam
  vishaka  <- joined shivam
  shivam   <- welcome shivam (3 online)
a second tejas joins
  refused: error.NickTaken
```

The refusal returns an error to the caller. The hub does not send it. The
connection that asked puts the `error` event into its own outbox, as the
last chapter shows.

## Say: the sender gets the line too

```zig
    /// A message from a member goes to each member, the sender too. The
    /// sender sees its own line in the same order as everybody else.
    pub fn say(hub: *Hub, io: std.Io, peer: *const Peer, text: []const u8) (protocol.Refusal || std.Io.Cancelable)!void {
        try hub.mutex.lock(io);
        defer hub.mutex.unlock(io);
        const m = &hub.members[hub.find(peer) orelse return error.NoNickYet].?;
        hub.broadcast(io, protocol.format(.{ .msg = .{ .nick = m.nick(), .text = text } }), null);
        hub.dropSlow(io);
    }
```

*Quoted from the source: `say` from `snippets/11-networking/chat-hub.zig`.*

The broadcast has no `except`, thus the sender gets its own line back:

```
vishaka says "hello, room"
  tejas    <- msg vishaka: hello, room
  vishaka  <- msg vishaka: hello, room
  shivam   <- msg vishaka: hello, room
```

The echo has a purpose. The hub holds its lock for the whole broadcast,
thus messages enter all outboxes in one order. When the line returns to vishaka, vishaka knows its position among the other messages. A client
that shows its own message at once, before the echo, can show the messages
in a different order from everybody else.

## A slot number is not a name

`say` and `leave` take the `*Peer` of the connection, not the number of a
slot in `members`:

```zig
    /// Find a member by its peer, never by its slot. The hub can drop a
    /// member and give the slot to a new member. A slot number that the old
    /// connection kept would then point at the new member.
    fn find(hub: *Hub, peer: *const Peer) ?usize {
        for (hub.members, 0..) |slot, i| {
            if (slot) |m| if (m.peer == peer) return i;
        }
        return null;
    }
```

*Quoted from the source: `find` from `snippets/11-networking/chat-hub.zig`.*

The first version of the hub returned the slot number from `join`, and the
connection kept it. That fails in a case that the next chapter adds. The
hub can drop a member, and the next member to join gets the free slot. The
task of the dropped member still runs and still has the old number. Its next
`say` then speaks as the new member.

The `Peer` lives as long as the connection, and no other connection has the
same pointer. Thus the hub searches the members for the pointer. With eight
slots, the search is eight comparisons.

## Leave

```zig
    /// The member closed the connection. Close its outbox, so that the
    /// writer task sends what is left and ends.
    /// If the hub already dropped the member, `leave` only closes the outbox.
    pub fn leave(hub: *Hub, io: std.Io, peer: *Peer) std.Io.Cancelable!void {
        try hub.mutex.lock(io);
        defer hub.mutex.unlock(io);
        const id = hub.find(peer) orelse return peer.outbox.close(io);
        const m = hub.members[id].?;
        hub.members[id] = null;
        m.peer.outbox.close(io);
        hub.broadcast(io, protocol.format(.{ .left = .{ .nick = m.nick(), .reason = .quit } }), null);
        hub.dropSlow(io);
    }
```

*Quoted from the source: `leave` from `snippets/11-networking/chat-hub.zig`.*

`leave` closes the outbox. A closed `std.Io.Queue` still gives the lines
that it holds. After the last line, `get` returns `error.Closed`. Thus the
writer task sends each line that is still in the outbox, then sees
`error.Closed`, sends the close frame and ends. The close of the queue tells
the writer to stop, and no flag or extra message is necessary.

```
the outbox of tejas after leave: Closed
```
