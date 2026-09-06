# An HTTP Round Trip

> A std.http.Server on a thread, a std.http.Client fetching from it, no dependencies.

## The problem

You want to make an HTTP request from Zig, or handle one, using only the
standard library. Both halves exist in `std.http`, both were rebuilt on the
`std.Io` reader/writer interfaces, and most tutorial code for either predates
the rebuild.

As with [TCP](https://www.ziglang.in/learn/networking/tcp-echo/), the recipe runs server and client
in one process. CI executes it and diffs the output, so the page cannot
quietly rot.

## The plan

1. Listen on an ephemeral TCP port, exactly as in the TCP recipe. HTTP is
   a layer, not a different kind of socket.
2. On the server thread, wrap the accepted stream's reader and writer in
   `std.http.Server.init`, then loop: `receiveHead()` gives a request,
   route on `request.head.target`, answer with `respond()`.
3. On the client side, create a `std.http.Client` and call `fetch()` with
   a URL and a `response_writer`. One call drives connect, request,
   redirect handling, and body delivery.

```zig
const std = @import("std");

// One connection's lifecycle: HTTP is layered over the plain TCP stream
// by giving std.http.Server the stream's reader and writer interfaces.
fn serve(listener: *std.Io.net.Server, io: std.Io) void {
    var conn = listener.accept(io) catch return;
    defer conn.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    var writer = conn.writer(io, &write_buf);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    // Keep-alive means several requests can arrive on this connection;
    // the loop ends when the client is done and the stream closes.
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

    // Same bootstrap as the TCP recipe: port 0, OS picks, socket records.
    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try any_port.listen(io, .{});
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    const thread = try std.Thread.spawn(.{}, serve, .{ &listener, io });
    defer thread.join();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // fetch() drives the whole request: connect, send, follow the
    // response, decompress if needed. The body lands in any writer you
    // hand it; Allocating collects it into memory.
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

    // Second request reuses the pooled keep-alive connection.
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

*Built and run natively by CI: a real client fetches from a real server over loopback. Browser wasm has no sockets. (`11-networking.http-roundtrip`)*

## The layering is literal

`std.http.Server.init(&reader.interface, &writer.interface)` takes the same
two interfaces every stream in current Zig exposes. The HTTP layer never sees
the socket; hand it a pipe or a fixed buffer and it works the same, which is
how the standard library tests itself. If you understand the TCP recipe, the
only new machinery here is head parsing and response formatting, and both
belong to `std.http`.

The server loop also explains keep-alive concretely: both fetches in the
snippet arrive over one TCP connection, as two iterations of the `receiveHead`
loop. The loop exits when the client's connection pool closes the stream.

## What fetch does for you

`fetch` is the one-shot path. It parses the URL, takes a pooled connection or
opens one, sends the request, follows redirects (up to three by default for
GET), decompresses the body if needed, and writes the body into the writer you
supply. The result carries the status code. For streaming bodies, per-request
headers, or long-lived requests, drop down to `client.request()`; the shape is
the same, spelled out.

## Status is data, not an error

The 404 comes back as `FetchResult.status`, not as a Zig error. Errors are for
the transport failing (refused connection, malformed response); whether a 404
is a failure is your application's decision. Route on the status enum: `.ok`,
`.not_found`, or the numeric value via `@intFromEnum`.

## Variations

- **POST:** set `.payload = body` in the fetch options; the method
  defaults to POST when a payload is present.
- **Serving files:** pair the router with
  [Filesystem](https://www.ziglang.in/learn/standard-library/filesystem/) reads; `respond` takes any
  byte slice.
- **HTTPS:** `fetch` handles `https://` URLs with the bundled TLS client;
  nothing changes at the call site.
