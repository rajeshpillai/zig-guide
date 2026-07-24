//! title: A Redis RESP Round Trip
//! native
//! A tiny RESP server and client in one process: SET and GET over the wire.

const std = @import("std");

// A RESP command is an array of bulk strings: `*<n>\r\n` then, per argument,
// `$<len>\r\n<bytes>\r\n`. That is exactly what a real redis-server accepts.
fn sendCommand(w: *std.Io.Writer, args: []const []const u8) !void {
    try w.print("*{d}\r\n", .{args.len});
    for (args) |a| {
        try w.print("${d}\r\n", .{a.len});
        try w.writeAll(a);
        try w.writeAll("\r\n");
    }
    try w.flush();
}

// takeDelimiterInclusive consumes the '\n' (the Exclusive form leaves it in the
// stream); trimming drops the trailing "\r\n" a RESP line ends with.
fn line(r: *std.Io.Reader) ![]const u8 {
    return std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
}

// --- server: a one-connection key-value store speaking RESP ---

const Store = std.StringHashMapUnmanaged([]const u8);

fn serve(server: *std.Io.net.Server, io: std.Io) void {
    serveImpl(server, io) catch {};
}

fn serveImpl(server: *std.Io.net.Server, io: std.Io) !void {
    var conn = try server.accept(io);
    defer conn.close(io);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store: Store = .empty;

    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var reader = conn.reader(io, &rbuf);
    var writer = conn.writer(io, &wbuf);
    const r = &reader.interface;
    const w = &writer.interface;

    while (true) {
        // Parse one command array. A clean EOF ends the loop.
        const header = line(r) catch break;
        if (header.len == 0 or header[0] != '*') break;
        const n = try std.fmt.parseInt(usize, header[1..], 10);

        var argv: std.ArrayList([]const u8) = .empty;
        for (0..n) |_| {
            const len_line = try line(r);
            const len = try std.fmt.parseInt(usize, len_line[1..], 10);
            const data = try a.alloc(u8, len);
            try r.readSliceAll(data);
            try r.discardAll(2); // trailing \r\n
            try argv.append(a, data);
        }
        if (argv.items.len == 0) continue;

        const cmd = argv.items[0];
        if (std.ascii.eqlIgnoreCase(cmd, "SET") and argv.items.len == 3) {
            try store.put(a, try a.dupe(u8, argv.items[1]), try a.dupe(u8, argv.items[2]));
            try w.writeAll("+OK\r\n");
        } else if (std.ascii.eqlIgnoreCase(cmd, "GET") and argv.items.len == 2) {
            if (store.get(argv.items[1])) |val| {
                try w.print("${d}\r\n", .{val.len});
                try w.writeAll(val);
                try w.writeAll("\r\n");
            } else {
                try w.writeAll("$-1\r\n"); // RESP nil
            }
        } else if (std.ascii.eqlIgnoreCase(cmd, "QUIT")) {
            try w.writeAll("+OK\r\n");
            try w.flush();
            break;
        } else {
            try w.writeAll("-ERR unknown command\r\n");
        }
        try w.flush();
    }
}

// --- client: send a command, decode the one-line RESP reply ---

fn printReply(r: *std.Io.Reader, out: *std.Io.Writer) !void {
    const l = try line(r);
    switch (l[0]) {
        '+' => try out.print("  simple: {s}\n", .{l[1..]}),
        '-' => try out.print("  error:  {s}\n", .{l[1..]}),
        ':' => try out.print("  int:    {s}\n", .{l[1..]}),
        '$' => {
            const len = try std.fmt.parseInt(isize, l[1..], 10);
            if (len < 0) {
                try out.writeAll("  bulk:   (nil)\n");
            } else {
                var buf: [256]u8 = undefined;
                const data = buf[0..@intCast(len)];
                try r.readSliceAll(data);
                try r.discardAll(2);
                try out.print("  bulk:   \"{s}\"\n", .{data});
            }
        },
        else => try out.print("  ?       {s}\n", .{l}),
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // Stand up the toy server on an OS-chosen port, then talk to it.
    const any_port = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try any_port.listen(io, .{});
    defer server.deinit(io);
    const thread = try std.Thread.spawn(.{}, serve, .{ &server, io });

    var stream = try server.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    const r = &reader.interface;
    const w = &writer.interface;

    try out.writeAll("> SET framework zig\n");
    try sendCommand(w, &.{ "SET", "framework", "zig" });
    try printReply(r, out);

    try out.writeAll("> GET framework\n");
    try sendCommand(w, &.{ "GET", "framework" });
    try printReply(r, out);

    try out.writeAll("> GET missing\n");
    try sendCommand(w, &.{ "GET", "missing" });
    try printReply(r, out);

    try out.writeAll("> QUIT\n");
    try sendCommand(w, &.{"QUIT"});
    try printReply(r, out);

    thread.join();
    try out.flush();
}
