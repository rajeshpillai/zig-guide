# An HTTP Round Trip

> A std.http.Server on a thread, and a std.http.Client that fetches from it, with no dependencies.

The Zig standard library has the two halves of HTTP, with no dependencies:

- `std.http.Server` answers requests over any reader and writer.
- `std.http.Client.fetch` makes a request in one call.

The two halves use the `std.Io` reader and writer interfaces.

## The problem

Zig rebuilt the two halves on the `std.Io` interfaces. Most of the example
code that you can find for each half is older than that change.

As in [TCP](https://www.ziglang.in/learn/networking/tcp-echo/), the recipe runs the server and the
client in one process. CI runs the recipe and compares the output. Thus, if
the page becomes out of date, CI fails.

## The plan

1. Listen on an ephemeral TCP port, as in the TCP recipe. HTTP is a layer on
   a TCP socket. HTTP does not need a different type of socket.
2. On the server thread, give the reader and writer of the accepted stream to
   `std.http.Server.init`. Then use a loop: `receiveHead()` gives a request,
   `request.head.target` selects the route, and `respond()` sends the answer.
3. On the client side, make a `std.http.Client`. Call `fetch()` with a URL
   and a `response_writer`. One call does the connect, the request, the
   redirects and the delivery of the body.

```zig
const std = @import("std");

// The life of one connection. HTTP is a layer on the plain TCP stream. To
// make the layer, give the reader and writer of the stream to std.http.Server.
fn serve(listener: *std.Io.net.Server, io: std.Io) void {
    var conn = listener.accept(io) catch return;
    defer conn.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    var writer = conn.writer(io, &write_buf);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    // With keep-alive, many requests can arrive on this connection. The
    // loop ends when the client completes its work and the stream closes.
    while (true) {
        var request = http_server.receiveHead() catch return;
        if (std.mem.eql(u8, request.head.target, "/hello")) {
            request.respond("hello from zig\n", .{}) catch return;
        } else {
            request.respond("no such page\n", .{
                .status = .not_found,
            }) catch return;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.page_allocator;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // The same setup as the TCP recipe: port 0, the OS selects a port, and
    // the socket records the port.
    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try any_port.listen(io, .{});
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    const thread = try std.Thread.spawn(.{}, serve, .{ &listener, io });
    defer thread.join();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // fetch() does the full request: connect, send, follow the response,
    // and decompress if necessary. The body goes to the writer that you
    // give. `Allocating` collects the body into memory.
    var url_buf: [64]u8 = undefined;
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const ok = try client.fetch(.{
        .location = .{ .url = try std.mem.print(
            &url_buf,
            "http://127.0.0.1:{d}/hello",
            .{port},
        ) },
        .response_writer = &body.writer,
    });
    try out.print("GET /hello -> {d}\n", .{@intFromEnum(ok.status)});
    try out.print("body: {s}", .{body.written()});

    // The second request uses the same keep-alive connection from the pool.
    const missing = try client.fetch(.{
        .location = .{ .url = try std.mem.print(
            &url_buf,
            "http://127.0.0.1:{d}/nope",
            .{port},
        ) },
    });
    try out.print("GET /nope  -> {d}\n", .{@intFromEnum(missing.status)});

    try out.flush();
}
```

*CI builds and runs this snippet natively: a real client fetches from a real server over loopback. Browser wasm has no sockets. (`11-networking.http-roundtrip`)*

## The layers are real

`std.http.Server.init(&reader.interface, &writer.interface)` takes the same
two interfaces that each stream in current Zig has. The HTTP layer never sees
the socket. If you give it a pipe or a fixed buffer, it works in the same way.
The standard library tests it with a fixed buffer. If you know the TCP recipe,
only two parts are new: the parse of the head and the format of the response.
Both parts are in `std.http`.

The server loop also shows keep-alive. The two fetches in the snippet arrive
on one TCP connection, as two iterations of the `receiveHead` loop. The loop
ends when the connection pool of the client closes the stream.

## What fetch does for you

`fetch` is the one-call path. It does these steps:

1. It parses the URL.
2. It takes a connection from the pool, or it opens a connection.
3. It sends the request.
4. It follows redirects. For GET, the default maximum is three redirects.
5. If necessary, it decompresses the body.
6. It writes the body into the writer that you supply.

The result contains the status code. For streamed bodies, headers for each
request, or requests that stay open for a long time, use `client.request()`.
That function does the same steps, but you write each step in your code.

## Status is data, not an error

The 404 arrives as `FetchResult.status`, not as a Zig error. Errors are
for a failure of the transport, for example a refused connection or a
malformed response. Your application decides if a 404 is a failure. Use the
status enum to select the action: `.ok`, `.not_found`, or the numeric value
with `@intFromEnum`.

## Variations

- **POST:** set `.payload = body` in the fetch options. When a payload is
  present, the default method is POST.
- **Serve files:** use the router with reads from
  [Filesystem](https://www.ziglang.in/learn/standard-library/filesystem/). `respond` takes any byte
  slice.
- **HTTPS:** `fetch` handles `https://` URLs with the bundled TLS client. The
  call site does not change.
