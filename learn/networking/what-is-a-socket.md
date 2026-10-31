# What a Socket Is

> An address, a mode, and a handle that you read and write like a file.

A socket is a [file descriptor](https://www.ziglang.in/learn/os/file-descriptors/) with an address.
That is almost the full definition. When two sockets have a connection, all the
work uses the reader and writer interface from [Readers and
Writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/). A file uses the same
interface.

```zig
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
```

*CI builds and runs this snippet natively, and binds a real loopback socket. Browser wasm has no sockets. (`11-networking.what-is-a-socket`)*

## An address is data

`IpAddress.parse` does not use the network. It opens nothing and sends
nothing. It fails only if the text is not an address. No network action
occurs until you call `listen`, `bind` or `connect`.

```zig
const wanted = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
```

## Port 0 tells the kernel to select a port

If you ask for port 0, the kernel gives the socket a free port when it binds
the socket. The socket records the port in `server.socket.address`.

A test that uses a fixed port such as 8080 can fail in three conditions:

- Two copies of the test run at the same time.
- The server from the last run is still active.
- A different program on the computer already uses port 8080.

Each snippet in this section binds port 0 and reads the port that it gets.
Thus all of the snippets can run on the same CI computer at the same time.

## Stream or datagram

```zig
var client = try bound.connect(io, .{ .mode = .stream });
```

`.stream` is TCP. TCP keeps the bytes in order, is reliable, and uses a
connection. `.dgram` is UDP,
and UDP has none of these three properties.
[UDP Datagrams](https://www.ziglang.in/learn/networking/udp-message/), at the end of this section,
gives more information about UDP. You select the mode one time, on the socket.
Each difference between the two protocols comes from that mode.

## After the connection, the code does not use sockets

```zig
var writer = client.writer(io, &write_buf);
try writer.interface.writeAll("ping\n");
try writer.interface.flush();
```

When the connection exists, no part of the code is specific to networks.
Thus five of the chapters between this chapter and the UDP chapter run in your
browser, without sockets. A protocol parser that uses `std.Io.Reader` works
on a socket, on a file and on a byte array in a test. You write the parser
one time only.

## You must close each socket

Each socket is a file descriptor, and each process has a limit on file
descriptors. If a server does not close one socket for each connection, the
server cannot accept new connections when it reaches that limit. This occurs a long time before the server has no
more memory. The symptom is an error from `accept`, and the error does not
tell you about the leak. Put a `defer` immediately after the line that makes
the socket. Then the program always closes the socket.

Next: [A TCP Round Trip](https://www.ziglang.in/learn/networking/tcp-echo/). That chapter adds an
accept loop to this program.
