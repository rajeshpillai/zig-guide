# The Server

> The client, the slugs and the routes put together into one file, and run against a real Postgres.

A URL shortener in Zig fits in one file. The file contains a Postgres wire
client, base62 slugs, and a CRUD `handle` function behind a store seam. An
accept loop serves the routes on real sockets. The server runs against a local
Postgres that one `docker run` command starts.

## The problem

Three chapters built three parts, and the tests of each part used bytes. The
last part cannot run in a browser: real sockets on both sides. All the
code is in one file. Thus you can read the full service from the top to the
bottom.

CI compiles this file on each run. Thus the file stays correct against Zig
master, the same as each other snippet. CI cannot run the file, because CI has
no Postgres server. You can run the file on your computer against a local
Postgres.

## The plan

1. Connect to Postgres on 127.0.0.1:5432. Use the `PgClient` from the client
   chapter again, with only the parts that the server calls.
2. `SqlStore`: the store interface from the routes chapter, with SQL behind
   it. `sqlQuote` puts values into the statement text, and doubles each `'`.
   Thus a value cannot end its own quotes.
3. The same `handle` function, behind the same seam.
4. An accept loop: parse one request, answer it, and close the connection. One
   Postgres connection serves all requests.

```zig
const std = @import("std");

// ------------------------------------------------- wire framing, again
// The same as in the client chapter. In a multi-file project, this block is
// the module that the chapters share. In a one-file server that you read
// from the top to the bottom, it is forty lines of repeated code.

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

// ------------------------------------------------------ the pg client
// The PgClient from the client chapter, with only the parts that this
// server calls.

const PgClient = struct {
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    msg_buf: [512]u8 = undefined,
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

    fn connect(r: *std.Io.Reader, w: *std.Io.Writer, user: []const u8, database: []const u8, password: []const u8) !PgClient {
        var body_buf: [128]u8 = undefined;
        var body: std.Io.Writer = .fixed(&body_buf);
        try putInt(i32, &body, 196608); // protocol 3.0
        for ([_][]const u8{ "user", user, "database", database }) |s| {
            try body.writeAll(s);
            try body.writeAll("\x00");
        }
        try body.writeAll("\x00");
        try putInt(i32, w, @intCast(4 + body.buffered().len));
        try w.writeAll(body.buffered());
        try w.flush();

        var client = PgClient{ .r = r, .w = w };
        while (true) {
            const m = try client.readMsg();
            var c = Cursor{ .b = m.payload };
            switch (m.tag) {
                'R' => switch (c.int(i32)) {
                    0 => {},
                    3 => {
                        var pw_buf: [64]u8 = undefined;
                        var pw: std.Io.Writer = .fixed(&pw_buf);
                        try pw.writeAll(password);
                        try pw.writeAll("\x00");
                        try sendMsg(w, 'p', pw.buffered());
                        try w.flush();
                    },
                    // A default Postgres wants SCRAM. The server chapter
                    // tells you how to allow password auth for this demo.
                    else => return error.UnsupportedAuth,
                },
                'S', 'K', 'N' => {},
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

    fn query(self: *PgClient, sql: []const u8) !Rows {
        var sql_buf: [512]u8 = undefined;
        var q: std.Io.Writer = .fixed(&sql_buf);
        try q.writeAll(sql);
        try q.writeAll("\x00");
        try sendMsg(self.w, 'Q', q.buffered());
        try self.w.flush();
        return .{ .client = self };
    }

    /// Run a statement, and keep no part of the result.
    fn exec(self: *PgClient, sql: []const u8) !void {
        var rows = try self.query(sql);
        while (try rows.next()) |_| {}
    }
};

const Rows = struct {
    client: *PgClient,

    const Row = struct { values: [4][]const u8, count: usize };

    fn next(self: *Rows) !?Row {
        while (true) {
            const m = try self.client.readMsg();
            var c = Cursor{ .b = m.payload };
            switch (m.tag) {
                'D' => {
                    var row = Row{ .values = undefined, .count = @intCast(c.int(i16)) };
                    for (0..row.count) |i| {
                        const len = c.int(i32);
                        if (len < 0) {
                            row.values[i] = "";
                            continue;
                        }
                        row.values[i] = c.b[c.i..][0..@intCast(len)];
                        c.i += @intCast(len);
                    }
                    return row;
                },
                'E' => {
                    self.client.storeError(m.payload);
                    while ((try self.client.readMsg()).tag != 'Z') {}
                    self.client.ready_status = 'I';
                    return error.QueryFailed;
                },
                'Z' => {
                    self.client.ready_status = m.payload[0];
                    return null;
                },
                else => {}, // T, C, N: this server does not need them
            }
        }
    }

    /// Read the other messages, to make the connection ready again. Call
    /// this function after you copy the values that you keep. Row values are
    /// in the message buffer of the client, and this function writes over it.
    fn drain(self: *Rows) !void {
        while (try self.next()) |_| {}
    }
};

// -------------------------------------------------- slugs, from before

const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

fn encode(id: u64, buf: *[11]u8) []const u8 {
    var rest = id;
    var i: usize = buf.len;
    while (true) {
        i -= 1;
        buf[i] = alphabet[@intCast(rest % 62)];
        rest /= 62;
        if (rest == 0) break;
    }
    return buf[i..];
}

fn checkTarget(url: []const u8) !void {
    const has_scheme = std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://");
    if (!has_scheme) return error.SchemeNotAllowed;
    for (url) |ch| {
        if (ch <= ' ' or ch == 0x7f) return error.BadCharacter;
    }
}

// ------------------------------------------------------- the sql store
// The same interface that the routes chapter used in memory, with SQL
// behind it. The store quotes values into the statement text: each ' in the
// value becomes ''. Thus the value cannot end its own quotes. This quoting
// is the simple-protocol tradeoff that the intro names. A production driver
// uses the extended protocol, which sends values outside the SQL.

fn sqlQuote(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |ch| {
        if (ch == '\'') try w.writeAll("''") else try w.writeByte(ch);
    }
    try w.writeByte('\'');
}

const SqlStore = struct {
    client: *PgClient,

    fn ensureSchema(self: *SqlStore) !void {
        try self.client.exec(
            \\CREATE TABLE IF NOT EXISTS links (
            \\  id     bigserial PRIMARY KEY,
            \\  slug   text UNIQUE NOT NULL,
            \\  target text NOT NULL,
            \\  hits   bigint NOT NULL DEFAULT 0
            \\)
        );
    }

    /// The slug comes from the id, and the id comes from the sequence of
    /// the table. Thus ask the sequence first, then insert a complete row.
    /// That is two statements. A production service puts them in a
    /// transaction. Then a crash between them cannot lose an id.
    fn create(self: *SqlStore, target: []const u8, slug_buf: *[11]u8) ![]const u8 {
        var rows = try self.client.query("SELECT nextval('links_id_seq')");
        const row = (try rows.next()) orelse return error.NoRow;
        const id = try std.fmt.parseInt(u64, row.values[0], 10);
        try rows.drain();

        const slug = encode(id, slug_buf);
        var stmt_buf: [512]u8 = undefined;
        var stmt: std.Io.Writer = .fixed(&stmt_buf);
        try stmt.print("INSERT INTO links (id, slug, target) VALUES ({d}, ", .{id});
        try sqlQuote(&stmt, slug);
        try stmt.writeAll(", ");
        try sqlQuote(&stmt, target);
        try stmt.writeAll(")");
        try self.client.exec(stmt.buffered());
        return slug;
    }

    const LinkInfo = struct {
        target_buf: [256]u8,
        target_len: usize,
        hits: u64,

        fn target(self: *const LinkInfo) []const u8 {
            return self.target_buf[0..self.target_len];
        }
    };

    fn lookup(self: *SqlStore, slug: []const u8) !?LinkInfo {
        var stmt_buf: [128]u8 = undefined;
        var stmt: std.Io.Writer = .fixed(&stmt_buf);
        try stmt.writeAll("SELECT target, hits FROM links WHERE slug = ");
        try sqlQuote(&stmt, slug);
        var rows = try self.client.query(stmt.buffered());
        const row = (try rows.next()) orelse return null;
        var info = LinkInfo{ .target_buf = undefined, .target_len = row.values[0].len, .hits = 0 };
        @memcpy(info.target_buf[0..info.target_len], row.values[0]);
        info.hits = try std.fmt.parseInt(u64, row.values[1], 10);
        try rows.drain();
        return info;
    }

    /// The read for the redirect and its hit count, in one statement. It
    /// needs no second round trip. When two requests race, no update is lost.
    fn follow(self: *SqlStore, slug: []const u8, target_buf: *[256]u8) !?[]const u8 {
        var stmt_buf: [128]u8 = undefined;
        var stmt: std.Io.Writer = .fixed(&stmt_buf);
        try stmt.writeAll("UPDATE links SET hits = hits + 1 WHERE slug = ");
        try sqlQuote(&stmt, slug);
        try stmt.writeAll(" RETURNING target");
        var rows = try self.client.query(stmt.buffered());
        const row = (try rows.next()) orelse return null;
        const target = target_buf[0..row.values[0].len];
        @memcpy(target, row.values[0]);
        try rows.drain();
        return target;
    }

    fn update(self: *SqlStore, slug: []const u8, target: []const u8) !bool {
        var stmt_buf: [512]u8 = undefined;
        var stmt: std.Io.Writer = .fixed(&stmt_buf);
        try stmt.writeAll("UPDATE links SET target = ");
        try sqlQuote(&stmt, target);
        try stmt.writeAll(" WHERE slug = ");
        try sqlQuote(&stmt, slug);
        try stmt.writeAll(" RETURNING id");
        var rows = try self.client.query(stmt.buffered());
        const found = (try rows.next()) != null;
        try rows.drain();
        return found;
    }

    fn remove(self: *SqlStore, slug: []const u8) !bool {
        var stmt_buf: [128]u8 = undefined;
        var stmt: std.Io.Writer = .fixed(&stmt_buf);
        try stmt.writeAll("DELETE FROM links WHERE slug = ");
        try sqlQuote(&stmt, slug);
        try stmt.writeAll(" RETURNING id");
        var rows = try self.client.query(stmt.buffered());
        const found = (try rows.next()) != null;
        try rows.drain();
        return found;
    }
};

// ------------------------------------------------------------ the http
// The handler from the routes chapter, with the SQL store behind the seam.
// The shape does not change. Only the store calls are different, because
// the in-memory version returned pointers and SQL returns copies.

fn respond(w: *std.Io.Writer, status: []const u8, extra_header: []const u8, body: []const u8) !void {
    try w.print("HTTP/1.1 {s}\r\n", .{status});
    if (extra_header.len > 0) try w.print("{s}\r\n", .{extra_header});
    try w.print("Connection: close\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

fn handle(store: *SqlStore, request: []const u8, w: *std.Io.Writer) !void {
    const line_end = std.mem.find(u8, request, "\r\n") orelse return error.BadRequest;
    var line = std.mem.tokenizeScalar(u8, request[0..line_end], ' ');
    const method = line.next() orelse return error.BadRequest;
    const path = line.next() orelse return error.BadRequest;
    const body_start = std.mem.find(u8, request, "\r\n\r\n") orelse return error.BadRequest;
    const body = request[body_start + 4 ..];

    var scratch: [300]u8 = undefined;

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/links")) {
        checkTarget(body) catch |err| {
            const msg = try std.mem.print(&scratch, "{t}\n", .{err});
            return respond(w, "400 Bad Request", "", msg);
        };
        var slug_buf: [11]u8 = undefined;
        const slug = try store.create(body, &slug_buf);
        const msg = try std.mem.print(&scratch, "{s}\n", .{slug});
        return respond(w, "201 Created", "", msg);
    }

    if (std.mem.startsWith(u8, path, "/links/")) {
        const slug = path["/links/".len..];
        if (std.mem.eql(u8, method, "GET")) {
            const info = (try store.lookup(slug)) orelse
                return respond(w, "404 Not Found", "", "no such link\n");
            const msg = try std.mem.print(&scratch, "{s} -> {s} ({d} hits)\n", .{
                slug, info.target(), info.hits,
            });
            return respond(w, "200 OK", "", msg);
        }
        if (std.mem.eql(u8, method, "PUT")) {
            checkTarget(body) catch |err| {
                const msg = try std.mem.print(&scratch, "{t}\n", .{err});
                return respond(w, "400 Bad Request", "", msg);
            };
            if (!try store.update(slug, body))
                return respond(w, "404 Not Found", "", "no such link\n");
            return respond(w, "200 OK", "", "updated\n");
        }
        if (std.mem.eql(u8, method, "DELETE")) {
            if (!try store.remove(slug))
                return respond(w, "404 Not Found", "", "no such link\n");
            return respond(w, "204 No Content", "", "");
        }
        return respond(w, "405 Method Not Allowed", "", "");
    }

    if (std.mem.eql(u8, method, "GET")) {
        var target_buf: [256]u8 = undefined;
        if (try store.follow(path[1..], &target_buf)) |target| {
            const loc = try std.mem.print(&scratch, "Location: {s}", .{target});
            return respond(w, "302 Found", loc, "");
        }
    }
    return respond(w, "404 Not Found", "", "no such link\n");
}

// -------------------------------------------------------------- wiring

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &file_writer.interface;

    // One connection to Postgres. It serves each request in sequence.
    const pg_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 5432);
    var pg_stream = try pg_addr.connect(io, .{ .mode = .stream });
    defer pg_stream.close(io);
    var pg_rbuf: [4096]u8 = undefined;
    var pg_wbuf: [1024]u8 = undefined;
    var pg_reader = pg_stream.reader(io, &pg_rbuf);
    var pg_writer = pg_stream.writer(io, &pg_wbuf);

    var client = PgClient.connect(
        &pg_reader.interface,
        &pg_writer.interface,
        "shortener",
        "shortener",
        "hunter2",
    ) catch |err| {
        if (err == error.ConnectFailed) {
            try out.print("postgres refused: {s}\n", .{client_err_hint});
            try out.flush();
        }
        return err;
    };
    var store = SqlStore{ .client = &client };
    try store.ensureSchema();

    const http_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    var server = try http_addr.listen(io, .{});
    defer server.deinit(io);
    try out.writeAll("listening on http://127.0.0.1:8080\n");
    try out.flush();

    while (true) {
        var conn = server.accept(io) catch continue;
        defer conn.close(io);
        serveOne(io, &store, &conn) catch |err| {
            try out.print("request failed: {t}\n", .{err});
            try out.flush();
        };
    }
}

const client_err_hint =
    "check the docker run line in the server chapter; a stock Postgres asks for " ++
    "SCRAM auth, which this client does not speak";

fn serveOne(io: std.Io, store: *SqlStore, conn: *std.Io.net.Stream) !void {
    var rbuf: [4096]u8 = undefined;
    var wbuf: [2048]u8 = undefined;
    var reader = conn.reader(io, &rbuf);
    var writer = conn.writer(io, &wbuf);

    // Read header lines until the blank line, then exactly Content-Length
    // bytes of body. Only HTTP knows where a request starts and ends. If the
    // code reads only the bytes that are there now, it fails on the first
    // request that comes split. The short-reads chapter explains this.
    var request_buf: [2048]u8 = undefined;
    var used: usize = 0;
    var content_length: usize = 0;
    while (true) {
        const line = try reader.interface.takeDelimiterInclusive('\n');
        if (used + line.len + content_length > request_buf.len) return error.RequestTooBig;
        @memcpy(request_buf[used..][0..line.len], line);
        used += line.len;
        if (std.mem.eql(u8, line, "\r\n")) break;
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " \r\n");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    try reader.interface.readSliceAll(request_buf[used..][0..content_length]);

    try handle(store, request_buf[0 .. used + content_length], &writer.interface);
    try writer.interface.flush();
}
```

