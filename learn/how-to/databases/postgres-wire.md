# Recipe: The PostgreSQL Wire Protocol

> Speak Postgres directly, framing a startup handshake and a query by hand.

## The problem

A Postgres driver is mostly a codec for one TCP protocol. Seeing that protocol
without a driver in the way is the fastest route to understanding what a query
actually costs and where a hang comes from. This recipe implements enough of
both ends to complete a startup handshake and run one query, so the exact
bytes are on the page.

As with the other database recipes, it stands up a mock backend in the same
process, so CI runs and diffs the whole exchange without a running `postgres`.
The framing is the real thing; only the auth and the query engine are stubbed.

## The plan

1. Everything is big-endian. Write one `putInt` and one `getInt` and reuse them.
2. Send a `StartupMessage`: it has no type byte, just a length and a list of
   parameters ending in a null.
3. Read the backend's reply stream until `ReadyForQuery` (`Z`), decoding each
   message by its type byte.
4. Send a `Query` (`Q`) and read `RowDescription` (`T`), `DataRow` (`D`),
   `CommandComplete` (`C`), and the next `ReadyForQuery`.

```zig
const std = @import("std");

// PostgreSQL frames everything big-endian (network order).
fn putInt(comptime T: type, w: *std.Io.Writer, v: T) !void {
    var b: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .big);
    try w.writeAll(&b);
}

fn getInt(comptime T: type, r: *std.Io.Reader) !T {
    var b: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    try r.readSliceAll(&b);
    return std.mem.readInt(T, &b, .big);
}

// After startup, every message is: a type byte, an Int32 length that counts
// itself but not the type byte, then that many minus four bytes of payload.
fn sendMsg(w: *std.Io.Writer, tag: u8, payload: []const u8) !void {
    try w.writeAll(&.{tag});
    try putInt(i32, w, @intCast(payload.len + 4));
    try w.writeAll(payload);
}

const Msg = struct { tag: u8, payload: []const u8 };

fn readMsg(r: *std.Io.Reader, buf: []u8) !Msg {
    var tb: [1]u8 = undefined;
    try r.readSliceAll(&tb);
    const len = try getInt(i32, r);
    const payload = buf[0..@intCast(len - 4)];
    try r.readSliceAll(payload);
    return .{ .tag = tb[0], .payload = payload };
}

// A little reader over a message payload.
const Cursor = struct {
    b: []const u8,
    i: usize = 0,
    fn int(self: *Cursor, comptime T: type) T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        const v = std.mem.readInt(T, self.b[self.i..][0..n], .big);
        self.i += n;
        return v;
    }
    fn cstr(self: *Cursor) []const u8 {
        const start = self.i;
        while (self.b[self.i] != 0) self.i += 1;
        defer self.i += 1; // step past the terminator
        return self.b[start..self.i];
    }
};

// --- the mock backend ---

fn serve(server: *std.Io.net.Server, io: std.Io) void {
    serveImpl(server, io) catch {};
}

fn sendParam(w: *std.Io.Writer, name: []const u8, val: []const u8) !void {
    var buf: [128]u8 = undefined;
    var fb = std.Io.Writer.fixed(&buf);
    try fb.writeAll(name);
    try fb.writeAll("\x00");
    try fb.writeAll(val);
    try fb.writeAll("\x00");
    try sendMsg(w, 'S', fb.buffered());
}

fn serveImpl(server: *std.Io.net.Server, io: std.Io) !void {
    var conn = try server.accept(io);
    defer conn.close(io);

    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var reader = conn.reader(io, &rbuf);
    var writer = conn.writer(io, &wbuf);
    const r = &reader.interface;
    const w = &writer.interface;

    // StartupMessage has no type byte: an Int32 length then the body. The demo
    // does not authenticate, so the body is read and discarded.
    const slen = try getInt(i32, r);
    try r.discardAll(@intCast(slen - 4));

    var p: [128]u8 = undefined;
    var fb = std.Io.Writer.fixed(&p);
    try putInt(i32, &fb, 0); // AuthenticationOk
    try sendMsg(w, 'R', fb.buffered());
    try sendParam(w, "server_version", "16.0");
    try sendParam(w, "client_encoding", "UTF8");
    fb = std.Io.Writer.fixed(&p);
    try putInt(i32, &fb, 4242); // BackendKeyData: pid
    try putInt(i32, &fb, 99887766); // secret
    try sendMsg(w, 'K', fb.buffered());
    try sendMsg(w, 'Z', "I"); // ReadyForQuery: idle
    try w.flush();

    // One simple Query, answered with a single text column and row.
    var mbuf: [1024]u8 = undefined;
    const q = try readMsg(r, &mbuf);
    if (q.tag == 'Q') {
        fb = std.Io.Writer.fixed(&p);
        try putInt(i16, &fb, 1); // RowDescription: one field
        try fb.writeAll("greeting\x00");
        try putInt(i32, &fb, 0); // table oid
        try putInt(i16, &fb, 0); // column number
        try putInt(i32, &fb, 25); // type oid: text
        try putInt(i16, &fb, -1); // type is variable length
        try putInt(i32, &fb, -1); // no type modifier
        try putInt(i16, &fb, 0); // text format
        try sendMsg(w, 'T', fb.buffered());

        fb = std.Io.Writer.fixed(&p);
        try putInt(i16, &fb, 1); // DataRow: one column
        try putInt(i32, &fb, 3); // its length
        try fb.writeAll("zig");
        try sendMsg(w, 'D', fb.buffered());

        try sendMsg(w, 'C', "SELECT 1\x00"); // CommandComplete
        try sendMsg(w, 'Z', "I");
        try w.flush();
    }

    _ = readMsg(r, &mbuf) catch {}; // Terminate, or the client hanging up
}

// --- the client ---

fn sendStartup(w: *std.Io.Writer, user: []const u8) !void {
    var buf: [256]u8 = undefined;
    var fb = std.Io.Writer.fixed(&buf);
    try putInt(i32, &fb, 196608); // protocol 3.0 == 3 << 16
    try fb.writeAll("user\x00");
    try fb.writeAll(user);
    try fb.writeAll("\x00");
    try fb.writeAll("\x00"); // end of parameters
    const body = fb.buffered();
    try putInt(i32, w, @intCast(4 + body.len)); // length counts itself
    try w.writeAll(body);
    try w.flush();
}

fn statusName(b: u8) []const u8 {
    return switch (b) {
        'I' => "idle",
        'T' => "in transaction",
        'E' => "failed transaction",
        else => "?",
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

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

    var mbuf: [1024]u8 = undefined;

    try out.writeAll("> startup (user=zig)\n");
    try sendStartup(w, "zig");
    while (true) {
        const m = try readMsg(r, &mbuf);
        var c = Cursor{ .b = m.payload };
        switch (m.tag) {
            'R' => if (c.int(i32) == 0) try out.writeAll("auth:    ok\n"),
            'S' => try out.print("param:   {s}={s}\n", .{ c.cstr(), c.cstr() }),
            'K' => try out.print("backend: pid={d}\n", .{c.int(i32)}),
            'Z' => {
                try out.print("ready:   {s}\n", .{statusName(m.payload[0])});
                break;
            },
            else => {},
        }
    }

    try out.writeAll("> query: SELECT 'zig' AS greeting\n");
    try sendMsg(w, 'Q', "SELECT 'zig' AS greeting\x00");
    try w.flush();
    while (true) {
        const m = try readMsg(r, &mbuf);
        var c = Cursor{ .b = m.payload };
        switch (m.tag) {
            'T' => {
                const n = c.int(i16);
                try out.print("fields:  {d} ({s})\n", .{ n, c.cstr() });
            },
            'D' => {
                _ = c.int(i16); // column count
                const len = c.int(i32);
                try out.print("row:     {s}\n", .{c.b[c.i..][0..@intCast(len)]});
            },
            'C' => try out.print("done:    {s}\n", .{c.cstr()}),
            'Z' => {
                try out.print("ready:   {s}\n", .{statusName(m.payload[0])});
                break;
            },
            else => {},
        }
    }

    try sendMsg(w, 'X', ""); // Terminate
    try w.flush();
    thread.join();
    try out.flush();
}
```

