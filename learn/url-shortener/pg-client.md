# A Postgres Client

> Startup, password auth, a row iterator and error recovery, tested against scripted bytes.

## The problem

The [cookbook recipe](https://www.ziglang.in/learn/how-to/databases/postgres-wire/) proved the
wire protocol is just tagged, length-prefixed messages. A recipe is not
a client. The service in this project needs something it can call
without thinking about bytes: connect and authenticate, send SQL, walk
the rows, and find out what went wrong when a query fails, without
losing the connection.

That last part matters more than it sounds. A shortener will hit
constraint violations in normal operation; a client that treats every
error as fatal reconnects all day.

## The plan

1. `PgClient` holds a reader, a writer, and the server's last known
   state. It never opens a socket; whoever owns the connection hands in
   the streams.
2. `connect` sends the startup message and walks the handshake. If the
   server asks for a password, it sends one.
3. `query` returns `Rows`, an iterator. Column names arrive in the
   `RowDescription` message; values arrive one `DataRow` at a time.
4. An `ErrorResponse` becomes a Zig error, with the SQL state code and
   message kept on the client. The iterator drains to `ReadyForQuery`
   first, so the connection is immediately usable again.

The demo talks to a scripted backend: the server half of two
conversations written into a buffer in advance. The client cannot tell.
It parses a `Reader`, and bytes from a script are bytes. That is the
guide's usual seam, and it is how a driver gets regression tests
without a database in CI.

```zig
const std = @import("std");

// ------------------------------------------------- framing, as the recipe
// Postgres frames everything big-endian: a tag byte, an Int32 length that
// counts itself but not the tag, then the payload.

fn putInt(comptime T: type, w: *std.Io.Writer, v: T) !void {
    var b: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .big);
    try w.writeAll(&b);
}

fn sendMsg(w: *std.Io.Writer, tag: u8, payload: []const u8) !void {
    try w.writeAll(&.{tag});
    try putInt(i32, w, @intCast(payload.len + 4));
    try w.writeAll(payload);
}

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
        defer self.i += 1;
        return self.b[start..self.i];
    }
};

// ------------------------------------------------------------- the client

const max_columns = 8;

/// A Postgres connection: a reader, a writer, and enough state to know
/// what the server last said. It never touches a socket. Whoever owns
/// the connection hands in the two streams, which is why the demo below
/// can hand it a script instead.
const PgClient = struct {
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    msg_buf: [512]u8 = undefined,
    asked_for_password: bool = false,
    /// From the last ReadyForQuery: 'I' idle, 'T' in transaction, 'E' failed.
    ready_status: u8 = 0,
    err_code: [5]u8 = undefined,
    err_msg: [256]u8 = undefined,
    err_msg_len: usize = 0,

    const Msg = struct { tag: u8, payload: []const u8 };

    fn readMsg(self: *PgClient) !Msg {
        var tag: [1]u8 = undefined;
        try self.r.readSliceAll(&tag);
        var len_bytes: [4]u8 = undefined;
        try self.r.readSliceAll(&len_bytes);
        const len = std.mem.readInt(i32, &len_bytes, .big);
        const payload = self.msg_buf[0..@intCast(len - 4)];
        try self.r.readSliceAll(payload);
        return .{ .tag = tag[0], .payload = payload };
    }

    /// Startup and authentication, up to the first ReadyForQuery. The
    /// server chooses the auth method; this client speaks "none" and
    /// "cleartext password", which is what loopback setups use. SCRAM,
    /// the production method, slots in as one more case here.
    fn connect(r: *std.Io.Reader, w: *std.Io.Writer, user: []const u8, database: []const u8, password: []const u8) !PgClient {
        var body_buf: [128]u8 = undefined;
        var body: std.Io.Writer = .fixed(&body_buf);
        try putInt(i32, &body, 196608); // protocol 3.0
        for ([_][]const u8{ "user", user, "database", database }) |s| {
            try body.writeAll(s);
            try body.writeAll("\x00");
        }
        try body.writeAll("\x00");
        // The startup message alone has no tag byte.
        try putInt(i32, w, @intCast(4 + body.buffered().len));
        try w.writeAll(body.buffered());
        try w.flush();

        var client = PgClient{ .r = r, .w = w };
        while (true) {
            const m = try client.readMsg();
            var c = Cursor{ .b = m.payload };
            switch (m.tag) {
                'R' => switch (c.int(i32)) {
                    0 => {}, // AuthenticationOk
                    3 => { // AuthenticationCleartextPassword
                        client.asked_for_password = true;
                        var pw_buf: [64]u8 = undefined;
                        var pw: std.Io.Writer = .fixed(&pw_buf);
                        try pw.writeAll(password);
                        try pw.writeAll("\x00");
                        try sendMsg(w, 'p', pw.buffered());
                        try w.flush();
                    },
                    else => return error.UnsupportedAuth,
                },
                'S', 'K' => {}, // parameters and cancel key: noted, unused
                'E' => {
                    client.storeError(m.payload);
                    return error.ConnectFailed;
                },
                'Z' => {
                    client.ready_status = m.payload[0];
                    return client;
                },
                else => {},
            }
        }
    }

    fn storeError(self: *PgClient, payload: []const u8) void {
        // ErrorResponse is a list of fields: a type byte, a C string,
        // ending at a zero byte. Code and message are the useful two.
        var c = Cursor{ .b = payload };
        while (c.b[c.i] != 0) {
            const kind = c.b[c.i];
            c.i += 1;
            const text = c.cstr();
            switch (kind) {
                'C' => @memcpy(&self.err_code, text[0..5]),
                'M' => {
                    const n = @min(text.len, self.err_msg.len);
                    @memcpy(self.err_msg[0..n], text[0..n]);
                    self.err_msg_len = n;
                },
                else => {},
            }
        }
    }

    fn errorMessage(self: *const PgClient) []const u8 {
        return self.err_msg[0..self.err_msg_len];
    }

    fn query(self: *PgClient, sql: []const u8) !Rows {
        var sql_buf: [256]u8 = undefined;
        var q: std.Io.Writer = .fixed(&sql_buf);
        try q.writeAll(sql);
        try q.writeAll("\x00");
        try sendMsg(self.w, 'Q', q.buffered());
        try self.w.flush();
        return .{ .client = self };
    }
};

/// Row iteration. Column values are slices into the client's message
/// buffer: valid until the next call, exactly like a real driver's
/// zero-copy row. Copy anything you keep.
const Rows = struct {
    client: *PgClient,
    column_count: usize = 0,
    names: [max_columns][24]u8 = undefined,
    name_lens: [max_columns]usize = @splat(0),

    const Row = struct { values: [max_columns][]const u8, count: usize };

    fn name(self: *const Rows, i: usize) []const u8 {
        return self.names[i][0..self.name_lens[i]];
    }

    fn next(self: *Rows) !?Row {
        while (true) {
            const m = try self.client.readMsg();
            var c = Cursor{ .b = m.payload };
            switch (m.tag) {
                'T' => { // RowDescription: names now, values in 'D' messages
                    self.column_count = @intCast(c.int(i16));
                    for (0..self.column_count) |i| {
                        const n = c.cstr();
                        const len = @min(n.len, self.names[i].len);
                        @memcpy(self.names[i][0..len], n[0..len]);
                        self.name_lens[i] = len;
                        // table oid, attnum, type oid, typlen, typmod,
                        // format: 18 bytes this client has no use for.
                        c.i += 18;
                    }
                },
                'D' => {
                    var row = Row{ .values = undefined, .count = @intCast(c.int(i16)) };
                    for (0..row.count) |i| {
                        const len = c.int(i32);
                        if (len < 0) {
                            row.values[i] = "<null>";
                            continue;
                        }
                        row.values[i] = c.b[c.i..][0..@intCast(len)];
                        c.i += @intCast(len);
                    }
                    return row;
                },
                'C' => {}, // CommandComplete; the tag repeats what we sent
                'E' => {
                    self.client.storeError(m.payload);
                    // Drain to ReadyForQuery so the connection stays usable.
                    while ((try self.client.readMsg()).tag != 'Z') {}
                    self.client.ready_status = 'I';
                    return error.QueryFailed;
                },
                'Z' => {
                    self.client.ready_status = m.payload[0];
                    return null;
                },
                else => {},
            }
        }
    }
};

// ---------------------------------------------------- a scripted backend

/// The server half of two conversations, written into a buffer in
/// advance. The client cannot tell: it parses a `Reader`, and bytes from
/// a script are bytes. This is the site's usual trick, and it is also
/// how you get regression tests for a driver without a database in CI.
fn scriptBackend(w: *std.Io.Writer) !void {
    var pbuf: [256]u8 = undefined;
    var p: std.Io.Writer = .fixed(&pbuf);

    // Connection: demand a password, accept it, ready.
    try putInt(i32, &p, 3); // AuthenticationCleartextPassword
    try sendMsg(w, 'R', p.buffered());
    p = .fixed(&pbuf);
    try putInt(i32, &p, 0); // AuthenticationOk
    try sendMsg(w, 'R', p.buffered());
    try sendMsg(w, 'S', "server_version\x0016.4\x00");
    try sendMsg(w, 'Z', "I");

    // The SELECT: three columns, one row, done.
    p = .fixed(&pbuf);
    try putInt(i16, &p, 3);
    for ([_][]const u8{ "id", "target", "hits" }) |col| {
        try p.writeAll(col);
        try p.writeAll("\x00");
        try putInt(i32, &p, 0); // table oid
        try putInt(i16, &p, 0); // column number
        try putInt(i32, &p, 25); // type oid: text
        try putInt(i16, &p, -1); // variable length
        try putInt(i32, &p, -1); // no modifier
        try putInt(i16, &p, 0); // text format
    }
    try sendMsg(w, 'T', p.buffered());
    p = .fixed(&pbuf);
    try putInt(i16, &p, 3);
    for ([_][]const u8{ "7", "https://ziglang.org", "41" }) |val| {
        try putInt(i32, &p, @intCast(val.len));
        try p.writeAll(val);
    }
    try sendMsg(w, 'D', p.buffered());
    try sendMsg(w, 'C', "SELECT 1\x00");
    try sendMsg(w, 'Z', "I");

    // The INSERT: rejected, then ready again anyway.
    try sendMsg(w, 'E', "SERROR\x00C23505\x00" ++
        "Mduplicate key value violates unique constraint \"links_slug_key\"\x00\x00");
    try sendMsg(w, 'Z', "I");
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var backend_bytes: [1024]u8 = undefined;
    var backend: std.Io.Writer = .fixed(&backend_bytes);
    try scriptBackend(&backend);

    var sent: [512]u8 = undefined; // what the client says, unexamined here
    var to_server: std.Io.Writer = .fixed(&sent);
    var from_server: std.Io.Reader = .fixed(backend.buffered());

    var client = try PgClient.connect(&from_server, &to_server, "shortener", "links", "hunter2");
    try out.print("connect: password asked: {}, ready: {c}\n", .{
        client.asked_for_password, client.ready_status,
    });

    try out.writeAll("\nquery: SELECT id, target, hits FROM links WHERE slug = 'zig1'\n");
    var rows = try client.query("SELECT id, target, hits FROM links WHERE slug = 'zig1'");
    while (try rows.next()) |row| {
        try out.writeAll("  row:");
        for (0..row.count) |i| {
            try out.print(" {s}={s}", .{ rows.name(i), row.values[i] });
        }
        try out.writeAll("\n");
    }

    try out.writeAll("\nquery: INSERT INTO links (slug, target) VALUES ('zig1', ...)\n");
    var failing = try client.query("INSERT INTO links (slug, target) VALUES ('zig1', 'https://example.com')");
    _ = failing.next() catch {
        try out.print("  error {s}: {s}\n", .{ client.err_code, client.errorMessage() });
    };
    try out.print("  connection after the failure: ready: {c}\n", .{client.ready_status});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`22-url-shortener.pg-client`)*

## The server picks the auth method

The client does not decide how to authenticate; it answers whatever the
`R` message asks. Code 0 means accepted, code 3 means send the password
in the clear, which is what loopback setups use and what this client
speaks. A stock Postgres asks for SCRAM instead, a
challenge-response exchange that never puts the password on the wire.
It slots into the same `switch` as one more case, and the
[final chapter](https://www.ziglang.in/learn/url-shortener/the-server/) says how to configure
a local server down to the method this client knows.

## Rows are borrowed, not owned

Column values returned by `next` are slices into the client's message
buffer, valid until the next message is read. That is how real drivers
work too, and for the same reason: the alternative is an allocation per
row. The cost of borrowing is a rule the caller must follow: copy what
you keep. The server chapter's store copies each value it returns, and
the comment on `drain` in that file is this paragraph in one line.

## An error is a message, not a hangup

Watch the failing INSERT at the end of the trace. The server sends an
`ErrorResponse` carrying a five-character SQL state (`23505` is unique
violation), then a `ReadyForQuery` as if nothing happened, because from
its side nothing did: the transaction failed, the connection is fine.
The client stores the code and message, drains to ready, and returns
`error.QueryFailed`. The routes can now turn "duplicate slug" into a
response instead of a reconnect.

## Variations

- **More of the handshake:** the scripted backend sends one
  `ParameterStatus`; a real server sends a dozen. The client ignores
  them, which is what most drivers do with most of them.
- **Null:** a column can be null on the wire (length -1), which is not
  the empty string. This client substitutes a marker; a real driver
  makes the distinction typed.
- **The script is a test:** point `scriptBackend` at a bug you once hit
  (a truncated row, an error mid-results) and you have a regression
  test no integration suite could run as fast.
