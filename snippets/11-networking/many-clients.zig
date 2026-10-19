//! title: Serving Many Clients
//! One handler for each connection, through `Io`. The source runs with and without threads.

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
