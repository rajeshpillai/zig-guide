# Routes Over a Seam

> All five CRUD routes as one pure function, tested against an in-memory store.

## The problem

The HTTP surface is where create, read, update and delete become
routes. It is also the layer with the most cases to get right: the
slug that does not exist, the URL that fails validation, the method
nobody handles. Testing those against a running server and database
means standing both up for every case.

The fix is the same seam the
[ORM's Repo chapter](https://www.ziglang.in/learn/orm/repo/) built: put storage behind an
interface, and hand the handler whichever implementation the moment
calls for. Here the handler takes request bytes and a store, and
returns response bytes. With the in-memory store it needs no server,
no socket and no database, which is why this chapter runs in your
browser.

## The plan

1. A `Store` holding links in a fixed array, with the methods the
   routes are allowed to want: create, find, and nothing else.
2. `handle`: parse the request line, dispatch on method and path,
   write a complete HTTP response. Request parsing is the minimum that
   works; the [web server track](https://www.ziglang.in/learn/web-server/request/) does it
   in full.
3. A demo that runs all five routes, plus the failure cases, and
   prints each exchange.

```zig
const std = @import("std");

// From the slugs chapter, unchanged.
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

// ---------------------------------------------------------------- store

/// Everything the routes are allowed to ask of storage, and nothing
/// else. The final chapter swaps this struct for one whose methods
/// write SQL; the handler will not change by a line. Same seam, same
/// reason as the ORM's recording driver: the interesting logic gets
/// tested with no database in the room.
const Store = struct {
    const Link = struct {
        id: u64 = 0,
        slug_buf: [11]u8 = undefined,
        slug_len: usize = 0,
        target_buf: [256]u8 = undefined,
        target_len: usize = 0,
        hits: u64 = 0,
        live: bool = false,

        fn slug(self: *const Link) []const u8 {
            return self.slug_buf[0..self.slug_len];
        }
        fn target(self: *const Link) []const u8 {
            return self.target_buf[0..self.target_len];
        }
    };

    links: [16]Link = @splat(.{}),
    next_id: u64 = 1,

    fn create(self: *Store, target: []const u8) ?*Link {
        for (&self.links) |*link| {
            if (link.live) continue;
            const id = self.next_id;
            self.next_id += 1;
            link.* = .{ .id = id, .live = true };
            // encode fills the tail of its buffer; the slug lives at the
            // front. The ranges can overlap, which is what @memmove is for.
            const s = encode(id, &link.slug_buf);
            @memmove(link.slug_buf[0..s.len], s);
            link.slug_len = s.len;
            @memcpy(link.target_buf[0..target.len], target);
            link.target_len = target.len;
            return link;
        }
        return null;
    }

    fn find(self: *Store, slug: []const u8) ?*Link {
        for (&self.links) |*link| {
            if (link.live and std.mem.eql(u8, link.slug(), slug)) return link;
        }
        return null;
    }
};

// -------------------------------------------------------------- handler

fn respond(w: *std.Io.Writer, status: []const u8, extra_header: []const u8, body: []const u8) !void {
    try w.print("HTTP/1.1 {s}\r\n", .{status});
    if (extra_header.len > 0) try w.print("{s}\r\n", .{extra_header});
    try w.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

/// One request in, one response out, nothing else touched. The request
/// parsing here is the minimum that works; the web server track does it
/// properly, headers and all.
fn handle(store: *Store, request: []const u8, w: *std.Io.Writer) !void {
    const line_end = std.mem.find(u8, request, "\r\n") orelse return error.BadRequest;
    var line = std.mem.tokenizeScalar(u8, request[0..line_end], ' ');
    const method = line.next() orelse return error.BadRequest;
    const path = line.next() orelse return error.BadRequest;
    const body_start = std.mem.find(u8, request, "\r\n\r\n") orelse return error.BadRequest;
    const body = request[body_start + 4 ..];

    var scratch: [300]u8 = undefined;

    // Create: the body is the URL to shorten, the answer is the slug.
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/links")) {
        checkTarget(body) catch |err| {
            const msg = try std.mem.print(&scratch, "{t}\n", .{err});
            return respond(w, "400 Bad Request", "", msg);
        };
        const link = store.create(body) orelse
            return respond(w, "507 Insufficient Storage", "", "full\n");
        const msg = try std.mem.print(&scratch, "{s}\n", .{link.slug()});
        return respond(w, "201 Created", "", msg);
    }

    // The management routes share a prefix and a lookup.
    if (std.mem.startsWith(u8, path, "/links/")) {
        const link = store.find(path["/links/".len..]) orelse
            return respond(w, "404 Not Found", "", "no such link\n");
        if (std.mem.eql(u8, method, "GET")) {
            const msg = try std.mem.print(&scratch, "{s} -> {s} ({d} hits)\n", .{
                link.slug(), link.target(), link.hits,
            });
            return respond(w, "200 OK", "", msg);
        }
        if (std.mem.eql(u8, method, "PUT")) {
            checkTarget(body) catch |err| {
                const msg = try std.mem.print(&scratch, "{t}\n", .{err});
                return respond(w, "400 Bad Request", "", msg);
            };
            @memcpy(link.target_buf[0..body.len], body);
            link.target_len = body.len;
            return respond(w, "200 OK", "", "updated\n");
        }
        if (std.mem.eql(u8, method, "DELETE")) {
            link.live = false;
            return respond(w, "204 No Content", "", "");
        }
        return respond(w, "405 Method Not Allowed", "", "");
    }

    // The route the service exists for: anything else is a slug.
    if (std.mem.eql(u8, method, "GET")) {
        if (store.find(path[1..])) |link| {
            link.hits += 1;
            const loc = try std.mem.print(&scratch, "Location: {s}", .{link.target()});
            return respond(w, "302 Found", loc, "");
        }
    }
    return respond(w, "404 Not Found", "", "no such link\n");
}

// ----------------------------------------------------------------- demo

pub fn main(init: std.process.Init) !void {
    var out_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const out = &file_writer.interface;

    var store = Store{};

    const requests = [_][]const u8{
        "POST /links HTTP/1.1\r\nHost: s\r\n\r\nhttps://ziglang.org",
        "POST /links HTTP/1.1\r\nHost: s\r\n\r\njavascript:alert(1)",
        "GET /1 HTTP/1.1\r\nHost: s\r\n\r\n",
        "GET /links/1 HTTP/1.1\r\nHost: s\r\n\r\n",
        "PUT /links/1 HTTP/1.1\r\nHost: s\r\n\r\nhttps://ziglang.org/download/",
        "GET /1 HTTP/1.1\r\nHost: s\r\n\r\n",
        "DELETE /links/1 HTTP/1.1\r\nHost: s\r\n\r\n",
        "GET /1 HTTP/1.1\r\nHost: s\r\n\r\n",
    };

    for (requests) |request| {
        const line_end = std.mem.find(u8, request, "\r\n").?;
        try out.print("> {s}\n", .{request[0..line_end]});

        var response_buf: [512]u8 = undefined;
        var response: std.Io.Writer = .fixed(&response_buf);
        try handle(&store, request, &response);

        // Print the response minus HTTP's \r, one prefixed line each.
        var lines = std.mem.splitSequence(u8, response.buffered(), "\r\n");
        while (lines.next()) |l| {
            const line = std.mem.trimEnd(u8, l, "\n");
            if (line.len > 0) try out.print("< {s}\n", .{line});
        }
        try out.writeAll("\n");
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`22-url-shortener.routes`)*

## Read the trace as a contract

The demo is the service's specification, one exchange per case: create
answers 201 with the slug, the bad scheme answers 400 before storage
hears about it, the redirect answers 302 and counts the hit, update
changes where the same slug points, delete answers 204, and the slug
that no longer exists answers 404. When the final chapter swaps the
store for SQL, this trace is what must still be true.

## The routing order is load-bearing

`/links` and `/links/{slug}` are matched before the catch-all slug
route, which means a link whose slug is literally `links` could never
be reached. The slugs chapter's alphabet makes that collision
impossible today (`links` decodes to a huge id, not an early one), but
route shadowing is the kind of bug that arrives silently when someone
adds `/stats` next to a growing slug space. Keeping every reserved
path under one prefix, as `/links/...` does, is the cheap insurance.

## Variations

- **No allocation anywhere:** the store is a fixed array and every
  response is built in a caller-owned buffer. A service this size can
  simply decide its limits up front; 507 is what honesty looks like
  when the array fills.
- **Add a route:** a `GET /links` listing is one more branch and one
  more store method. Notice the handler cannot cheat: whatever it
  needs, it has to ask the seam for.
