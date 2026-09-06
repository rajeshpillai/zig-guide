# Serving Many Clients

> One handler per connection through Io, so the same source runs either way.

A server that handles one connection at a time is a server one slow client can
stop. The traditional answers are two, and both have a cost. A thread per
connection costs a stack each and stops scaling in the thousands. A
single-threaded event loop scales, and infects every function you write with
callbacks.

Zig's answer is neither, and this page runs it in your browser on a target
with no threads at all.

```zig
const std = @import("std");

/// A connection, with the transport left out. The handler below reads bytes
/// and writes bytes and never learns whether they came from a socket, which
/// is what lets this page run in a browser with no sockets at all. Chapter
/// two is the same handler with a `std.Io.net.Server` in front of it.
const Connection = struct {
    request: []const u8,
    reply: [64]u8 = undefined,
    reply_len: usize = 0,

    fn written(self: *const Connection) []const u8 {
        return self.reply[0..self.reply_len];
    }
};

/// Deliberately not `!void`. A task spawned into a Group cannot return an
/// error to anyone, so a per-connection failure has to become part of that
/// connection's reply. One bad client must not take down the server.
fn handle(conn: *Connection, counter: *usize, mutex: *std.Io.Mutex, io: std.Io) void {
    var w: std.Io.Writer = .fixed(&conn.reply);

    var it = std.mem.tokenizeScalar(u8, conn.request, ' ');
    const verb = it.next() orelse "";

    if (std.mem.eql(u8, verb, "ECHO")) {
        w.print("+{s}\r\n", .{it.rest()}) catch {};
    } else if (std.mem.eql(u8, verb, "COUNT")) {
        // Shared state, so it needs the lock. `io.async` may or may not be
        // parallel depending on the implementation, and code that is only
        // correct under the single-threaded one is a race waiting for a
        // deployment.
        mutex.lock(io) catch return;
        defer mutex.unlock(io);
        counter.* += 1;
        w.print(":{d}\r\n", .{counter.*}) catch {};
    } else {
        w.print("-ERR unknown command '{s}'\r\n", .{verb}) catch {};
    }

    conn.reply_len = w.buffered().len;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    var conns = [_]Connection{
        .{ .request = "ECHO first" },
        .{ .request = "COUNT" },
        .{ .request = "ECHO second" },
        .{ .request = "COUNT" },
        .{ .request = "SUBSCRIBE news" },
        .{ .request = "COUNT" },
    };

    var counter: usize = 0;
    var mutex: std.Io.Mutex = .init;

    // A Group owns its tasks: awaiting it waits for every one, and nothing
    // can outlive this scope. That is the property a bare `Thread.spawn`
    // per connection does not give you, and it is why a server built this
    // way can shut down rather than leaking connections it forgot about.
    var group: std.Io.Group = .init;
    for (&conns) |*conn| {
        group.async(io, handle, .{ conn, &counter, &mutex, io });
    }
    try group.await(io);

    // Replies printed in connection order, not completion order. The tasks
    // finished in whatever order the implementation chose; if this printed
    // as they completed, the output would differ between a threaded Io and
    // the single-threaded one this page runs on.
    for (&conns, 1..) |*conn, n| {
        try out.print("conn {d}: {s: <16} -> ", .{ n, conn.request });
        for (conn.written()) |byte| switch (byte) {
            '\r' => try out.writeAll("\\r"),
            '\n' => try out.writeAll("\\n"),
            else => try out.writeByte(byte),
        };
        try out.writeByte('\n');
    }

    try out.print("\nCOUNT reached {d} across {d} connections\n", .{ counter, conns.len });
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.many-clients`)*

## The handler does not know about sockets

```zig
const Connection = struct {
    request: []const u8,
    reply: [64]u8 = undefined,
    reply_len: usize = 0,
};
```

The transport is missing on purpose. `handle` reads bytes and writes bytes and
never learns where they came from, which is why this page runs with no network
underneath it. Put a `std.Io.net.Server` in front of the same function and it
is [the TCP round trip](https://www.ziglang.in/learn/networking/tcp-echo/).

That is the whole argument for writing protocol code against `Reader` and
`Writer` instead of against a socket. The tests get to be fast, and the
browser gets to run the example.

## `io.async`, not `Thread.spawn`

```zig
var group: std.Io.Group = .init;
for (&conns) |*conn| {
    group.async(io, handle, .{ conn, &counter, &mutex, io });
}
try group.await(io);
```

The `Io` implementation decides what "async" means. `std.Io.Threaded` runs
these on a thread pool; the single-threaded WASI one running this page runs
them inline. **The source does not change**, which is why
[Threads](https://www.ziglang.in/learn/standard-library/threads/) is a page you cannot run here and
this one is.

If you are arriving from an older Zig looking for `async` and `await` as
keywords: they were removed. This is what replaced them, and it is a library,
not syntax. [Concurrency](https://www.ziglang.in/learn/standard-library/concurrency/) covers the
shape in general.

## A Group so nothing outlives the scope

`Group` owns its tasks. Awaiting it waits for all of them, and cancelling it
cancels all of them, so a connection handler cannot outlive the server that
started it. A bare `Thread.spawn` per connection gives you no such guarantee,
and shutting down cleanly means tracking every thread you ever started.
[Cancellation](https://www.ziglang.in/learn/standard-library/cancellation/) covers what a handler
sees when the group it belongs to is cancelled.

## A handler cannot return an error

```zig
fn handle(conn: *Connection, counter: *usize, mutex: *std.Io.Mutex, io: std.Io) void {
```

Note the `void`. There is nobody to return an error to: the caller has moved
on to the next connection. So a per-connection failure has to become part of
that connection's reply, which is the same conclusion the [text protocol
chapter](https://www.ziglang.in/learn/networking/text-protocols/) reached from the other direction.
One client sending garbage must not affect any other client.

## Shared state still needs a lock

```zig
mutex.lock(io) catch return;
defer mutex.unlock(io);
counter.* += 1;
```

The single-threaded implementation this page runs on would be perfectly happy
without the mutex. That is exactly the trap. Code that is only correct under
the implementation you tested with is a race waiting for a deployment, and the
`Io` you get in production is the threaded one.

`lock` takes the `io` and returns an error, because it can block and therefore
can be cancelled.

## Why the replies print in order

The tasks completed in whatever order the implementation chose. The loop that
prints them runs afterwards, over the connections in order, so the output is
the same either way. Printing from inside the handlers would interleave
differently on a threaded `Io` than on this one.

The `COUNT` values are the exception, and they are honest: they show the order
the tasks actually reached the mutex. Run this natively and they may well come
out shuffled.
