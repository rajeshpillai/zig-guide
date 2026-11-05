# A TCP Round Trip

> Listen, connect, and echo through std.Io.net, all in one process.

In current Zig, a TCP server uses three calls:
`std.Io.net.IpAddress.parse`, then `address.listen(io, .{})`, then
`server.accept(io)`. A TCP client uses `addr.connect(io, .{ .mode = .stream })`.
The reader of a connected stream is the same `std.Io.Reader` that you use for
files.

## The problem

You want a TCP server and a client that talks to the server, in Zig, with the
current API. Old tutorials cause many problems on this topic. The network
code moved from `std.net` to `std.Io.net`, and each operation now takes the
`Io` instance. If you copy code from a guide of last year, the compiler
rejects the code.

The recipe runs the two halves in one process. You can use the same method
for an integration test of any protocol code.

## The plan

1. Parse `127.0.0.1` with **port 0**, and call `listen`. Port 0 tells the OS
   to select a free ephemeral port. `server.socket.address` holds the port
   that the OS selected. Thus no code uses a fixed port that another program
   can already use.
2. Start a thread for the server half. The thread calls `accept`, reads a
   line and sends a reply.
3. In the main thread, `connect` to the recorded address. Send a line and
   read the reply.
4. Join the thread. CI runs exactly this program and compares the output.

```zig
const std = @import("std");

// The server half: accept one client, read one line, and send the line
// back in uppercase. A real server runs this code one time per connection.
fn serve(server: *std.Io.net.Server, io: std.Io) void {
    var conn = server.accept(io) catch return;
    defer conn.close(io);

    var read_buf: [256]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch return;

    var upper_buf: [256]u8 = undefined;
    const upper = std.ascii.upperString(&upper_buf, line);

    var write_buf: [256]u8 = undefined;
    var writer = conn.writer(io, &write_buf);
    writer.interface.print("{s}\n", .{upper}) catch return;
    writer.interface.flush() catch return;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // Port 0 asks the OS for a free port. The socket records the port that
    // it got. Thus no code here uses a fixed port that is possibly in use.
    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try any_port.listen(io, .{});
    defer server.deinit(io);
    const addr = server.socket.address;

    const thread = try std.Thread.spawn(.{}, serve, .{ &server, io });

    // The client half. After this point, all code uses the reader and
    // writer interface. A socket stream and a file operate the same way.
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("hello over tcp\n");
    try writer.interface.flush();

    var read_buf: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const reply = try reader.interface.takeDelimiterExclusive('\n');

    try out.print("sent:     hello over tcp\n", .{});
    try out.print("received: {s}\n", .{reply});

    thread.join();
    try out.flush();
}
```

*CI builds and runs this snippet natively, and sends real bytes over loopback. Browser wasm has no sockets. (`11-networking.tcp-echo`)*

## What changed from std.net

If you learned to write network code in Zig before the change to `std.Io`, use
this table:

| Then | Now |
| --- | --- |
| `std.net.Address.parseIp(...)` | `std.Io.net.IpAddress.parse(...)` |
| `address.listen(.{})` | `address.listen(io, .{})` |
| `listener.accept()` | `server.accept(io)` |
| `std.net.tcpConnectToAddress(addr)` | `addr.connect(io, .{ .mode = .stream })` |
| `stream.reader()` / `.writer()` | `stream.reader(io, &buf)` / `.writer(io, &buf)`, then `.interface` |

All rows follow one rule. Each operation that can block uses the `io` parameter,
and you must supply the buffers.

## One interface for sockets and files

`stream.reader(io, &buf).interface` is the same `std.Io.Reader` that you use
for files and stdin. Thus `takeDelimiterExclusive('\n')` reads a line from a
socket in the same way as from a file. Protocol code that uses the interface
does not know that a socket is below it. For this reason, you can test the
protocol code with `std.Io.Reader.fixed` in unit tests.

## Why a thread

`accept` blocks until a client connects, and `connect` blocks until the
server accepts. Thus one thread cannot do the two halves together, unless it
uses details of the connection queue in the kernel. A second thread lets each
half run as straight-line code. On the wasm target, this code does not
compile, because wasm has no sockets and no threads. For this reason, CI runs
this snippet natively.

## Variations

- **Many clients:** put the accept-and-serve body in a loop and start one
  thread for each connection. Or give the accepted streams to a
  [worker queue](https://www.ziglang.in/learn/how-to/worker-queue/).
- **Timeouts:** `connect` takes an `Io.Timeout` in its options. Reads can use
  `receiveTimeout` at the socket level.
- **Structured protocols:** for binary data, length-prefixed frames are better
  than lines of text. See [the wire format recipe](https://www.ziglang.in/learn/how-to/binary-roundtrip/).
