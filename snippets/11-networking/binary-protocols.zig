//! title: Binary Protocols and Byte Order
//! A struct is not a wire format. Write the fields, and state which end is first.

const std = @import("std");

/// Each message in this example protocol starts with this header. The
/// header is always ten bytes. Thus the receiver can read a fixed quantity
/// before it knows other data. Compare `@sizeOf(Header)`, which is not ten.
const Header = struct {
    magic: u16,
    version: u8,
    kind: Kind,
    length: u32,
    checksum: u16,

    const Kind = enum(u8) { request = 1, response = 2 };
    const magic_value: u16 = 0x5A47; // "ZG"
    const wire_size = 10;

    /// One field at a time, with the endianness at each call. This needs
    /// more code than a cast of the bytes of the struct. It is the only
    /// method that works with a different compiler, a different target, or
    /// a peer in a different language.
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
            // `std.enums.fromInt` returns null, not an error. It replaced
            // `std.meta.intToEnum`, which does not exist now. An attacker
            // can control a tag byte from the wire. Thus `@enumFromInt` on
            // the byte is undefined behaviour.
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
    // the compiler can pad and change the order. You cannot send a struct
    // as it is, because you do not control the padding bytes.
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

    // Write as big-endian, read as little-endian. No function returns an
    // error. The length is only wrong. It is so large that the receiver
    // tries to allocate or wait for 83 million bytes.
    var swapped: std.Io.Reader = .fixed(w.buffered()[4..8]);
    try out.print("length read as big-endian:    {d}\n", .{
        std.mem.readInt(u32, w.buffered()[4..8], .big),
    });
    try out.print("length read as little-endian: {d}\n", .{
        try swapped.takeInt(u32, .little),
    });

    // The other half of a header check. If a peer does not use your
    // protocol, reject the peer on the first two bytes. Do this before
    // the parser trusts a length.
    var junk: std.Io.Reader = .fixed("GET / HTTP/1.1\r\n");
    if (Header.read(&junk)) |_| {
        try out.writeAll("\nan HTTP request into this parser: accepted\n");
    } else |err| {
        try out.print("\nan HTTP request into this parser: {s}\n", .{@errorName(err)});
    }

    try out.flush();
}
