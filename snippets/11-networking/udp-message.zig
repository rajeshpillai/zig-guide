//! title: UDP Datagrams
//! native
//! Connectionless messages: two bound sockets, and no threads.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // A datagram socket binds, and does not listen. There is no connection
    // to accept. There is only an address that can receive messages.
    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const receiver = try any_port.bind(io, .{ .mode = .dgram });
    defer receiver.close(io);

    const sender = try any_port.bind(io, .{ .mode = .dgram });
    defer sender.close(io);

    // Send first, receive second, on one thread. The kernel keeps the
    // datagram until a program asks for it. Thus the send and the receive
    // are independent steps.
    // `receiver.address` holds the ephemeral port that the OS selected.
    try sender.send(io, &receiver.address, "reading: 21.4C");

    var data_buf: [256]u8 = undefined;
    const msg = try receiver.receive(io, &data_buf);

    try out.print("got {d} bytes: \"{s}\"\n", .{ msg.data.len, msg.data });

    // Each datagram is one unit. This second message cannot merge with the
    // first message. Bytes on a TCP stream can merge.
    try sender.send(io, &receiver.address, "reading: 21.6C");
    const second = try receiver.receive(io, &data_buf);
    try out.print("got {d} bytes: \"{s}\"\n", .{ second.data.len, second.data });

    // The message holds the address of the sender in `second.from`. A send
    // to that address is a reply, with no accept and no connection. The
    // receiver knows only the address in the packet about the sender. The
    // receiver needs no more data.
    var upper_buf: [256]u8 = undefined;
    const reply = std.ascii.upperString(&upper_buf, second.data);
    try receiver.send(io, &second.from, reply);

    var reply_buf: [256]u8 = undefined;
    const answer = try sender.receive(io, &reply_buf);
    try out.print("reply: \"{s}\"\n", .{answer.data});

    try out.flush();
}
