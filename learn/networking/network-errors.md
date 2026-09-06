# Failure Is Ordinary

> End of stream is not an error, and a truncated message can look like a good one.

On a network, failure is not exceptional. Clients disappear mid-request,
machines go away, and a connection ends every single time it succeeds. The
question is never whether these happen, only whether your code can tell them
apart.

```zig
const std = @import("std");

/// The client half of the clean-shutdown case: send a whole message, then
/// close. The server should see the message and then an orderly end.
fn sendThenClose(address: std.Io.net.IpAddress, io: std.Io) void {
    var stream = address.connect(io, .{ .mode = .stream }) catch return;
    defer stream.close(io);

    var buf: [64]u8 = undefined;
    var writer = stream.writer(io, &buf);
    writer.interface.writeAll("complete\n") catch return;
    writer.interface.flush() catch return;
}

/// The truncated case: half a message, then close. The bytes sent are
/// perfectly valid; there are just not enough of them to be a message.
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

    // 1. The peer finished and hung up. This is what every connection does
    //    eventually, so treating it as a failure means logging an error on
    //    every successful conversation you ever have.
    {
        const thread = try std.Thread.spawn(.{}, sendThenClose, .{ address, io });
        defer thread.join();

        var conn = try server.accept(io);
        defer conn.close(io);

        var read_buf: [64]u8 = undefined;
        var reader = conn.reader(io, &read_buf);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        try out.print("clean close:  read \"{s}\", then ", .{line});

        // The delimiter is still unconsumed, so step past it and read on.
        reader.interface.toss(1);
        if (reader.interface.takeDelimiterExclusive('\n')) |_| {
            try out.writeAll("more data\n");
        } else |err| {
            try out.print("{s} (expected: the client is done)\n", .{@errorName(err)});
        }
    }

    // 2. The peer hung up mid-message, and this is the trap. Read the
    //    doc comment on `takeDelimiterExclusive`: "End-of-stream is treated
    //    equivalent to a delimiter." A client that dies halfway through a
    //    line hands you a fragment that is indistinguishable from a message
    //    the sender finished. No error, no flag, nothing to check.
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

    // 3. The same half-message, read by the call that insists on actually
    //    seeing the delimiter. `takeDelimiterInclusive` returns the byte as
    //    part of the slice, which is precisely why it cannot invent one:
    //    end of stream without it is `EndOfStream`, and you drop the bytes.
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

    // 4. Nobody listening. The listener is closed first, so the port is
    //    real and unused: the kernel answers for the machine and the
    //    connect fails immediately rather than hanging.
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

`EndOfStream` after a complete message is what a successful conversation looks
like when it ends. Treat it as a failure and you will log an error for every
client that ever behaves correctly, which is the fastest way to make a log
worthless.

## The one that will bite you

```
truncated:    Exclusive returned "truncat" and no error
```

The client sent `"truncat"` and died. No newline was ever transmitted. And
`takeDelimiterExclusive` returned it as a message, successfully, with nothing
to check.

That is not a bug in the standard library. It is documented:

> End-of-stream is treated equivalent to a delimiter, unless it would result
> in a length 0 return value, in which case `null` is returned instead.

That behaviour is right for a text file, where the last line often has no
trailing newline. It is wrong for a socket, where the absence of the delimiter
is exactly how you learn the sender did not finish. If your protocol acts on
what it reads, this default will act on half a request.

## The call that refuses to invent a delimiter

```
truncated:    Inclusive returned EndOfStream, so the 7 buffered bytes get discarded
```

`takeDelimiterInclusive` returns the delimiter as part of the slice, which is
precisely why it cannot make one up. No delimiter means `EndOfStream`, and you
discard the fragment.

The rule is short: **on a stream where a partial message is possible, use
`takeDelimiterInclusive` and strip the delimiter yourself.** Reach for
`takeDelimiterExclusive` when a truncated final record is acceptable, which on
a socket it almost never is.

## Refused

```
refused:      ConnectionRefused
```

Nothing was listening, so the kernel on the other machine answered on its
behalf and the connect failed immediately. This is the good case. The bad case
is a host that does not answer at all, where the connect hangs until a
timeout you did not set, and the default is measured in minutes.

## What to do with each

| What happened | What it means | What to do |
| --- | --- | --- |
| `EndOfStream`, message complete | The client is done | Close, do not log an error |
| `EndOfStream`, message partial | The client died mid-request | Discard the fragment, close |
| `ConnectionRefused` | Nothing is listening there | Fail fast, back off before retrying |
| `ConnectionResetByPeer` | The peer closed hard, or crashed | Same as a partial message |
| `BrokenPipe` on write | The peer is gone and you are still writing | Stop, close, do not retry the write |

The last two are the ones a loopback test will not produce for you, which is
why they are in a table rather than in the snippet.
