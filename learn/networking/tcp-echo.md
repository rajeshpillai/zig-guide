# A TCP Round Trip

> Listen, connect, and echo through std.Io.net, all in one process.

## The problem

You want a TCP server and a client talking to it, in Zig, with today's API.
This is the topic where stale tutorials hurt the most. Networking moved from
`std.net` to `std.Io.net`, and every operation now takes the `Io` instance.
Code copied from a last-year guide does not get past the compiler.

The recipe runs both halves in one process. That is not a toy compromise; it
is also how you write an integration test for any protocol code.

## The plan

1. Parse `127.0.0.1` with **port 0**, and `listen`. Port 0 tells the OS
   to pick a free ephemeral port; `server.socket.address` carries the
   resolved one, so nothing hardcodes a port that might be taken.
2. Spawn a thread for the server half: `accept`, read a line, reply.
3. In the main thread, `connect` to the recorded address, send a line,
   read the reply.
4. Join the thread. CI runs exactly this and diffs the output.

```zig
const std = @import("std");

// The server half: accept one client, read one line, echo it uppercased.
// In a real server this loop would run per connection; the shape is the same.
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

    // Port 0 asks the OS for any free port; the socket records which one
    // it got, so nothing here hardcodes a port that might be taken.
    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try any_port.listen(io, .{});
    defer server.deinit(io);
    const addr = server.socket.address;

    const thread = try std.Thread.spawn(.{}, serve, .{ &server, io });

    // The client half. Everything is the reader/writer interface from
    // here on; a socket stream and a file behave the same way.
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

*Built and run natively by CI, exchanging real bytes over loopback. Browser wasm has no sockets. (`11-networking.tcp-echo`)*

## What changed from std.net

If you learned Zig networking before the `std.Io` rework, the map is:

| Then | Now |
| --- | --- |
| `std.net.Address.parseIp(...)` | `std.Io.net.IpAddress.parse(...)` |
| `address.listen(.{})` | `address.listen(io, .{})` |
| `listener.accept()` | `server.accept(io)` |
| `std.net.tcpConnectToAddress(addr)` | `addr.connect(io, .{ .mode = .stream })` |
| `stream.reader()` / `.writer()` | `stream.reader(io, &buf)` / `.writer(io, &buf)`, then `.interface` |

The pattern behind every row: blocking operations go through the `io`
parameter, and buffers are yours to supply.

## One interface for sockets and files

`stream.reader(io, &buf).interface` is the same `std.Io.Reader` you use for
files and stdin, so `takeDelimiterExclusive('\n')` reads a line off a socket
exactly as it would off a file. Protocol code written against the interface
does not know or care that a socket is underneath, which is what makes it
testable with `std.Io.Reader.fixed` in unit tests.

## Why a thread

`accept` blocks until a client arrives, and `connect` blocks until the server
accepts, so one thread cannot do both halves interleaved without relying on
kernel queue subtleties. A second thread keeps each half straight-line. On the
wasm target none of this compiles (no sockets, no threads), which is why CI
runs this snippet natively.

## Variations

- **Many clients:** wrap the accept-and-serve body in a loop and spawn a
  thread per connection, or feed accepted streams to a
  [worker queue](https://www.ziglang.in/learn/how-to/worker-queue/).
- **Timeouts:** `connect` takes an `Io.Timeout` in its options; reads can
  use `receiveTimeout` on the socket level.
- **Structured protocols:** length-prefixed frames beat line-delimited
  text for binary data; see [the wire format recipe](https://www.ziglang.in/learn/how-to/binary-roundtrip/).
