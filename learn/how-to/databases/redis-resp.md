# Recipe: A Redis RESP Round Trip

> Speak Redis's RESP protocol over a socket, with a tiny server and client in one process.

## The problem

Redis speaks RESP, a small text protocol over TCP. You do not need a client
library to talk to it: a command is a length-prefixed array of strings, and a
reply is one tagged line. This recipe implements just enough of both ends to
run `SET` and `GET`, so you can see the exact bytes that go over the wire.

Rather than depend on a running `redis-server`, it stands up a toy RESP server
in the same process, the way [the TCP recipe](https://www.ziglang.in/learn/networking/tcp-echo/)
does. CI runs the whole exchange and diffs the output, so the protocol code is
verified even though there is no external database.

## The plan

1. Encode a command as RESP: `*<n>` for the argument count, then `$<len>` and
   the bytes for each argument, each line ending `\r\n`.
2. On the server, parse that array, dispatch `SET`/`GET` against a
   `StringHashMap`, and reply in RESP.
3. On the client, send a command and decode the one-line reply by its first
   byte: `+` simple string, `-` error, `:` integer, `$` bulk string.

```zig
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
```

*A self-contained RESP server and client, built and run natively by CI. It needs no redis-server, and browser wasm has no sockets. (`06-cookbook.redis-resp`)*

## The wire format is the whole protocol

`SET framework zig` goes out as
`*3\r\n$3\r\nSET\r\n$9\r\nframework\r\n$3\r\nzig\r\n`. That is all RESP is: a
count, then each argument as a byte length and the bytes. Because the length
is explicit, the parser never has to guess where a value ends, and a value may
contain any byte, including `\r\n`. Replies are simpler still: a single
leading byte names the type, so `+OK\r\n` is success and `$3\r\nzig\r\n` is
the three-byte string `zig`. A missing key is the RESP nil, `$-1\r\n`, which
the client prints as `(nil)`.

## Reading lines: mind the delimiter

The reader helper uses `takeDelimiterInclusive('\n')` and trims the trailing
`\r\n`. This is deliberate. The exclusive variant returns the line without the
terminator, but leaves that terminator in the stream. A loop that reads line
after line with it would read an empty string on every other call. The
`Inclusive` form consumes the delimiter, which is what you want when parsing a
stream of `\r\n`-terminated lines. For a bulk string the code does not read a
line at all: it reads exactly the advertised number of bytes, then discards
the two trailing framing bytes.

## Talking to a real Redis

Point the client at a real server by replacing the in-process listener with a
connection to `127.0.0.1:6379`, exactly as [the TCP
recipe](https://www.ziglang.in/learn/networking/tcp-echo/) connects. The encoding and decoding here
are the real thing, so the same `sendCommand` and reply parser work against
`redis-server` unchanged. The parser handles the four reply types most
commands return; add the array case (`*`) for commands like `KEYS` or
`HGETALL`.

## Variations

- **Pipelining:** send several commands before reading any replies. RESP
  allows it, and it cuts round trips; the reply order matches the send order.
- **Binary values:** because bulk strings are length-prefixed, storing raw
  bytes works without escaping.
- **A persistent store:** for a database that keeps data on disk from Zig, see
  [SQLite from Zig](https://www.ziglang.in/learn/how-to/databases/sqlite-basic/).
