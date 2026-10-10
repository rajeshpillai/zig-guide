# UDP Datagrams

> Bound sockets and discrete messages, no connection anywhere.

In Zig, a UDP socket comes from `std.Io.net.IpAddress.bind` with `.mode
= .dgram`, and there is no `listen` or `accept`. Each `send` names its
destination, and each `receive` returns the data along with the sender's
address.

## The problem

Some traffic does not want a connection: metrics, discovery pings, game
state, sensor readings. Losing one message is fine. Paying for TCP's ordering and retransmission is
not. That is UDP, and its API shape is
different enough from TCP that the "listen and accept" model does not carry
over.

There is nothing to accept. A socket binds to an address, and messages
arrive whenever they arrive.

## The plan

1. `bind` with `.mode = .dgram` instead of `listen`. Binding to port 0
   picks an ephemeral port, recorded on `socket.address`.
2. Send with `socket.send(io, &destination, bytes)`: destination per
   message, because there is no connection to remember it.
3. Receive with `socket.receive(io, &buffer)`, which returns the data
   slice and the sender's address.
4. Reply by sending to that address. There is no connection to answer
   on, so the reply is just another `send`.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // A datagram socket binds instead of listening. There is no connection
    // to accept, only an address that can receive messages.
    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const receiver = try any_port.bind(io, .{ .mode = .dgram });
    defer receiver.close(io);

    const sender = try any_port.bind(io, .{ .mode = .dgram });
    defer sender.close(io);

    // Send first, receive second, one thread. The kernel holds the
    // datagram until someone asks for it, so sending and receiving are
    // independent steps.
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

    // The message carries the sender's address in `second.from`. Sending
    // back to it is a reply, with no accept and no connection. The address
    // in the packet is all the receiver knows about the sender, and it is
    // all the receiver needs.
    var upper_buf: [256]u8 = undefined;
    const reply = std.ascii.upperString(&upper_buf, second.data);
    try receiver.send(io, &second.from, reply);

    var reply_buf: [256]u8 = undefined;
    const answer = try sender.receive(io, &reply_buf);
    try out.print("reply: \"{s}\"\n", .{answer.data});

    try out.flush();
}
```

*Built and run natively by CI, sending real datagrams over loopback. Browser wasm has no sockets. (`11-networking.udp-message`)*

## No threads in this one, and why that works

The snippet sends a message, reads it, sends another, and reads that, all on
one thread. Nothing has to be waiting when a datagram arrives, because the
kernel queues datagrams on the bound socket until someone reads them.
This is how UDP works: the sender and receiver never meet. They only share
an address. (The queue is finite; when it
overflows, datagrams are dropped, which is UDP behaving as documented.)

## Message boundaries are real

Two `send` calls produced exactly two `receive` results, 14 bytes each.
TCP could deliver those 28 bytes as one read or three; a datagram
socket never merges or splits messages. Protocol designers choose UDP for this property. It comes with a matching
limit: a
datagram larger than the receive buffer is truncated, signalled by
`msg.flags.trunc`.

## Replying without a connection

The last step uppercases the message and sends it back. Look at what it
does not need. With TCP, a server that wants to answer must `accept` and
hold a socket for that client. Here the receiver knows one thing about
the sender: the address in `second.from`. It sends to that address and is
done.

Receiving and then sending back is all that request/response over UDP
needs. DNS works this way: one datagram asks, one datagram answers,
and no connection ever exists.

## Variations

- **Timeouts:** `receiveTimeout` returns `error.Timeout` instead of
  blocking forever, which is how you write "wait up to a second for a
  reply".
- **Broadcast:** set `.allow_broadcast = true` in the bind options to
  send to broadcast addresses on a LAN.
