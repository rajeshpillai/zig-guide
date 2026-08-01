//! title: Form Bodies
//! The same encoding as a query string, arriving somewhere it can be much larger.

const std = @import("std");
const routes = @import("routes.zig");

pub const Field = routes.Param;

/// A urlencoded body is a query string without the `?`. That is not a
/// coincidence: HTML forms were specified to produce one encoding, and where
/// it travels is the method's business rather than the format's.
pub fn parseForm(body: []const u8, dest: []u8, out: []Field) ![]Field {
    var joined: [1024]u8 = undefined;
    if (body.len + 1 > joined.len) return error.TooLong;
    joined[0] = '?';
    @memcpy(joined[1..][0..body.len], body);
    return routes.parseQuery(joined[0 .. body.len + 1], dest, out);
}

/// How many bytes of body to read. A server that trusts this number without a
/// ceiling has handed the client control of its memory.
pub fn bodyLength(declared: ?[]const u8, limit: usize) !usize {
    const text = declared orelse return 0;
    const n = std.fmt.parseInt(usize, text, 10) catch return error.Malformed;
    if (n > limit) return error.TooLarge;
    return n;
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var scratch: [512]u8 = undefined;
    var fields: [8]Field = undefined;

    const bodies = [_][]const u8{
        "name=Ada+Lovelace&role=engineer",
        "note=100%25+done&tags=a%26b",
        "consent=on&newsletter=",
        "",
    };

    for (bodies) |body| {
        const parsed = try parseForm(body, &scratch, &fields);
        try out.print("\"{s}\"\n", .{body});
        for (parsed) |f| try out.print("  {s} = \"{s}\"\n", .{ f.name, f.value });
        if (parsed.len == 0) try out.writeAll("  (no fields)\n");
    }

    try out.writeAll("\nContent-Length, with a ceiling of 1 MB\n");
    for ([_]?[]const u8{ "13", null, "99999999", "twelve" }) |declared| {
        const label = declared orelse "(absent)";
        if (bodyLength(declared, 1 << 20)) |n| {
            try out.print("  {s: <10} -> read {d} bytes\n", .{ label, n });
        } else |err| {
            try out.print("  {s: <10} -> {t}\n", .{ label, err });
        }
    }

    try out.flush();
}
