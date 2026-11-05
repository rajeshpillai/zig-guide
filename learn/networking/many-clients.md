# Serve Many Clients

> One handler for each connection through Io, thus the same source runs with threads and without threads.

If a server handles one connection at a time, one slow client can stop the
server. There are two usual solutions, and each solution has a cost:

- One thread for each connection. Each thread costs a stack, and the server
  cannot scale past some thousands of threads.
- A single-threaded event loop. The loop can scale, but each function that
  you write must use callbacks.

Zig uses neither of these two solutions. This page runs the Zig solution in
your browser, on a target that has no threads.

```zig
const std = @import("std");

/// A connection without the transport. The handler below reads bytes and
/// writes bytes. It does not know if the bytes came from a socket. Thus this
/// page can run in a browser that has no sockets. Chapter two puts a
/// `std.Io.net.Server` in front of the same handler.
const Connection = struct {
    request: []const u8,
    reply: [64]u8 = undefined,
    reply_len: usize = 0,

    fn written(self: *const Connection) []const u8 {
        return self.reply[0..self.reply_len];
    }
};

/// Not `!void`, by design. A task in a Group cannot return an error to a
/// caller. Thus a failure in a connection must become a part of the reply
/// for that connection. One bad client must not stop the server.
fn handle(conn: *Connection, counter: *usize, mutex: *std.Io.Mutex, io: std.Io) void {
    var w: std.Io.Writer = .fixed(&conn.reply);

    var it = std.mem.tokenizeScalar(u8, conn.request, ' ');
    const verb = it.next() orelse "";

    if (std.mem.eql(u8, verb, "ECHO")) {
        w.print("+{s}\r\n", .{it.rest()}) catch {};
    } else if (std.mem.eql(u8, verb, "COUNT")) {
        // Shared state, thus it needs the lock. The implementation decides
        // if `io.async` is parallel. If code is correct only with the
        // single-threaded implementation, the code has a race when you
        // deploy it on a threaded implementation.
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

    // A Group owns its tasks. The await waits for each task, and no task
    // continues after this scope. A bare `Thread.spawn` for each connection
    // does not give you this. Thus a server with a Group can stop, and it
    // does not leak connections that it forgot.
    var group: std.Io.Group = .init;
    for (&conns) |*conn| {
        group.async(io, handle, .{ conn, &counter, &mutex, io });
    }
    try group.await(io);

    // Print the replies in the order of the connections, not in the order
    // that the tasks completed. The implementation selected that order. A
    // threaded Io and the single-threaded Io of this page can complete the
    // tasks in different orders.
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

The struct has no transport, by design. `handle` reads bytes and writes
bytes. It does not know where the bytes came from. Thus this page runs
without a network below it. If you put a `std.Io.net.Server` in front of the
same function, you get [the TCP round trip](https://www.ziglang.in/learn/networking/tcp-echo/).

Write protocol code for `Reader` and `Writer`, not for a socket. Then the
tests are fast, and the browser can run the example.

## `io.async`, not `Thread.spawn`

```zig
var group: std.Io.Group = .init;
for (&conns) |*conn| {
    group.async(io, handle, .{ conn, &counter, &mutex, io });
}
try group.await(io);
```

The `Io` implementation decides what "async" means. `std.Io.Threaded` runs
the tasks on a thread pool. This page runs on the single-threaded WASI
implementation, which runs the tasks inline. **The source does not change.**
For this reason, you cannot run the [Threads](https://www.ziglang.in/learn/concurrency/threads/)
page here, but you can run this page.

If you used an older version of Zig, you possibly look for the `async` and
`await` keywords. Zig removed these keywords. `io.async` replaced them, as a
library function and not as syntax.
[Concurrency](https://www.ziglang.in/learn/concurrency/async-future-group/) shows the general
shape.

## A Group so nothing outlives the scope

`Group` owns its tasks. When you await the group, it waits for all of its
tasks. When you cancel the group, it cancels all of its tasks. Thus a
connection handler cannot continue after the end of the server that started
it. A bare `Thread.spawn` for each connection does not give you this
guarantee. To stop the server cleanly, you must then record each thread that
you started.

[Cancellation](https://www.ziglang.in/learn/concurrency/cancellation/) shows what a
handler sees when you cancel its group.

## A handler cannot return an error

```zig
fn handle(conn: *Connection, counter: *usize, mutex: *std.Io.Mutex, io: std.Io) void {
```

Look at the `void`. There is no caller that can receive an error, because
the caller continued to the next connection. Thus a failure in a connection
must become a part of the reply for that connection. The [text protocol
chapter](https://www.ziglang.in/learn/networking/text-protocols/) came to the same result from the
other direction. If one client sends bad data, no other client must see an
effect.

## Shared state still needs a lock

```zig
mutex.lock(io) catch return;
defer mutex.unlock(io);
counter.* += 1;
```

This page uses the single-threaded implementation, and that implementation
works without the mutex. Do not trust that result. Some code is correct only
with the implementation that you used for the tests. That code has a data
race, and the race can occur after you deploy the code. The cause is that the
`Io` in production is the threaded implementation.

`lock` takes the `io` and returns an error. The function can block, thus a
cancel can stop it.

## Why the replies print in order

The tasks completed in the order that the implementation selected. The loop
that prints the replies runs after the tasks, and it uses the order of the
connections. Thus the output is the same with each implementation. If the
handlers printed the replies, the lines would have a different order on a
threaded `Io`.

The `COUNT` values are the exception. They show the order in which the tasks
got the mutex. If you run this program natively, the values can have a
different order.
