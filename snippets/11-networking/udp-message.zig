//! title: UDP Datagrams
//! native
//! Connectionless messages: two bound sockets, no threads required.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // A datagram socket binds rather than listens: there is no connection
    // to accept, just an address that can receive messages.
    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const receiver = try any_port.bind(io, .{ .mode = .dgram });
    defer receiver.close(io);

    const sender = try any_port.bind(io, .{ .mode = .dgram });
    defer sender.close(io);

    // Send first, receive second, one thread. The kernel holds the
    // datagram until someone asks; that decoupling is the whole model.
    // `receiver.address` carries the resolved ephemeral port.
    try sender.send(io, &receiver.address, "reading: 21.4C");

    var data_buf: [256]u8 = undefined;
    const msg = try receiver.receive(io, &data_buf);

    try out.print("got {d} bytes: \"{s}\"\n", .{ msg.data.len, msg.data });

    // Each datagram is one unit: this second message cannot merge with
    // the first, unlike bytes on a TCP stream.
    try sender.send(io, &receiver.address, "reading: 21.6C");
    const second = try receiver.receive(io, &data_buf);
    try out.print("got {d} bytes: \"{s}\"\n", .{ second.data.len, second.data });

    try out.flush();
}
