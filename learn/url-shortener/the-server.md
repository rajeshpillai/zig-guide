# The Server

> The client, the slugs and the routes assembled into one file, run against a real Postgres.

## The problem

Three chapters built three pieces, each proven against bytes: a
Postgres client, slug arithmetic, and a CRUD handler over a store
seam. What remains is the part that cannot run in a browser: real
sockets on both sides. One file assembles everything, so the whole
service is something you can read top to bottom and run with one
command.

CI compiles this file on every run, which is what keeps it correct
against Zig master like every other snippet. It cannot run it, because
there is no Postgres in the room. On your machine there can be.

## The plan

1. Connect to Postgres on 127.0.0.1:5432 and reuse the client
   chapter's `PgClient`, trimmed to what the server calls.
2. `SqlStore`: the routes chapter's store interface, backed by SQL.
   Values are quoted into statement text by `sqlQuote`, every `'`
   doubled, so a value cannot end its own quotes.
3. The same `handle` function, behind the same seam.
4. An accept loop: parse one request, answer it, close. One Postgres
   connection serves everything.

```zig
const std = @import("std");

// ------------------------------------------------- wire framing, again
// Identical to the client chapter. In a multi-file project this block
// would be the module the chapters share; in a one-file server you can
// read top to bottom, it is forty lines of tax.

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
// The client chapter's PgClient, trimmed to what this server calls.

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
                    // A default Postgres wants SCRAM; the intro chapter
                    // says how to allow password auth for this demo.
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

    /// Run a statement, keep none of the result.
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
                else => {}, // T, C, N: nothing this server needs
            }
        }
    }

    /// Read the remaining messages so the connection is ready again.
    /// Call after copying anything you keep: row values live in the
    /// client's message buffer, and draining overwrites it.
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
// The same interface the routes chapter ran in memory, backed by SQL.
// Values are quoted into the statement text: every ' in the value
// becomes '', so the value cannot end its own quotes. This is the
// simple-protocol tradeoff named in the intro; the extended protocol,
// which ships values outside the SQL entirely, is what a production
// driver uses instead.

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

    /// The slug is derived from the id, and the id comes from the
    /// table's sequence, so ask the sequence first and insert a complete
    /// row. Two statements; a production service would wrap them in a
    /// transaction so a crash between them cannot leak an id.
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

    /// The redirect's read and its hit count in one statement: no
    /// second round trip, and no lost update when two requests race.
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
// The routes chapter's handler with the SQL store behind the seam. The
// shape is unchanged; only the store calls differ, and only because the
// in-memory version handed out pointers where SQL hands out copies.

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

    // One connection to Postgres, serving every request in turn.
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
    "check the intro chapter's docker run line; a stock Postgres asks for " ++
    "SCRAM auth, which this client does not speak";

fn serveOne(io: std.Io, store: *SqlStore, conn: *std.Io.net.Stream) !void {
    var rbuf: [4096]u8 = undefined;
    var wbuf: [2048]u8 = undefined;
    var reader = conn.reader(io, &rbuf);
    var writer = conn.writer(io, &wbuf);

    // Read header lines to the blank line, then exactly Content-Length
    // bytes of body. A request is bytes with edges only HTTP knows;
    // reading "what is there" instead would work until the first client
    // whose request arrives split, which the short-reads chapter covers.
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

*Needs a Postgres answering on localhost, which CI does not have. Compiled against Zig master on every run; the commands below run it against a throwaway database. (`22-url-shortener.the-server`)*

## Run it

A stock Postgres asks for SCRAM authentication, which this client
does not speak. The container flag `POSTGRES_HOST_AUTH_METHOD=password`
selects the cleartext method the client knows; that is acceptable on
loopback and nowhere else.

```bash
docker run --rm -d --name shortener-pg \
  -e POSTGRES_USER=shortener -e POSTGRES_PASSWORD=hunter2 \
  -e POSTGRES_DB=shortener -e POSTGRES_HOST_AUTH_METHOD=password \
  -p 5432:5432 postgres:16

zig run the-server.zig
```

Then, from another terminal, the whole CRUD surface:

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

`docker stop shortener-pg` removes the database when you are done.

## What changed behind the seam, and what did not

Compare `handle` here with the routes chapter: the dispatch, the
status codes and the bodies are the same, because the seam held. What
changed is ownership. The in-memory store handed out pointers into its
own array; SQL hands out bytes in a message buffer that the next query
overwrites, so every store method copies what it returns and drains
the row iterator before handing back control. The redirect also got
better on the way through: `UPDATE ... SET hits = hits + 1 ...
RETURNING target` reads the target and counts the hit in one
statement, so two simultaneous visitors cannot lose an update.

## Quoting is a defense with a known edge

`sqlQuote` doubles every `'` and the demo stores an O'Reilly URL to
prove it. Understand what that buys and what it does not. It stops a
value from terminating its own string literal, which is the classic
injection. It is also the method the simple query protocol forces,
and keeping it correct forever is exactly the burden real drivers
refuse: they use the extended protocol, where values travel in
separate messages and are never part of the SQL text at all. That
protocol is more messages, not more ideas, and the client chapter's
`switch` is where `Parse`, `Bind` and `Execute` would go.

## What to build next

- **Pooling:** one Postgres connection means one query at a time. A
  pool is a fixed array of clients and a free list, and the
  [many-clients chapter](https://www.ziglang.in/learn/networking/many-clients/) supplies the
  concurrency model.
- **The extended protocol:** replace `sqlQuote` with real parameters.
  The messages are in the Postgres manual; the framing code does not
  change.
- **SCRAM:** one more arm in the auth `switch`, and the loopback-only
  configuration above stops being necessary.
