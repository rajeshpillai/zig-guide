# Three Ways to Frame

> Length prefix, delimiter, self-describing, and what each one costs.

The previous chapter said a stream has no message boundaries. Framing is how
you put them back. There are three ways, every protocol you have used picks
one of them, and the choice is visible in the hex below.

```zig
const std = @import("std");

// ---------------------------------------------------------------- length

/// Two bytes of length, then exactly that many bytes. The receiver knows
/// how much to wait for before it has read a single byte of payload.
fn writeLengthPrefixed(w: *std.Io.Writer, payload: []const u8) !void {
    var header: [2]u8 = undefined;
    std.mem.writeInt(u16, &header, @intCast(payload.len), .big);
    try w.writeAll(&header);
    try w.writeAll(payload);
}

fn readLengthPrefixed(r: *std.Io.Reader) ![]const u8 {
    const header = try r.take(2);
    const len = std.mem.readInt(u16, header[0..2], .big);
    return r.take(len);
}

// ------------------------------------------------------------- delimiter

/// A byte that cannot appear in the payload ends the message. Cheap to
/// write, cheap to read by hand, and it costs you that byte forever.
fn writeDelimited(w: *std.Io.Writer, payload: []const u8) !void {
    try w.writeAll(payload);
    try w.writeByte('\n');
}

// ------------------------------------------------------- self-describing

/// The payload says how to read itself. Here a single tag byte selects
/// between a fixed-width integer and a length-prefixed string, which is
/// how RESP, protobuf and every tagged format work.
const Value = union(enum) {
    int: i32,
    text: []const u8,
};

fn writeTagged(w: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .int => |n| {
            try w.writeByte('i');
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, n, .big);
            try w.writeAll(&b);
        },
        .text => |s| {
            try w.writeByte('s');
            try writeLengthPrefixed(w, s);
        },
    }
}

fn printValue(w: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .int => |n| try w.print("int {d}\n", .{n}),
        .text => |s| try w.print("text \"{s}\"\n", .{s}),
    }
}

fn readTagged(r: *std.Io.Reader) !Value {
    const tag = try r.takeByte();
    return switch (tag) {
        'i' => .{ .int = std.mem.readInt(i32, (try r.take(4))[0..4], .big) },
        's' => .{ .text = try readLengthPrefixed(r) },
        else => error.BadTag,
    };
}

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var wire: [64]u8 = undefined;

    // Length prefix. Note the payload is untouched: it may contain any
    // byte at all, including the newline the next scheme cannot carry.
    {
        var w: std.Io.Writer = .fixed(&wire);
        try writeLengthPrefixed(&w, "PING");
        try out.print("length:    {x}\n", .{w.buffered()});

        var r: std.Io.Reader = .fixed(w.buffered());
        try out.print("           read back \"{s}\"\n\n", .{try readLengthPrefixed(&r)});
    }

    // Delimiter. Readable on the wire, which is why HTTP and SMTP use it.
    {
        var w: std.Io.Writer = .fixed(&wire);
        try writeDelimited(&w, "PING");
        try out.print("delimiter: {x}\n", .{w.buffered()});

        var r: std.Io.Reader = .fixed(w.buffered());
        try out.print("           read back \"{s}\"\n\n", .{try r.takeDelimiterExclusive('\n')});
    }

    // Self-describing. Costs a tag byte and buys you a payload whose type
    // the receiver did not have to agree on in advance.
    {
        var w: std.Io.Writer = .fixed(&wire);
        try writeTagged(&w, .{ .int = 4096 });
        try writeTagged(&w, .{ .text = "PING" });
        try out.print("tagged:    {x}\n", .{w.buffered()});

        var r: std.Io.Reader = .fixed(w.buffered());
        try out.writeAll("           read back ");
        try printValue(out, try readTagged(&r));
        try out.writeAll("           read back ");
        try printValue(out, try readTagged(&r));
        try out.writeByte('\n');
    }

    // What the delimiter scheme cannot do. The payload contains the
    // delimiter, so the reader stops early and silently: no error, just a
    // truncated message and the rest treated as the next one.
    {
        var w: std.Io.Writer = .fixed(&wire);
        try writeDelimited(&w, "two\nlines");

        var r: std.Io.Reader = .fixed(w.buffered());
        const first = try r.takeDelimiterExclusive('\n');
        try out.print("delimiter with a '\\n' in the payload: \"{s}\"", .{first});
        try out.print(" ({d} of {d} bytes)\n", .{ first.len, "two\nlines".len });
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.framing`)*

## Length prefix

```
00 04 50 49 4e 47
^^^^^ length      ^^^^^^^^^^^ payload
```

The receiver knows exactly how many bytes to wait for before it reads a single
byte of payload. That is what makes the parser in the last chapter possible,
and it is why this is the default choice for anything binary.

The payload is untouched, so it may contain any byte at all, including the
newline the next scheme cannot carry. The cost is that you must know the
length before you start writing, which means either buffering the whole
message or knowing its size in advance.

## Delimiter

```
50 49 4e 47 0a
^^^^^^^^^^^ payload  ^^ '\n'
```

Cheap to write, cheap to read, and readable on the wire, which is why HTTP,
SMTP, IMAP and Redis all use it for their text parts. You can debug it with
`nc` and your eyes.

The cost is permanent: that byte can never appear in a payload. The last line
of the output shows what happens when it does. The reader stops early and
reports no error at all. From its point of view the message ended exactly
where a message is supposed to end. The rest gets treated as the next message.

Real protocols solve this with escaping or with a length prefix on the body
only, which is exactly what HTTP does: delimited headers, then
`Content-Length` and a raw body.

## Self-describing

```
69 00 00 10 00   73 00 04 50 49 4e 47
^^ 'i'           ^^ 's'
```

A tag byte says how to read what follows. Here `i` means a fixed-width integer
and `s` means a length-prefixed string, so the receiver does not have to have
agreed in advance on what this field holds.

That is the shape of RESP, of protobuf wire types, of MessagePack and of CBOR.
The cost is a byte per value and a `switch` that has to reject unknown tags
rather than trusting them.

## Choosing

Both of the others are special cases of a length prefix. A delimiter is a
length you have to go looking for. A tag is a length whose meaning comes with
it. If you are designing something new and have no reason to prefer
readability, use a length prefix and stop thinking about it.

If you want it debuggable by hand, use a delimiter for the envelope and a
length for the body. That combination has survived thirty years of HTTP.
