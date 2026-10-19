//! title: Three Ways to Frame
//! Length prefix, delimiter, self-describing. Each protocol selects one.

const std = @import("std");

// ---------------------------------------------------------------- length

/// Two bytes of length, then exactly that number of bytes. Before the
/// receiver reads one byte of payload, it knows how much to wait for.
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

/// A byte that cannot occur in the payload ends the message. The delimiter
/// is cheap to write and easy to read by hand. The cost is that the payload
/// can never contain that byte.
fn writeDelimited(w: *std.Io.Writer, payload: []const u8) !void {
    try w.writeAll(payload);
    try w.writeByte('\n');
}

// ------------------------------------------------------- self-describing

/// The payload tells the receiver how to read the payload. Here, one tag
/// byte selects a fixed-width integer or a length-prefixed string. RESP,
/// protobuf and all tagged formats work in this way.
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

    // Length prefix. The framing does not change the payload. The payload
    // can contain any byte, also the newline that the next method cannot
    // carry.
    {
        var w: std.Io.Writer = .fixed(&wire);
        try writeLengthPrefixed(&w, "PING");
        try out.print("length:    {x}\n", .{w.buffered()});

        var r: std.Io.Reader = .fixed(w.buffered());
        try out.print("           read back \"{s}\"\n\n", .{try readLengthPrefixed(&r)});
    }

    // Delimiter. A person can read it on the wire, thus HTTP and SMTP use it.
    {
        var w: std.Io.Writer = .fixed(&wire);
        try writeDelimited(&w, "PING");
        try out.print("delimiter: {x}\n", .{w.buffered()});

        var r: std.Io.Reader = .fixed(w.buffered());
        try out.print("           read back \"{s}\"\n\n", .{try r.takeDelimiterExclusive('\n')});
    }

    // Self-describing. The cost is a tag byte. Then the receiver does not
    // need an agreement about the type of the payload before the message.
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

    // A limit of the delimiter method. The payload contains the delimiter,
    // thus the reader stops too early and does not report an error. The
    // message is too short, and the reader uses the rest as the next message.
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
