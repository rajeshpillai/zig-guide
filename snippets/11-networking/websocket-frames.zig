//! title: WebSocket Frames
//! The frame header, the three length forms, the mask, and what std rejects.

const std = @import("std");
const WebSocket = std.http.Server.WebSocket;

fn printBytes(out: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes, 0..) |b, i| {
        if (i > 0) try out.writeByte(' ');
        try out.print("{x:0>2}", .{b});
    }
}

/// A frame from a client. The server writes frames with std, but std has no
/// client, so this is the other half. RFC 6455 requires a client to mask
/// each frame, and a server must refuse a frame without the mask.
fn writeClientFrame(
    w: *std.Io.Writer,
    opcode: WebSocket.Opcode,
    fin: bool,
    mask: [4]u8,
    payload: []const u8,
) !void {
    try w.writeByte(@bitCast(WebSocket.Header0{ .opcode = opcode, .fin = fin }));
    if (payload.len <= 125) {
        try w.writeByte(@bitCast(WebSocket.Header1{
            .payload_len = @enumFromInt(payload.len),
            .mask = true,
        }));
    } else if (payload.len <= 0xffff) {
        try w.writeByte(@bitCast(WebSocket.Header1{ .payload_len = .len16, .mask = true }));
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(@bitCast(WebSocket.Header1{ .payload_len = .len64, .mask = true }));
        try w.writeInt(u64, payload.len, .big);
    }
    try w.writeAll(&mask);
    // The mask is four bytes. Each byte i of the payload gets an XOR with byte
    // i % 4 of the mask. The same XOR on the receiver gives the payload back.
    for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
}

/// Print the fields of a packed struct with the bits that each one uses.
fn printLayout(out: *std.Io.Writer, comptime T: type) !void {
    try out.print("  {s}:", .{@typeName(T)[std.mem.findScalarLast(u8, @typeName(T), '.').? + 1 ..]});
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        const low = @bitOffsetOf(T, name);
        const high = low + @bitSizeOf(F) - 1;
        if (low == high) {
            try out.print(" {s}={d}", .{ name, low });
        } else {
            try out.print(" {s}={d}-{d}", .{ name, low, high });
        }
    }
    try out.print("\n", .{});
}

/// Give one frame to std, as a server reads it, and print the result.
fn serverReads(out: *std.Io.Writer, name: []const u8, frame: []const u8) !void {
    var in: std.Io.Reader = .fixed(frame);
    var unused: [0]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&unused);
    var ws: WebSocket = .{ .key = "", .input = &in, .output = &sink };
    try out.print("  {s:<26} -> ", .{name});
    if (ws.readSmallMessage()) |msg| {
        try out.print("{t} \"{s}\"\n", .{ msg.opcode, msg.data });
    } else |err| {
        try out.print("error.{t}\n", .{err});
    }
}

var big: [70000]u8 = @splat('x');

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // ------------------------------------------------ the three length forms

    // A server frame from std. The length field has 7 bits. The values 126
    // and 127 mean that a 16-bit or a 64-bit length follows.
    try out.print("server frames, header bytes:\n", .{});
    var frame_buf: [70016]u8 = undefined;
    for ([_]usize{ 5, 125, 126, 200, 70000 }) |len| {
        var w: std.Io.Writer = .fixed(&frame_buf);
        var ws: WebSocket = .{ .key = "", .input = undefined, .output = &w };
        try ws.writeMessage(big[0..len], .text);
        const header_len: usize = switch (frame_buf[1] & 0x7f) {
            126 => 4,
            127 => 10,
            else => 2,
        };
        try out.print("  {d:>5} bytes: ", .{len});
        try printBytes(out, frame_buf[0..header_len]);
        try out.print("\n", .{});
    }

    // ----------------------------------------------------- the header bits

    // The first two bytes are two packed structs in std. Zig packs the
    // first field into the lowest bits.
    try out.print("\nthe header structs in std, field=bits, bit 0 first:\n", .{});
    try printLayout(out, WebSocket.Header0);
    try printLayout(out, WebSocket.Header1);

    // A @bitCast reads the fields of one byte.
    try out.print("\nthe first two bytes, 81 85:\n", .{});
    const h0: WebSocket.Header0 = @bitCast(@as(u8, 0x81));
    const h1: WebSocket.Header1 = @bitCast(@as(u8, 0x85));
    try out.print("  byte 0 = {b:0>8}: fin={} rsv=0 opcode={t}\n", .{ @as(u8, 0x81), h0.fin, h0.opcode });
    try out.print("  byte 1 = {b:0>8}: mask={} length={d}\n", .{ @as(u8, 0x85), h1.mask, @intFromEnum(h1.payload_len) });

    // ------------------------------------------------------------ the mask

    // The example from section 5.7 of RFC 6455: "Hello", masked.
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    var hello_buf: [16]u8 = undefined;
    var hello_w: std.Io.Writer = .fixed(&hello_buf);
    try writeClientFrame(&hello_w, .text, true, mask, "Hello");
    const hello = hello_w.buffered();

    try out.print("\nmask a client frame, mask ", .{});
    try printBytes(out, &mask);
    try out.print(":\n", .{});
    for ("Hello", 0..) |c, i| {
        try out.print("  {d}  '{c}' {x:0>2} ^ {x:0>2} = {x:0>2}\n", .{ i, c, c, mask[i % 4], c ^ mask[i % 4] });
    }
    try out.print("frame: ", .{});
    try printBytes(out, hello);
    const rfc = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    try out.print("\nthe same as RFC 6455: {}\n", .{std.mem.eql(u8, hello, &rfc)});

    // ------------------------------------------------ what std.http accepts

    // Each frame goes to readSmallMessage, as a server reads it.
    try out.print("\nstd reads each frame:\n", .{});
    try serverReads(out, "masked text", hello);

    var f: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&f);
    try writeClientFrame(&w, .ping, true, mask, "are you there");
    try serverReads(out, "masked ping", w.buffered());

    w = .fixed(&f);
    try writeClientFrame(&w, .pong, true, mask, "");
    try writeClientFrame(&w, .text, true, mask, "after");
    try serverReads(out, "pong, then text", w.buffered());

    try serverReads(out, "unmasked text", &.{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' });

    w = .fixed(&f);
    try writeClientFrame(&w, .text, false, mask, "Hel");
    try writeClientFrame(&w, .continuation, true, mask, "lo");
    try serverReads(out, "\"Hel\" + \"lo\" in 2 frames", w.buffered());

    w = .fixed(&f);
    try writeClientFrame(&w, .continuation, true, mask, "lo");
    try serverReads(out, "continuation alone", w.buffered());

    // The length says 300 bytes. The reader has a buffer of 10 bytes.
    try serverReads(out, "300 bytes, 10-byte buffer", &.{ 0x81, 0xfe, 0x01, 0x2c, 1, 2, 3, 4, 5, 6 });

    w = .fixed(&f);
    try writeClientFrame(&w, .connection_close, true, mask, &.{ 0x03, 0xe8 });
    try serverReads(out, "close, code 1000", w.buffered());

    try out.flush();
}
