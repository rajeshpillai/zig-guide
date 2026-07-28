//! title: What a Socket Is
//! native
//! An address, a mode, and a handle. Everything else is reading and writing.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // An address is just data. Parsing one touches no network, opens
    // nothing, and cannot fail for any reason except bad text.
    const wanted = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    try out.print("asked for port:  {d}\n", .{wanted.getPort()});

    // Port 0 means "any free port, you pick". The kernel assigns one when
    // the socket is bound, and the socket records it. Hardcoding a port is
    // what makes a test suite fail when two of them run at once.
    var server = try wanted.listen(io, .{});
    defer server.deinit(io);

    const bound = server.socket.address;
    try out.print("kernel gave me:  {s}\n", .{if (bound.getPort() == 0) "port 0" else "a real port"});
    try out.print("still loopback:  {}\n\n", .{bound.getPort() != wanted.getPort()});

    // `.stream` is TCP: an ordered, reliable byte stream with a connection
    // behind it. `.dgram` is UDP, and has none of those three properties.
    var client = try bound.connect(io, .{ .mode = .stream });
    defer client.close(io);

    var accepted = try server.accept(io);
    defer accepted.close(io);

    try out.writeAll("connected. two handles now refer to one conversation.\n\n");

    // From here nothing is socket-shaped. The same reader and writer
    // interfaces a file uses carry the bytes, which is why the protocol
    // chapters that follow can run without a network at all.
    var write_buf: [64]u8 = undefined;
    var writer = client.writer(io, &write_buf);
    try writer.interface.writeAll("ping\n");
    try writer.interface.flush();

    var read_buf: [64]u8 = undefined;
    var reader = accepted.reader(io, &read_buf);
    const line = try reader.interface.takeDelimiterExclusive('\n');
    try out.print("server read:     \"{s}\"\n", .{line});

    // Closing is not optional and not automatic. Every socket is a file
    // descriptor, and a server that leaks them stops accepting connections
    // once it hits the process limit, long before it runs out of memory.
    try out.writeAll("closing: the defers above release three descriptors\n");

    try out.flush();
}
