# What a Socket Is

> An address, a mode, and a handle you read and write like a file.

A socket is a [file descriptor](https://www.ziglang.in/learn/os/file-descriptors/) with an address
attached. That is nearly the whole of it. Once two of them are connected,
everything you do is the reader and writer interface from [Readers and
Writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/), the same one a file
uses.

```zig
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
```

*Built and run natively by CI, binding a real loopback socket. Browser wasm has no sockets. (`11-networking.what-is-a-socket`)*

## An address is data

`IpAddress.parse` touches no network. It opens nothing, sends nothing, and
fails only if the text is not an address. Nothing happens until you `listen`,
`bind` or `connect`.

```zig
const wanted = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
```

## Port 0 means "you pick"

Ask for port 0 and the kernel assigns a free one when the socket is bound. The
socket records which one it got, at `server.socket.address`.

This matters more than it looks. A test that hardcodes port 8080 fails three
ways. It fails when two of them run at once. It fails when you left the last
run's server up. And it fails on a machine where something else already has
8080. Every snippet in this section binds port 0 and reads back what it was
given. That is why they can all run on the same CI machine at the same time.

## Stream or datagram

```zig
var client = try bound.connect(io, .{ .mode = .stream });
```

`.stream` is TCP: ordered, reliable, and connected. `.dgram` is UDP and gives
you none of those three, which [UDP Datagrams](https://www.ziglang.in/learn/networking/udp-message/)
covers at the end of this section. The mode is chosen once, at the socket, and
every difference between the two protocols follows from it.

## Then it stops being a socket

```zig
var writer = client.writer(io, &write_buf);
try writer.interface.writeAll("ping\n");
try writer.interface.flush();
```

After the connection exists, nothing in the code is network-shaped. That is
not a convenience: it is the reason the six chapters between here and UDP can
run in your browser with no sockets at all. A protocol parser written against
`std.Io.Reader` works over a socket, over a file, and over a byte array in a
test, and you never write it twice.

## Closing is yours to do

Every socket is a file descriptor, and processes have a limit on those. A
server that leaks one per connection stops accepting new ones long before it
runs out of memory. The symptom is an error on `accept` rather than anything
pointing at the leak. `defer` at the point of creation is how you never have
to think about it again.

Next: [A TCP Round Trip](https://www.ziglang.in/learn/networking/tcp-echo/), which is this plus an
accept loop.
