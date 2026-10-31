# A Text Protocol, Both Directions

> Parse a command from bytes, and write a reply back into bytes.

A text protocol is delimiter framing with a grammar in it. This protocol uses
the reply syntax of Redis, because that syntax is small and useful. The first
byte of a reply tells the reader how to read the rest of the reply.

```zig
const std = @import("std");

/// All the commands that the server knows. The verb is an enum, not a
/// string, thus the switch below is exhaustive. If you add a command and do
/// not handle it, the compiler gives an error. Thus no request can do
/// nothing and report nothing.
const Verb = enum { get, set, del, ping };

const Command = struct {
    verb: Verb,
    args: [2][]const u8 = .{ "", "" },
    count: usize = 0,
};

/// On the wire, commands are not case-sensitive, as in Redis, SMTP and HTTP
/// methods. Normalise the case one time, here. Then later code need not.
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

/// The reply side. The first byte tells the reader how to read the rest.
/// This is the self-describing framing from the previous chapter, for text.
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

    // A conversation as it arrives: lines that end in CRLF, in one buffer.
    // The network does not deliver the lines one at a time.
    const conversation =
        "PING\r\n" ++
        "set name alice\r\n" ++
        "GET name\r\n" ++
        "DEL a b\r\n" ++
        "SET oops\r\n" ++
        "FLY me to the moon\r\n";

    var reader: std.Io.Reader = .fixed(conversation);
    var wire: [128]u8 = undefined;

    // `takeDelimiter` consumes the '\n' and returns null at the end. Thus
    // this is the full read loop. The '\r' is still on the line. Remove it,
    // but do not think that it is always there. Many clients do not send it.
    while (try reader.takeDelimiter('\n')) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");

        var w: std.Io.Writer = .fixed(&wire);
        if (parse(line)) |cmd| {
            try reply(&w, cmd);
        } else |err| {
            // An error is also a reply. If the server closes the connection,
            // the client cannot know which command was bad.
            try w.print("-ERR {s}\r\n", .{@errorName(err)});
        }

        // Escape the CRLF in the reply. Then you can see the framing, and
        // the terminal does not change the CRLF into line breaks.
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

Convert the verb one time, at the edge. Then each `switch` after the
conversion can be exhaustive. If you add a command to the enum and do not
handle the command, the compiler rejects the program. If the verb stays a
`[]const u8`, the same mistake gives a request that does nothing and reports
nothing. Then a user finds the problem later.

`parse` is the one place where this conversion can occur. It is the only
place that knows that the bytes came from outside the program.

## Normalise at the edge

On the wire, commands are not case-sensitive, as in Redis, SMTP and HTTP
methods. Change the command to lowercase one time, in `parse`. Then no later
code must remember that `GET`, `get` and `Get` are the same command. If many
functions must remember this rule, one of the functions will possibly get it
wrong.

## Errors are replies

```zig
} else |err| {
    try w.print("-ERR {s}\r\n", .{@errorName(err)});
}
```

Do not close the connection because of a malformed command. The client is
still connected and can still send valid commands. The client does not know
which command you rejected, unless you tell it. If you close the socket on a
parse error, each typo causes a new connection. Under load, that becomes many
new connections at the same time.

`@errorName` sends the names of your internal errors to the connected client.
For a guide, that is satisfactory. For a service on a public port, decide if
you want to show these names.

## The `\r` is not optional and not guaranteed

```zig
const line = std.mem.trimEnd(u8, raw, "\r");
```

The specification says CRLF. Real clients send LF only, and so does a person
who types into `nc`. Read until `\n`, then remove a `\r` if there is one.

- If you require the `\r`, you reject the clients that send LF only.
- If you think that the `\r` is not there, the last character is wrong for
  the clients that send CRLF.

## Escape the framing when you print it

The output above shows `\r\n` as text, and the line does not end there. If
the program prints a raw reply, the terminal changes the framing into line
breaks. Then you cannot see the bytes that the server sent. To debug a
protocol, you must see the exact bytes, and a terminal hides characters such
as `\r`.
