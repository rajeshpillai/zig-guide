# UDP Datagrams

> Bound sockets and discrete messages, without a connection.

In Zig, a UDP socket comes from `std.Io.net.IpAddress.bind` with `.mode
= .dgram`. There is no `listen` and no `accept`. Each `send` names its
destination. Each `receive` returns the data and the address of the sender.

## The problem

Some traffic does not need a connection: metrics, discovery pings, game
state and sensor readings. The loss of one message is acceptable. The cost of
the ordering and retransmission in TCP is not acceptable. For this traffic,
use UDP. The API of UDP is very different from TCP, thus the "listen and
accept" model does not apply.

There is nothing to accept. A socket binds to an address, and messages arrive
at any time.

## The plan

1. Call `bind` with `.mode = .dgram`, not `listen`. If you bind to port 0,
   the OS selects an ephemeral port and records it in `socket.address`.
2. Send with `socket.send(io, &destination, bytes)`. Each message has a
   destination, because there is no connection to remember the destination.
3. Receive with `socket.receive(io, &buffer)`. This function returns the data
   slice and the address of the sender.
4. To reply, send to that address. There is no connection for the answer,
   thus the reply is only one more `send`.

```zig
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
```

*CI builds and runs this snippet natively, and sends real datagrams over loopback. Browser wasm has no sockets. (`11-networking.udp-message`)*

## Why this program needs no threads

The snippet sends a message and reads it. Then it sends one more message and
reads that message. All of this occurs on one thread. No code must wait when
a datagram arrives, because the kernel keeps the datagrams on the bound
socket until a program reads them.

UDP works in this way: the sender and the
receiver never meet. They only share an address. (The queue has a limit.
When the queue is full, the kernel drops datagrams, and UDP permits that.)

## Message boundaries are real

Two `send` calls gave exactly two `receive` results, of 14 bytes each. TCP
can deliver those 28 bytes as one read or as three reads. A datagram socket
never merges or splits messages. Protocol designers select UDP for this
property. The property comes with a limit: if a datagram is larger than the
receive buffer, the kernel truncates the datagram. `msg.flags.trunc` shows
the truncation.

## Reply without a connection

The last step changes the message to uppercase and sends it back. Look at
what this step does not need. In TCP, a server that sends an answer must
`accept` and keep a socket for that client. Here, the receiver knows one
thing about the sender: the address in `second.from`. The receiver sends to
that address, and then its work is complete.

Request and response over UDP need only a receive and then a send. DNS works
in this way: one datagram asks, one datagram answers, and no connection ever
exists.

## Variations

- **Timeouts:** `receiveTimeout` returns `error.Timeout` and does not block
  forever. Use it to wait a maximum of one second for a reply.
- **Broadcast:** to send to broadcast addresses on a LAN, set
  `.allow_broadcast = true` in the bind options.
