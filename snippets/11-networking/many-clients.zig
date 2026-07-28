//! title: Serving Many Clients
//! One handler per connection, through `Io`, so the same source runs either way.

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