*This program needs a Postgres that answers on localhost, and CI does not have one. CI compiles the program against Zig master on each run. The commands below run the program against a temporary database. (`22-url-shortener.the-server`)*

## Run it

A standard Postgres asks for SCRAM authentication, and this client does not
support SCRAM. The container flag `POSTGRES_HOST_AUTH_METHOD=password` selects
the cleartext method that the client knows. That method is acceptable on
loopback, and nowhere else.

```bash
docker run --rm -d --name shortener-pg \
  -e POSTGRES_USER=shortener -e POSTGRES_PASSWORD=hunter2 \
  -e POSTGRES_DB=shortener -e POSTGRES_HOST_AUTH_METHOD=password \
  -p 5432:5432 postgres:16

zig run the-server.zig
```

Then, in a different terminal, use the full CRUD surface:

```bash
curl -X POST --data-binary 'https://ziglang.org' localhost:8080/links
# 1
curl -i localhost:8080/1
# HTTP/1.1 302 Found, Location: https://ziglang.org
curl localhost:8080/links/1
# 1 -> https://ziglang.org (1 hits)
curl -X PUT --data-binary 'https://ziglang.org/download/' localhost:8080/links/1
curl -X DELETE localhost:8080/links/1
```

When you finish, `docker stop shortener-pg` removes the database.

