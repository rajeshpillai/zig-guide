//! title: The Chat Protocol
//! Commands in, events out: a small text protocol inside WebSocket messages.

const std = @import("std");

/// WebSocket already frames each message, thus a command is one message
/// and needs no delimiter. The protocol only has to say what the bytes in
/// a message mean.
pub const max_nick = 16;
pub const max_text = 120;

/// What a client can send.
pub const Command = union(enum) {
    nick: []const u8,
    say: []const u8,
};

pub const ParseError = error{
    UnknownCommand,
    MissingArgument,
    BadNick,
    TextTooLong,
};

/// Parse one message from a client. The slices in the result point into
/// `message`.
pub fn parseCommand(message: []const u8) ParseError!Command {
    const space = std.mem.findScalar(u8, message, ' ');
    const verb = message[0 .. space orelse message.len];
    const arg = if (space) |i| message[i + 1 ..] else "";

    if (std.mem.eql(u8, verb, "nick")) {
        if (arg.len == 0) return error.MissingArgument;
        if (arg.len > max_nick) return error.BadNick;
        for (arg) |c| {
            if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_') return error.BadNick;
        }
        return .{ .nick = arg };
    }
    if (std.mem.eql(u8, verb, "say")) {
        if (arg.len == 0) return error.MissingArgument;
        if (arg.len > max_text) return error.TextTooLong;
        return .{ .say = arg };
    }
    return error.UnknownCommand;
}

/// Why the server refused a command. The parse errors, and the errors of
/// the hub in the next chapter.
pub const Refusal = ParseError || error{ NickTaken, RoomFull, NoNickYet, AlreadyJoined };

/// What the server sends.
pub const Event = union(enum) {
    welcome: struct { nick: []const u8, online: u8 },
    joined: []const u8,
    left: struct { nick: []const u8, reason: Reason },
    msg: struct { nick: []const u8, text: []const u8 },
    err: Refusal,

    pub const Reason = enum { quit, too_slow };
};

/// One event, formatted, in a fixed buffer. The hub copies a Line into
/// the outbox of each member, thus a Line must not point anywhere else.
pub const Line = struct {
    pub const capacity = 160;
    buf: [capacity]u8 = undefined,
    len: u8 = 0,

    pub fn bytes(line: *const Line) []const u8 {
        return line.buf[0..line.len];
    }
};

// The longest event is a `msg` with the longest nick and text. The
// compiler checks that it fits, thus `format` cannot fail at run time.
comptime {
    const longest = "msg ".len + max_nick + ": ".len + max_text;
    if (longest > Line.capacity) @compileError("Line.capacity is too small for a msg event");
}

pub fn format(event: Event) Line {
    var line: Line = .{};
    var w: std.Io.Writer = .fixed(&line.buf);
    (switch (event) {
        .welcome => |e| w.print("welcome {s} ({d} online)", .{ e.nick, e.online }),
        .joined => |nick| w.print("joined {s}", .{nick}),
        .left => |e| w.print("left {s} ({t})", .{ e.nick, e.reason }),
        .msg => |e| w.print("msg {s}: {s}", .{ e.nick, e.text }),
        .err => |e| w.print("error {t}", .{e}),
    }) catch unreachable;
    line.len = @intCast(w.buffered().len);
    return line;
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try out.print("commands from a client:\n", .{});
    const long_nick: [max_nick + 1]u8 = @splat('a');
    const long_text = "say " ++ @as([max_text + 1]u8, @splat('x'));
    const inputs = [_][]const u8{
        "nick tejas",
        "say hello, room",
        "say  two spaces",
        "nick Tejas",
        "nick " ++ long_nick,
        "say",
        long_text,
        "shout hello",
        "",
    };
    for (inputs) |input| {
        const shown = if (input.len > 24) "(long input)" else input;
        try out.print("  {s:<24} -> ", .{shown});
        if (parseCommand(input)) |command| switch (command) {
            .nick => |n| try out.print("nick \"{s}\"\n", .{n}),
            .say => |t| try out.print("say \"{s}\"\n", .{t}),
        } else |err| {
            try out.print("error.{t}\n", .{err});
        }
    }

    try out.print("\nevents from the server:\n", .{});
    const events = [_]Event{
        .{ .welcome = .{ .nick = "tejas", .online = 3 } },
        .{ .joined = "vishaka" },
        .{ .msg = .{ .nick = "vishaka", .text = "hello, room" } },
        .{ .left = .{ .nick = "shivam", .reason = .quit } },
        .{ .left = .{ .nick = "shivam", .reason = .too_slow } },
        .{ .err = error.NickTaken },
    };
    for (events) |event| {
        const line = format(event);
        try out.print("  {s}\n", .{line.bytes()});
    }

    const nick: [max_nick]u8 = @splat('a');
    const text: [max_text]u8 = @splat('x');
    const longest = format(.{ .msg = .{ .nick = &nick, .text = &text } });
    try out.print("\nthe longest event: {d} of {d} bytes\n", .{ longest.len, Line.capacity });

    try out.flush();
}
