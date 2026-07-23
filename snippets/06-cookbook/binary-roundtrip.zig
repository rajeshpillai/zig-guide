//! title: A Binary Wire Format
//! Explicit bytes in, explicit bytes out. No @bitCast of structs.

const std = @import("std");

const MAGIC: u32 = 0x5A49_4721; // "ZIG!"

const Header = struct {
    version: u16,
    payload_len: u32,

    const encoded_len = 10; // 4 magic + 2 version + 4 length

    // Field-by-field with a fixed endianness. Casting the struct's memory
    // with @bitCast or std.mem.asBytes would leak padding and host byte
    // order into the format: fine in RAM, wrong on a wire.
    fn encode(h: Header, buf: *[encoded_len]u8) void {
        std.mem.writeInt(u32, buf[0..4], MAGIC, .big);
        std.mem.writeInt(u16, buf[4..6], h.version, .big);
        std.mem.writeInt(u32, buf[6..10], h.payload_len, .big);
    }

    // Decoding is where trust ends: check everything you read.
    fn decode(buf: *const [encoded_len]u8) error{BadMagic}!Header {
        if (std.mem.readInt(u32, buf[0..4], .big) != MAGIC) return error.BadMagic;
        return .{
            .version = std.mem.readInt(u16, buf[4..6], .big),
            .payload_len = std.mem.readInt(u32, buf[6..10], .big),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const header = Header{ .version = 2, .payload_len = 400 };

    var wire: [Header.encoded_len]u8 = undefined;
    header.encode(&wire);

    try out.print("encoded {d} bytes:", .{wire.len});
    for (wire) |b| try out.print(" {X:0>2}", .{b});
    try out.print("\n", .{});

    const decoded = try Header.decode(&wire);
    try out.print("decoded: version={d} payload_len={d}\n", .{
        decoded.version, decoded.payload_len,
    });

    // Corrupt the first byte and the decoder refuses it.
    wire[0] ^= 0xFF;
    if (Header.decode(&wire)) |_| unreachable else |err| {
        try out.print("corrupted first byte: {t}\n", .{err});
    }

    try out.flush();
}
