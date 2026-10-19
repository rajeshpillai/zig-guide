//! title: A Binary Wire Format
//! Write explicit bytes and read explicit bytes. Do not use @bitCast on structs.

const std = @import("std");

const MAGIC: u32 = 0x5A49_4721; // "ZIG!"

const Header = struct {
    version: u16,
    payload_len: u32,

    const encoded_len = 10; // 4 magic + 2 version + 4 length

    // Write one field at a time with a fixed endianness. A cast of the memory
    // of the struct with @bitCast or std.mem.asBytes puts padding and the byte
    // order of the host into the format. That cast works in RAM. It is wrong
    // in a file or on a network.
    fn encode(h: Header, buf: *[encoded_len]u8) void {
        std.mem.writeInt(u32, buf[0..4], MAGIC, .big);
        std.mem.writeInt(u16, buf[4..6], h.version, .big);
        std.mem.writeInt(u32, buf[6..10], h.payload_len, .big);
    }

    // The decoder reads untrusted bytes. Thus check all of the bytes that you read.
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

    // Change the first byte. The decoder does not accept the result.
    wire[0] ^= 0xFF;
    if (Header.decode(&wire)) |_| unreachable else |err| {
        try out.print("corrupted first byte: {t}\n", .{err});
    }

    try out.flush();
}