## What changed behind the seam, and what did not change

Compare `handle` here with the routes chapter. The dispatch, the status codes
and the bodies are the same, because the seam did not change.

The ownership changed. The in-memory store gave pointers into its own array.
SQL gives bytes in a message buffer, and the next query writes over that
buffer. Thus each store method copies the values that it returns. Each method
also reads all of the row iterator before it returns control.

The redirect is also better. `UPDATE ... SET hits = hits + 1 ... RETURNING
target` reads the target and counts the hit in one statement. Thus two visitors
at the same time cannot lose an update.

## SQL quotes are a defense with a known limit

`sqlQuote` doubles each `'`. Thus a value cannot end its own string literal,
and this stops the usual injection. The simple query protocol makes this
method necessary.

To keep this method correct for all time is a burden, and real drivers do not
use it. They use the extended protocol. In the extended protocol, values go in
separate messages and are never part of the SQL text. The extended protocol
adds more message types, but no new concepts. `Parse`, `Bind` and `Execute`
go into the `switch` of the client chapter.

## What to build next

- **Pooling:** with one Postgres connection, the server can do only one query
  at a time. A pool is a fixed array of clients and a free list. The
  [many-clients chapter](https://www.ziglang.in/learn/networking/many-clients/) gives the concurrency
  model.
- **The extended protocol:** replace `sqlQuote` with real parameters. The
  Postgres manual describes the messages. The framing code does not change.
- **SCRAM:** add one more arm in the auth `switch`. Then the loopback-only
  configuration above is not necessary.
