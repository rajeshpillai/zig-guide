//! title: Binary Protocols and Byte Order
//! A struct is not a wire format. Write the fields, and say which end first.

const std = @import("std");

/// The header every message on this imaginary protocol starts with. Ten
/// bytes, always, so the receiver can read a fixed amount before it knows
/// anything else. Compare `@sizeOf(Header)`, which is not ten.
const Header = struct {
    magic: u16,
    version: u8,
    kind: Kind,
    length: u32,
    checksum: u16,

    const Kind = enum(u8) { request = 1, response = 2 };
    const magic_value: u16 = 0x5A47; // "ZG"
    const wire_size = 10;

    /// Field by field, endianness stated at every call. This is more typing
    /// than casting the struct's bytes and it is the only version that
    /// survives a different compiler, a different target, or a peer written
    /// in another language.
    fn write(self: Header, w: *std.Io.Writer) !void {
        try w.writeInt(u16, self.magic, .big);
        try w.writeInt(u8, self.version, .big);
        try w.writeInt(u8, @intFromEnum(self.kind), .big);
        try w.writeInt(u32, self.length, .big);
        try w.writeInt(u16, self.checksum, .big);
    }

    fn read(r: *std.Io.Reader) !Header {
        const magic = try r.takeInt(u16, .big);
        if (magic != magic_value) return error.NotOurProtocol;

        const version = try r.takeInt(u8, .big);
        const kind = try r.takeInt(u8, .big);
        return .{
            .magic = magic,
            .version = version,
            // `std.enums.fromInt` returns null rather than an error, and it
            // replaced `std.meta.intToEnum`, which no longer exists. A tag
            // byte off the wire is attacker-controlled, so `@enumFromInt` on
            // it is undefined behaviour, not a shortcut.
            .kind = std.enums.fromInt(Kind, kind) orelse return error.UnknownKind,
            .length = try r.takeInt(u32, .big),
            .checksum = try r.takeInt(u16, .big),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const payload = "hello";
    const header: Header = .{
        .magic = Header.magic_value,
        .version = 1,
        .kind = .request,
        .length = payload.len,
        .checksum = 0xBEEF,
    };

    // The struct in memory is larger than the message on the wire, because
    // the compiler is free to pad and reorder. That gap is exactly why you
    // cannot send a struct: the padding bytes are not yours to define.
    try out.print("@sizeOf(Header) = {d}, on the wire = {d}\n\n", .{
        @sizeOf(Header),
        Header.wire_size,
    });

    var wire: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&wire);
    try header.write(&w);
    try w.writeAll(payload);

    try out.print("wire: {x}\n", .{w.buffered()});
    try out.print("      ^^^^ magic  ^^ version  ^^ kind  ^^^^^^^^ length\n\n", .{});

    var r: std.Io.Reader = .fixed(w.buffered());
    const back = try Header.read(&r);
    const body = try r.take(back.length);
    try out.print("decoded: version {d}, {s}, {d} bytes: \"{s}\"\n\n", .{
        back.version,
        @tagName(back.kind),
        back.length,
        body,
    });

    // Big-endian written, little-endian read. Nothing errors: the length
    // is simply wrong, and it is wrong by a factor that makes the receiver
    // try to allocate or wait for 83 million bytes.
    var swapped: std.Io.Reader = .fixed(w.buffered()[4..8]);
    try out.print("length read as big-endian:    {d}\n", .{
        std.mem.readInt(u32, w.buffered()[4..8], .big),
    });
    try out.print("length read as little-endian: {d}\n", .{
        try swapped.takeInt(u32, .little),
    });

    // The other half of a header check. A peer that is not speaking your
    // protocol at all should be rejected on the first two bytes, before
    // any length is trusted enough to act on.
    var junk: std.Io.Reader = .fixed("GET / HTTP/1.1\r\n");
    if (Header.read(&junk)) |_| {
        try out.writeAll("\nan HTTP request into this parser: accepted\n");
    } else |err| {
        try out.print("\nan HTTP request into this parser: {s}\n", .{@errorName(err)});
    }

    try out.flush();
}
