# A Text Protocol, Both Directions

> Parse a command out of bytes, render a reply back into bytes.

A text protocol is a delimiter framing with a grammar inside it. This one
borrows Redis's reply syntax because it is small and useful: one leading byte
says how to read the rest.

```zig
const std = @import("std");

/// Everything the server understands. The verb is an enum, not a string, so
/// the switch below is exhaustive. Adding a command without handling it is a
/// compile error, so no request can silently do nothing.
const Verb = enum { get, set, del, ping };

const Command = struct {
    verb: Verb,
    args: [2][]const u8 = .{ "", "" },
    count: usize = 0,
};

/// Commands are case-insensitive on the wire, like Redis and SMTP and HTTP
/// methods. Normalise the case once, here, so later code does not have to.
fn parse(line: []const u8) !Command {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const word = it.next() orelse return error.EmptyCommand;

    var lower: [16]u8 = undefined;
    if (word.len > lower.len) return error.UnknownCommand;
    const verb = std.meta.stringToEnum(Verb, std.ascii.lowerString(lower[0..word.len], word)) orelse
        return error.UnknownCommand;

    var cmd: Command = .{ .verb = verb };
    while (it.next()) |arg| {
        if (cmd.count == cmd.args.len) return error.TooManyArguments;
        cmd.args[cmd.count] = arg;
        cmd.count += 1;
    }
    return cmd;
}

/// The reply side. A leading byte says how to read the rest, which is the
/// self-describing framing from the previous chapter applied to text.
fn reply(w: *std.Io.Writer, cmd: Command) !void {
    switch (cmd.verb) {
        .ping => try w.writeAll("+PONG\r\n"),
        .set => if (cmd.count == 2) try w.writeAll("+OK\r\n") else try w.writeAll("-ERR wrong number of arguments\r\n"),
        .get => if (cmd.count == 1)
            try w.print("${d}\r\n{s}\r\n", .{ cmd.args[0].len, cmd.args[0] })
        else
            try w.writeAll("-ERR wrong number of arguments\r\n"),
        .del => try w.print(":{d}\r\n", .{cmd.count}),
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // A conversation as it would arrive: CRLF-terminated lines, in one
    // buffer, because the network does not deliver them one at a time.
    const conversation =
        "PING\r\n" ++
        "set name alice\r\n" ++
        "GET name\r\n" ++
        "DEL a b\r\n" ++
        "SET oops\r\n" ++
        "FLY me to the moon\r\n";

    var reader: std.Io.Reader = .fixed(conversation);
    var wire: [128]u8 = undefined;

    // `takeDelimiter` consumes the '\n' and returns null at the end, so this
    // is the complete read loop. The '\r' is still on the line. Strip it, but
    // do not assume it is there, because many clients omit it.
    while (try reader.takeDelimiter('\n')) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");

        var w: std.Io.Writer = .fixed(&wire);
        if (parse(line)) |cmd| {
            try reply(&w, cmd);
        } else |err| {
            // An error is a reply too. A server that closes the connection
            // instead leaves the client unable to tell which command was bad.
            try w.print("-ERR {s}\r\n", .{@errorName(err)});
        }

        // Print the reply with its CRLF escaped, so the framing is visible
        // instead of the terminal turning it into line breaks.
        try out.print("{s: <20} -> ", .{line});
        for (w.buffered()) |byte| switch (byte) {
            '\r' => try out.writeAll("\\r"),
            '\n' => try out.writeAll("\\n"),
            else => try out.writeByte(byte),
        };
        try out.writeByte('\n');
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.text-protocols`)*

## The verb is an enum, not a string

```zig
const Verb = enum { get, set, del, ping };

const verb = std.meta.stringToEnum(Verb, lowered) orelse return error.UnknownCommand;
```

Convert once, at the edge, and every `switch` after it can be exhaustive. If
you add a command to the enum and do not handle it, the compiler rejects the
program. If the verb stays a `[]const u8`, the same mistake gives a request
that silently does nothing, and a user finds it later.

`parse` is the one place where this conversion can happen, because it is the
only place that knows the bytes came from outside.

## Normalise at the edge

Commands are case-insensitive on the wire, as they are in Redis, SMTP and HTTP
methods. Lowercase once, in `parse`, so no later code has to remember that
`GET`, `get` and `Get` are the same thing. If many functions have to remember
it, one of them will eventually get it wrong.

## Errors are replies

```zig
} else |err| {
    try w.print("-ERR {s}\r\n", .{@errorName(err)});
}
```

Do not close the connection because of a malformed command. The client is
still there and can still send valid commands. It does not know which command
you rejected unless you tell it. If you close the socket on a parse error,
every typo causes a reconnect. Under load, that becomes many reconnects at
once.

`@errorName` sends your internal error names to whoever is connected. That is
fine for a guide. For a service on a public port, decide whether you want to
expose them.

## The `\r` is not optional and not guaranteed

```zig
const line = std.mem.trimEnd(u8, raw, "\r");
```

The specification says CRLF. Real clients, including anything a person types
into `nc`, send LF alone. Read until `\n`, then strip a `\r` if one is there.
If you require the `\r`, you reject clients that send LF alone. If you assume
it is absent, the last character is wrong for clients that send CRLF.

## Escape the framing when you print it

The output above shows `\r\n` as text and does not end the line there. If a
reply is printed raw, the terminal turns its framing into line breaks, and you
can no longer see what was sent. When you debug a protocol, you need to see
the exact bytes, and a terminal hides characters like `\r`.
