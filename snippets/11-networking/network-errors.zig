//! title: Failure Is Ordinary
//! native
//! The end of a stream is not an error. Refused and reset are errors, and they are normal.

const std = @import("std");

/// The client half of the clean-shutdown case: send a full message, then
/// close. The server must see the message and then a normal end.
fn sendThenClose(address: std.Io.net.IpAddress, io: std.Io) void {
    var stream = address.connect(io, .{ .mode = .stream }) catch return;
    defer stream.close(io);

    var buf: [64]u8 = undefined;
    var writer = stream.writer(io, &buf);
    writer.interface.writeAll("complete\n") catch return;
    writer.interface.flush() catch return;
}

/// The truncated case: half of a message, then close. The bytes are valid.
/// But there are not sufficient bytes to make a message.
fn sendPartialThenClose(address: std.Io.net.IpAddress, io: std.Io) void {
    var stream = address.connect(io, .{ .mode = .stream }) catch return;
    defer stream.close(io);

    var buf: [64]u8 = undefined;
    var writer = stream.writer(io, &buf);
    writer.interface.writeAll("truncat") catch return;
    writer.interface.flush() catch return;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try any_port.listen(io, .{});
    const address = server.socket.address;

    // 1. The peer completed its message and closed the connection. Each
    //    connection does this at the end. If you make it a failure, you log
    //    an error for each successful conversation.
    {
        const thread = try std.Thread.spawn(.{}, sendThenClose, .{ address, io });
        defer thread.join();

        var conn = try server.accept(io);
        defer conn.close(io);

        var read_buf: [64]u8 = undefined;
        var reader = conn.reader(io, &read_buf);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        try out.print("clean close:  read \"{s}\", then ", .{line});

        // The delimiter is not consumed yet. Skip it and read again.
        reader.interface.toss(1);
        if (reader.interface.takeDelimiterExclusive('\n')) |_| {
            try out.writeAll("more data\n");
        } else |err| {
            try out.print("{s} (expected: the client is done)\n", .{@errorName(err)});
        }
    }

    // 2. The peer closed the connection in the middle of a message. It is
    //    easy to make a mistake here. Read the doc comment on
    //    `takeDelimiterExclusive`. The comment says: "End-of-stream is
    //    treated equivalent to a delimiter." If a client stops in the middle of a line, you get a
    //    fragment. The fragment looks the same as a complete message. There
    //    is no error and no flag to check.
    {
        const thread = try std.Thread.spawn(.{}, sendPartialThenClose, .{ address, io });
        defer thread.join();

        var conn = try server.accept(io);
        defer conn.close(io);

        var read_buf: [64]u8 = undefined;
        var reader = conn.reader(io, &read_buf);
        const fragment = try reader.interface.takeDelimiterExclusive('\n');
        try out.print("truncated:    Exclusive returned \"{s}\" and no error\n", .{fragment});
    }

    // 3. The same half of a message, but this call requires the delimiter.
    //    `takeDelimiterInclusive` returns the byte as a part of the slice.
    //    Thus it cannot invent a delimiter. The end of the stream without
    //    the delimiter is `EndOfStream`, and you discard the bytes.
    {
        const thread = try std.Thread.spawn(.{}, sendPartialThenClose, .{ address, io });
        defer thread.join();

        var conn = try server.accept(io);
        defer conn.close(io);

        var read_buf: [64]u8 = undefined;
        var reader = conn.reader(io, &read_buf);
        if (reader.interface.takeDelimiterInclusive('\n')) |line| {
            try out.print("truncated:    Inclusive returned \"{s}\"\n", .{line});
        } else |err| {
            try out.print("truncated:    Inclusive returned {s}, so the ", .{@errorName(err)});
            try out.print("{d} buffered bytes get discarded\n", .{reader.interface.buffered().len});
        }
    }

    // 4. No program listens. The code closes the listener first, thus the
    //    port is real and not in use. The kernel replies for the computer,
    //    and the connect fails immediately. It does not wait.
    server.deinit(io);
    if (address.connect(io, .{ .mode = .stream })) |stream| {
        var s = stream;
        s.close(io);
        try out.writeAll("refused:      connected anyway\n");
    } else |err| {
        try out.print("refused:      {s}\n", .{@errorName(err)});
    }

    try out.writeAll(
        \\
        \\None of these are bugs in your program, and all of them will happen.
        \\The one worth remembering is the second: a truncated message came
        \\back as a successful read, and only the choice of call decided
        \\whether the server acted on half a request.
        \\
    );

    try out.flush();
}
