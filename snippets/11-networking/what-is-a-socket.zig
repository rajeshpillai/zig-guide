//! title: What a Socket Is
//! native
//! An address, a mode, and a handle. After that, the code only reads and writes.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // An address is only data. The parse does not use the network and
    // opens nothing. It fails only if the text is not an address.
    const wanted = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    try out.print("asked for port:  {d}\n", .{wanted.getPort()});

    // Port 0 tells the kernel to select a free port. The kernel gives the
    // port when it binds the socket, and the socket records the port. A
    // fixed port makes a test suite fail when two copies run at one time.
    var server = try wanted.listen(io, .{});
    defer server.deinit(io);

    const bound = server.socket.address;
    try out.print("kernel gave me:  {s}\n", .{if (bound.getPort() == 0) "port 0" else "a real port"});
    try out.print("still loopback:  {}\n\n", .{bound.getPort() != wanted.getPort()});

    // `.stream` is TCP: an ordered and reliable byte stream on a
    // connection. `.dgram` is UDP, which has none of these three properties.
    var client = try bound.connect(io, .{ .mode = .stream });
    defer client.close(io);

    var accepted = try server.accept(io);
    defer accepted.close(io);

    try out.writeAll("connected. two handles now refer to one conversation.\n\n");

    // After this point, the code does not use sockets. The reader and
    // writer interfaces that a file uses move the bytes. Thus the next
    // protocol chapters can run without a network.
    var write_buf: [64]u8 = undefined;
    var writer = client.writer(io, &write_buf);
    try writer.interface.writeAll("ping\n");
    try writer.interface.flush();

    var read_buf: [64]u8 = undefined;
    var reader = accepted.reader(io, &read_buf);
    const line = try reader.interface.takeDelimiterExclusive('\n');
    try out.print("server read:     \"{s}\"\n", .{line});

    // No other code closes a socket for you. You must close each socket.
    // Each socket is a file descriptor. If a server does not close its
    // sockets, it cannot accept connections at the process limit. This
    // occurs a long time before the server has no more memory.
    try out.writeAll("closing: the defers above release three descriptors\n");

    try out.flush();
}
