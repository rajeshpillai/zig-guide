//! title: A Text Protocol, Both Directions
//! Parse a command from bytes, and write a reply back into bytes.

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
