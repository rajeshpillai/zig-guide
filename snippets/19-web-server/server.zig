//! title: An HTTP Server
//! native
//! The parser from the last chapter, with a socket in front of it.
//!
//! The snippet is native because it binds a listening socket, and the browser
//! sandbox has no sockets. CI builds the snippet and runs it on the host. The
//! snippet serves a real request over a real port, and CI compares what the
//! client received. Thus the verification is the same without a Run button.

const std = @import("std");
const http = @import("request.zig");

/// Serve exactly one connection, then return. A real server puts this function
/// in a loop, and gives each connection to a thread or to an event loop. The
/// work for each connection does not change.
fn serve(server: *std.Io.net.Server, io: std.Io) void {
    var conn = server.accept(io) catch return;
    defer conn.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buf);

    // Read until the blank line. HTTP does not give a length at the start.
    // Thus the server cannot know how much to read. The server reads until it
    // finds the end of the header section. After that, Content-Length gives
    // the size of a body.
    var raw: [4096]u8 = undefined;
    var used: usize = 0;
    while (std.mem.find(u8, raw[0..used], "\r\n\r\n") == null) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch break;
        if (used + line.len > raw.len) break;
        @memcpy(raw[used..][0..line.len], line);
        used += line.len;
    }

    var storage: [16][2][]const u8 = undefined;
    const request = http.parse(raw[0..used], &storage) catch {
        respond(&conn, io, 400, "text/plain", "bad request\n");
        return;
    };

    if (std.mem.eql(u8, request.target, "/")) {
        respond(&conn, io, 200, "text/html", "<h1>hello</h1>\n");
    } else {
        respond(&conn, io, 404, "text/plain", "not found\n");
    }
}

/// A response is a status line, headers, a blank line, and the body. The
/// Content-Length is necessary. Without it, the client cannot know that the
/// body ended, and the client waits.
fn respond(conn: *std.Io.net.Stream, io: std.Io, status: u16, content_type: []const u8, body: []const u8) void {
    var buf: [1024]u8 = undefined;
    var writer = conn.writer(io, &buf);
    const w = &writer.interface;

    const reason: []const u8 = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        else => "Not Found",
    };

    w.print("HTTP/1.1 {d} {s}\r\n", .{ status, reason }) catch return;
    w.print("Content-Type: {s}\r\n", .{content_type}) catch return;
    w.print("Content-Length: {d}\r\n", .{body.len}) catch return;
    w.writeAll("Connection: close\r\n\r\n") catch return;
    w.writeAll(body) catch return;
    w.flush() catch return;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // Port 0 asks the OS for a free port. Thus the server cannot use the same
    // port as a different program on the machine.
    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try any_port.listen(io, .{});
    defer server.deinit(io);
    const addr = server.socket.address;

    for ([_][]const u8{ "/", "/nope" }) |target| {
        const thread = try std.Thread.spawn(.{}, serve, .{ &server, io });

        var stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var write_buf: [512]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.print(
            "GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
            .{target},
        );
        try writer.interface.flush();

        var read_buf: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);

        // Read until the peer closes the connection. Do not read line by line.
        // The server sent `Connection: close`, thus the end of the stream is
        // the end of the response. Only this framing rule needs no header.
        var response: [2048]u8 = undefined;
        var got: usize = 0;
        while (true) {
            const n = reader.interface.readSliceShort(response[got..]) catch break;
            if (n == 0) break;
            got += n;
        }

        try out.print("--- GET {s}\n", .{target});
        var lines = std.mem.splitSequence(u8, response[0..got], "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try out.print("{s}\n", .{line});
        }

        thread.join();
    }

    try out.flush();
}
