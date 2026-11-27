# The Protocol

> Commands in, events out. A text protocol inside WebSocket messages, a tagged union for each direction, and a line size that the compiler checks.

WebSocket delivers messages with clear edges. One message is one frame, or
one set of fragments, and the receiver gets the whole message. Thus this
protocol needs no delimiter and no length prefix, unlike the protocols in
[Three Ways to Frame](https://www.ziglang.in/learn/networking/framing/). The protocol only says
what the bytes in one message mean.

The protocol has two directions:

- A client sends **commands**: `nick tejas` to pick a name, and
  `say hello` to talk.
- The server sends **events**: `welcome`, `joined`, `left`, `msg` and
  `error`.

Text is easy to read in a trace and easy to type into a test client. A
binary protocol would be smaller, and a chat line is small already.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.chat-protocol`)*

## Commands: parse into a tagged union

```zig
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
```

*Quoted from the source: `parseCommand` from `snippets/11-networking/chat-protocol.zig`.*

The result is a `Command`, a tagged union with one field for each verb. The
code after the parser uses a `switch`, and the compiler requires a case for
each verb. If you add a verb, each `switch` that forgets it fails to
compile.

```
commands from a client:
  nick tejas               -> nick "tejas"
  say hello, room          -> say "hello, room"
  say  two spaces          -> say " two spaces"
  nick Tejas               -> error.BadNick
  nick aaaaaaaaaaaaaaaaa   -> error.BadNick
  say                      -> error.MissingArgument
  (long input)             -> error.TextTooLong
  shout hello              -> error.UnknownCommand
                           -> error.UnknownCommand
```

Three rules in the parser are deliberate:

- **The text of `say` is exact.** The parser splits at the first space only.
  `say  two spaces` keeps the second space as the first byte of the text.
- **A nickname is lowercase letters, digits and `_`, 16 bytes or fewer.**
  Each event prints the nickname, thus a nickname with a space or a colon
  could make a `msg` event look like a different event.
- **Text has a limit of 120 bytes.** The next section shows why the limit is
  necessary.

The slices in a `Command` point into the message. The parser copies
nothing. The message must stay valid while you use the command. In the server,
the frame reader keeps the message in its buffer until the next call.

## Events: format into a fixed line

```zig
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
```

*Quoted from the source: `Line` from `snippets/11-networking/chat-protocol.zig`.*

The hub copies each event into the outbox of each member. A slice would
point into memory that one task owns, and the other tasks read it later. A
`Line` is a fixed array with a length, thus each copy owns its bytes, and
the hub needs no allocator.

A fixed buffer needs a maximum. The longest event is a `msg` with the
longest nickname and the longest text. A `comptime` block in the file adds
the four lengths: `"msg ".len`, `max_nick`, `": ".len` and `max_text`. If
the sum is larger than `Line.capacity`, the block calls `@compileError`.

The check runs in the compiler. If you raise `max_text` to 150, the program
does not compile. Because of that check, `format` uses `catch unreachable`:
the buffer can hold each event.

```zig
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
```

*Quoted from the source: `format` from `snippets/11-networking/chat-protocol.zig`.*

```
events from the server:
  welcome tejas (3 online)
  joined vishaka
  msg vishaka: hello, room
  left shivam (quit)
  left shivam (too_slow)
  error NickTaken
```

The `{t}` format prints the name of an enum tag or of an error. Thus the
reason of a `left` event and the name of a refusal need no table of
strings. The program also formats the longest possible event, and CI
compares the result:

```
the longest event: 142 of 160 bytes
```

## The refusals

`Refusal` is the set of errors that the server can send back as an `error`
event:

```zig
/// Why the server refused a command. The parse errors, and the errors of
/// the hub in the next chapter.
pub const Refusal = ParseError || error{ NickTaken, RoomFull, NoNickYet, AlreadyJoined };
```

*Quoted from the source: `Refusal` from `snippets/11-networking/chat-protocol.zig`.*

It joins the errors of the parser with the errors of the hub (the next
chapter) with `||`. Thus one `error` event covers both, and the `err` field
of `Event` cannot hold an error that a client must never see, for example
`error.ReadFailed`.
