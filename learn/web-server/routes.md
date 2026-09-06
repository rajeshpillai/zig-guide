# Routing and Query Strings

> Everything after the question mark, and the dispatch table that ignores it.

A request target is two things joined by a `?`. Before it is a path, which
decides *what runs*. After it is a query string, which is input to whatever
that is. The two are parsed differently and used differently, and treating
them as one string is the source of a surprising number of bugs.

Routing is the first half, and it is smaller than its reputation: a comparison
against a table. Everything a framework adds is compression of the table, not
a different decision.

## The program

```zig
const std = @import("std");
const path_util = @import("static.zig");

pub const Param = struct { name: []const u8, value: []const u8 };

/// In a query string `+` means a space. In a path it does not, which is why
/// this is a separate function from the path decoder rather than a flag on it.
fn decodeQueryValue(dest: []u8, src: []const u8) ![]u8 {
    var swapped: [256]u8 = undefined;
    if (src.len > swapped.len) return error.TooLong;
    for (src, 0..) |c, i| swapped[i] = if (c == '+') ' ' else c;
    return path_util.percentDecode(dest, swapped[0..src.len]);
}

/// Parse `a=1&b=hello+world&flag` into pairs. A key with no `=` is present
/// with an empty value, which is how HTML checkboxes and flags arrive.
pub fn parseQuery(target: []const u8, dest: []u8, out: []Param) ![]Param {
    const q = std.mem.findScalar(u8, target, '?') orelse return out[0..0];
    var used: usize = 0;
    var n: usize = 0;

    var pairs = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        if (n == out.len) return error.TooManyParams;

        const eq = std.mem.findScalar(u8, pair, '=');
        const raw_name = if (eq) |e| pair[0..e] else pair;
        const raw_value = if (eq) |e| pair[e + 1 ..] else "";

        const name = try decodeQueryValue(dest[used..], raw_name);
        used += name.len;
        const value = try decodeQueryValue(dest[used..], raw_value);
        used += value.len;

        out[n] = .{ .name = name, .value = value };
        n += 1;
    }
    return out[0..n];
}

pub fn find(params: []const Param, name: []const u8) ?[]const u8 {
    // Last wins. Real servers disagree about this, and the disagreement is
    // itself an attack: when a proxy takes the first `user` and the origin
    // takes the last, one request means two different things.
    var result: ?[]const u8 = null;
    for (params) |p| {
        if (std.mem.eql(u8, p.name, name)) result = p.value;
    }
    return result;
}

const Route = struct { method: []const u8, path: []const u8 };

/// Routing is a comparison. Everything a framework adds sits on top of this:
/// the table gets patterns, the patterns get compiled, and the compiled form
/// gets a tree. The decision being made never changes.
pub fn route(method: []const u8, target: []const u8) ?usize {
    const path = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;
    const table = [_]Route{
        .{ .method = "GET", .path = "/" },
        .{ .method = "GET", .path = "/search" },
        .{ .method = "POST", .path = "/submit" },
    };
    for (table, 0..) |r, i| {
        if (std.mem.eql(u8, r.method, method) and std.mem.eql(u8, r.path, path)) return i;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var scratch: [512]u8 = undefined;
    var params: [8]Param = undefined;

    const targets = [_][]const u8{
        "/search?q=hello+world&page=2",
        "/search?q=a%26b&empty=&flag",
        "/search?q=first&q=second",
        "/",
    };

    for (targets) |target| {
        const found = try parseQuery(target, &scratch, &params);
        try out.print("{s}\n", .{target});
        for (found) |p| try out.print("  {s} = \"{s}\"\n", .{ p.name, p.value });
        if (found.len == 0) try out.writeAll("  (no parameters)\n");
    }

    try out.writeAll("\nlast value wins\n");
    const dup = try parseQuery("/search?q=first&q=second", &scratch, &params);
    try out.print("  q -> \"{s}\"\n", .{find(dup, "q").?});

    try out.writeAll("\nrouting\n");
    for ([_][2][]const u8{
        .{ "GET", "/" },
        .{ "GET", "/search?q=x" },
        .{ "POST", "/submit" },
        .{ "GET", "/submit" },
        .{ "GET", "/missing" },
    }) |pair| {
        if (route(pair[0], pair[1])) |i| {
            try out.print("  {s: <5} {s: <14} -> handler {d}\n", .{ pair[0], pair[1], i });
        } else {
            try out.print("  {s: <5} {s: <14} -> 404\n", .{ pair[0], pair[1] });
        }
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`19-web-server.routes`)*

## What just happened

**`hello+world` became `hello world`, and `%26` became a literal `&`.** Both
matter. In a query string a plus sign means a space, a rule that exists only
there and not in the path. That is why the decoder is a separate function
rather than a flag. And `%26` decoded *after* the split on `&`, so a value
containing an ampersand stayed one value instead of becoming two parameters.
Decode after splitting on the structural characters. That is the opposite of
the ordering in the last chapter, and for the same reason: you decode at the
point where the result is data rather than structure.

**`empty=` and `flag` are different.** One is a parameter with an empty value,
the other has no `=` at all. HTML forms send both, and a parser that collapses
them cannot distinguish "the user cleared this field" from "this field was
never submitted".

**`q` appeared twice and the last one won.** Real servers disagree about this:
some take the first, some take the last, some build a list. The disagreement
is itself an attack. When a caching proxy takes the first value and the origin
server takes the last, one request means two different things to two systems.
That gap is where parameter-pollution bugs live. Whatever you choose, be able
to say what it is.

**Routing ignored the query.** `GET /search?q=x` matched the `/search` route,
because the path is what decides the handler and the query is its input. And
`GET /submit` was a 404 while `POST /submit` matched, because the method is
part of the route, not a detail checked later.

## Check yourself

The routing table is a linear scan over three entries. At what point does that
become the wrong shape?

Later than you would think, and the reason to change it is usually not speed.
A few dozen exact-match routes scanned linearly are nothing next to the
syscall that delivered the request. What forces a different structure is
*patterns*. Once a route contains a placeholder the comparison is no longer
equality, and matching a hundred patterns against every request means either
compiling them into a tree that walks the path once, or accepting a hundred
partial matches per request. That tree is what a real router is, and it exists
because of patterns rather than because of scale.

## If you have written C

The parsing is the same and the memory is the difference. The C version either
decodes in place, which works because a decoded string is never longer than
its encoded form, or allocates for each value and then owns freeing them.

Decoding in place is the tempting one and it destroys the original target,
which you may still want for logging. It also has to be done after splitting,
since writing a decoded `&` into the buffer before the split would create a
parameter boundary that was never sent. That is the same ordering point as
above, made sharper by the fact that C makes the mistake physically possible.

The other C-shaped trap is that `strtok` on `&` collapses runs, so `a=1&&b=2`
loses the empty parameter, and `a=1&` loses the trailing one. Whether that
matters depends on whether anything downstream counts parameters, which is
exactly the sort of coupling that is invisible until it breaks.

Next: form bodies, which are the same encoding arriving by a different route.
