# Recipe: A Redis RESP Round Trip

> Use the RESP protocol of Redis over a socket, with a small server and client in one process.

A Redis command in RESP is `*` and the argument count. Then each argument follows as `$`, its byte length and its bytes. Each line ends in `\r\n`. A Zig program can write and parse that format directly, with no client library.

## The problem

Redis uses RESP, a small text protocol over TCP. You do not need a client library to communicate with Redis. A command is an array of strings, each with its length before it. A reply is one line with a tag.

This recipe implements a small part of both ends, sufficient to run `SET` and `GET`. Thus you can see the exact bytes that go over the wire.

The recipe does not depend on a `redis-server` that runs. It runs a small RESP server in the same process, as [the TCP recipe](https://www.ziglang.in/learn/networking/tcp-echo/) does. CI runs the full exchange and compares the output. Thus CI verifies the protocol code, but no external database is necessary.

## The plan

1. Encode a command as RESP. Write `*<n>` for the argument count. Then, for each argument, write `$<len>` and the bytes. End each line with `\r\n`.
2. On the server, parse that array. Send `SET` and `GET` to a `StringHashMap`, and reply in RESP.
3. On the client, send a command. Decode the one-line reply by its first byte: `+` simple string, `-` error, `:` integer, `$` bulk string.

```zig
const std = @import("std");

// A RESP command is an array of bulk strings: `*<n>\r\n`, then
// `$<len>\r\n<bytes>\r\n` for each argument. A real redis-server accepts
// exactly this format.
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
// stream). The trim removes the "\r\n" at the end of each RESP line.
fn line(r: *std.Io.Reader) ![]const u8 {
    return std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
}

// --- server: a key-value store for one connection, with RESP ---

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
        // Parse one command array. A clean EOF stops the loop.
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

// --- client: send a command, and decode the one-line RESP reply ---

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

    // Start the small server on a port that the OS selects. Then connect to it.
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
```

*A RESP server and client in one program, with no other parts. CI builds and runs it natively. It needs no redis-server, and browser wasm has no sockets. (`06-cookbook.redis-resp`)*

## The wire format

`SET framework zig` goes out as `*3\r\n$3\r\nSET\r\n$9\r\nframework\r\n$3\r\nzig\r\n`. A RESP command contains only these parts: a count, then each argument as a byte length and the bytes.

The length is explicit. Thus the parser never has to guess where a value ends. A value can contain any byte, `\r\n` too.

Replies are more simple. One byte at the start gives the type. Thus `+OK\r\n` is success, and `$3\r\nzig\r\n` is the three-byte string `zig`. A key that does not exist gives the RESP nil, `$-1\r\n`, and the client prints it as `(nil)`.

## Read lines: be careful with the delimiter

The reader helper uses `takeDelimiterInclusive('\n')` and removes the `\r\n` at the end. This is intentional.

The exclusive variant returns the line without the terminator, but it leaves that terminator in the stream. In a loop that reads one line after the other with that variant, each later call reads an empty string.

The `Inclusive` form consumes the delimiter. You want that behavior when you parse a stream of lines that end in `\r\n`.

For a bulk string, the code does not read a line. It reads exactly the number of bytes that the length gives. Then it discards the two framing bytes at the end.

## Use a real Redis

To use a real server, replace the listener in the process with a connection to `127.0.0.1:6379`. Connect exactly as [the TCP recipe](https://www.ziglang.in/learn/networking/tcp-echo/) does.

The encoder and the decoder here use real RESP. Thus the same `sendCommand` and reply parser work with `redis-server` without a change. The parser handles the four reply types that most commands return. For commands such as `KEYS` or `HGETALL`, add the array case (`*`).

## Variations

- **Pipelining:** send several commands before you read the replies. RESP allows this, and it decreases the number of round trips. The replies come in the same order as the commands.
- **Binary values:** bulk strings have their length before them. Thus you can store raw bytes without escape characters.
- **A persistent store:** for a database that keeps data on disk from Zig, see [SQLite from Zig](https://www.ziglang.in/learn/how-to/databases/sqlite-basic/).
