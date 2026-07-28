//! title: A TCP Round Trip
//! native
//! Server and client in one process, on an ephemeral port the OS picks.

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
