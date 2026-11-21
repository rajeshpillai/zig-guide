# Routes and Query Strings

> All text after the question mark, and the dispatch table that ignores that text.

A request target is two parts with a `?` between them. Before the `?` is a
path. The path decides *what runs*. After the `?` is a query string. The query
string is input to the code that runs.

The two parts have different parsing
rules and different uses. If a program uses the two parts as one string, many
bugs occur.

Routing is the first part, and routing is simpler than many people expect: a
comparison with a table. A framework adds shorter ways to write the table. The
decision that the framework makes is the same.

## The program

```zig
const std = @import("std");
const path_util = @import("static.zig");

pub const Param = struct { name: []const u8, value: []const u8 };

/// In a query string, `+` means a space. In a path, `+` does not mean a space.
/// Thus this function is separate from the path decoder. It is not a flag.
fn decodeQueryValue(dest: []u8, src: []const u8) ![]u8 {
    var swapped: [256]u8 = undefined;
    if (src.len > swapped.len) return error.TooLong;
    for (src, 0..) |c, i| swapped[i] = if (c == '+') ' ' else c;
    return path_util.percentDecode(dest, swapped[0..src.len]);
}

/// Parse `a=1&b=hello+world&flag` into pairs. A key with no `=` gets an empty
/// value. HTML checkboxes and flags come in this form.
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
    // The last value wins. Real servers do not agree about this rule, and an
    // attacker can use the disagreement. Suppose a proxy uses the first `user`
    // and the origin uses the last. Then one request has two meanings.
    var result: ?[]const u8 = null;
    for (params) |p| {
        if (std.mem.eql(u8, p.name, name)) result = p.value;
    }
    return result;
}

const Route = struct { method: []const u8, path: []const u8 };

/// Routing is a comparison. A framework adds more parts on top of this
/// comparison. The table gets patterns, then a compiler changes the patterns
/// into a tree. The decision does not change.
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

## What the program did

**`hello+world` became `hello world`, and `%26` became a literal `&`.** Both
results are important.

In a query string, a plus sign means a space. This rule applies only in the
query string, not in the path. Thus the decoder is a separate function, not a
flag.

The program decoded `%26` *after* the split on `&`. Thus a value that contains
an ampersand stayed one value, and did not become two parameters. Decode after
you split on the structural characters. That order is the opposite of the order
in the last chapter. The reason is the same: decode at the point where the
result is data and not structure.

**`empty=` and `flag` both gave an empty value.** `empty=` is a parameter with
an empty value. `flag` has no `=`. This parser stores both values as `""`.

This choice has a cost: you cannot know the difference between a field that the user
cleared and a key that had no value. An optional value keeps the difference. A
browser always sends the first form. Thus keys without a value come from
hand-written URLs and from APIs.

**`q` occurred two times, and the last value won.** Servers do not agree about
this rule. Some servers use the first value, some use the last value, and some
make a list.

An attacker can use this disagreement. Suppose a caching proxy uses
the first value and the origin server uses the last value. Then one request has
two different meanings for two systems. Parameter-pollution bugs come from this
difference. Select a rule, and know which rule you selected.

**Routing ignored the query.** `GET /search?q=x` matched the `/search` route.
The path decides the handler, and the query is the input to the handler. Also,
`GET /submit` gave a 404 and `POST /submit` matched. The method is part of the
route. It is not a detail for a later check.

## Check yourself

The routing table is a linear scan over three entries. When is that shape
incorrect?

The answer: later than you think, and the reason for a change is usually not
speed. A linear scan of a few dozen exact-match routes costs almost nothing. The
syscall that delivered the request costs much more.

*Patterns* make a different structure necessary. When a route contains a
placeholder, the comparison is not equality. Then a server must match a hundred
patterns against each request. The server has two choices:

- Compile the patterns into a tree that walks the path one time.
- Accept a hundred partial matches for each request.

A production router is that tree. The tree exists because of patterns, not
because of scale.

## If you know C

The parsing is the same, and the difference is the memory. The C version has
two choices:

- Decode in place. This works because a decoded string is never longer than its
  encoded form.
- Allocate memory for each value. Then the code must free each value.

Many programmers decode in place, but that choice destroys the original target.
You possibly need that target for [logging](https://www.ziglang.in/learn/standard-library/logging/).
Also, the code must decode after the split. If the code writes a decoded `&`
into the buffer before the split, the code makes a parameter boundary that the
client did not send. This is the same point about order as above. In C, the
point is more important, because C lets you write the decoded bytes into the
buffer that you still parse.

Another problem in C: `strtok` on `&` joins a sequence of delimiters into one.
Thus `a=1&&b=2` loses the empty parameter, and `a=1&` loses the last one. This
loss is important only if code after the parser counts parameters. You do not
see that type of dependency until something breaks.

Next: form bodies. A form body uses the same encoding, but it comes by a
different path.
