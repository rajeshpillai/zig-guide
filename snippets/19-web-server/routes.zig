//! title: Routing and Query Strings
//! All text after the `?`, and the dispatch table that ignores that text.

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
