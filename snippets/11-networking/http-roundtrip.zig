//! title: An HTTP Round Trip
//! native
//! std.http.Server on a thread, and std.http.Client fetches from it.

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