*A self-contained client and mock backend, built and run natively by CI. No postgres server, and browser wasm has no sockets. (`06-cookbook.postgres-wire`)*

## Two message shapes

After the first message, every Postgres message has the same frame: a one-byte
type, an `Int32` length that counts itself but not the type byte, then `length
- 4` bytes of payload. `sendMsg` and `readMsg` encode exactly that, so the
rest of the code only cares about payloads. The startup message is the one
exception: it predates the type-byte convention, so it is a bare length and
body. That asymmetry is why `sendStartup` and `readMsg` are separate.

## The handshake is a stream, not a call

Sending the startup message does not get you one reply. The backend answers
with a run of messages. `AuthenticationOk` first. Then one `ParameterStatus`
per server setting (`server_version`, `client_encoding`, and normally a dozen
more). Then `BackendKeyData` with the process id and secret used to cancel
queries. And finally `ReadyForQuery`. The client loops until it sees `Z`,
which is the signal that the connection is usable. A real driver caches those
parameters and the cancel key here.

## Reading a result

A query answers with the same streaming shape. `RowDescription` names the
columns and their types. `DataRow` carries one row as length-prefixed column
values, where a length of -1 means SQL `NULL`. `CommandComplete` reports the
tag. And `ReadyForQuery` closes the batch. The `Cursor` helper walks a payload
with an index, reading integers and null-terminated strings, which is all the
parsing these messages need.

## Flush or hang

Every send here is followed by a flush, and the reason is the bug this recipe
first hit. The socket writer buffers, so a message you "sent" is still in your
buffer until you flush. If both sides then block reading, nothing moves. That
is the classic wire-protocol deadlock, and it is easy to introduce the moment
a send stops being immediately followed by a flush.

## Variations

- **Real auth:** the backend can answer startup with `AuthenticationCleartextPassword`
  or an MD5/SCRAM challenge instead of `AuthenticationOk`; the client replies
  with a `PasswordMessage` and the loop continues.
- **Prepared statements:** the extended-query protocol replaces `Q` with
  `Parse`/`Bind`/`Execute`, which is how parameters stay out of the SQL text.
- **A local database instead:** for persistence without a server or a protocol,
  [SQLite from Zig](https://www.ziglang.in/learn/how-to/databases/sqlite-basic/) links the C library directly.
