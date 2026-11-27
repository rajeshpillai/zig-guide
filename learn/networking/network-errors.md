# Failure Is Ordinary

> The end of a stream is not an error, and a truncated message can look like a good message.

On a network, failure is normal. A client can stop in the middle of a
request, and a computer can stop. Also, each connection ends when it
succeeds. These events will occur. The important question is if your code can
see the difference between them.

```zig
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
```

*Built and run natively by CI, over real loopback sockets. Browser wasm has no sockets. (`11-networking.network-errors`)*

## The clean close

```
clean close:  read "complete", then EndOfStream (expected: the client is done)
```

`EndOfStream` after a complete message is the normal end of a successful
conversation. If you make it a failure, you log an error for each client that
operates correctly. Then the log has no value.

## The truncated message

```
truncated:    Exclusive returned "truncat" and no error
```

The client sent `"truncat"` and then stopped. The client did not send a
newline. But `takeDelimiterExclusive` returned the bytes as a message, with
success. The result has no error and no flag to check.

This is not a bug in the standard library. The documentation says:

> End-of-stream is treated equivalent to a delimiter, unless it would result
> in a length 0 return value, in which case `error.EndOfStream` is returned
> instead.

That behaviour is correct for a text file, because the last line of a text
file often has no newline at the end. The behaviour is wrong for a socket. On
a socket, the absence of the delimiter is the only sign that the sender did not
complete the message. If your protocol does an action on the data that it
reads, this default does an action on half of a request.

## The call that does not invent a delimiter

```
truncated:    Inclusive returned EndOfStream, so the 7 buffered bytes get discarded
```

`takeDelimiterInclusive` returns the delimiter as a part of the slice. Thus
the function cannot invent a delimiter. If there is no delimiter, the result
is `EndOfStream`, and you discard the fragment.

The rule is short: **on a stream that can carry a partial message, use
`takeDelimiterInclusive`, and remove the delimiter in your code.** Use
`takeDelimiterExclusive` only when a truncated last record is acceptable. On
a socket, a truncated record is almost never acceptable.

## Refused

```
refused:      ConnectionRefused
```

No program listened on the port. Thus the kernel on the other computer sent
the answer, and the connect failed immediately. This is the good case. In the
bad case, the host does not answer. Then the connect waits until a timeout
that you did not set. The default timeout is some minutes long.

## What to do for each error

| What happened | What it means | What to do |
| --- | --- | --- |
| `EndOfStream`, message complete | The client completed its work | Close, do not log an error |
| `EndOfStream`, message partial | The client stopped in the middle of a request | Discard the fragment, close |
| `ConnectionRefused` | No program listens there | Fail fast, wait before you try again |
| `ConnectionResetByPeer` | The peer closed abruptly, or crashed | Same as a partial message |
| `BrokenPipe` on write | The peer is gone, and you still write | Stop, close, do not try the write again |

A loopback test does not cause the last two errors. For this reason, the last
two errors are in the table and not in the snippet.
