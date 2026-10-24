//! title: Parse Strings at Compile Time
//! A route pattern becomes a struct type and a matcher, during compilation.

const std = @import("std");

fn segmentCount(comptime pattern: []const u8) usize {
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

// "/users/:user" becomes .{ "users", ":user" }.
fn segments(comptime pattern: []const u8) [segmentCount(pattern)][]const u8 {
    var result: [segmentCount(pattern)][]const u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    for (&result) |*segment| segment.* = it.next().?;
    return result;
}

fn paramCount(comptime pattern: []const u8) usize {
    var n: usize = 0;
    for (segments(pattern)) |segment| {
        if (segment[0] == ':') n += 1;
    }
    return n;
}

// The names after each ':', in order. A name that occurs two times
// stops the build.
fn paramNames(comptime pattern: []const u8) [paramCount(pattern)][]const u8 {
    var names: [paramCount(pattern)][]const u8 = undefined;
    var i: usize = 0;
    for (segments(pattern)) |segment| {
        if (segment[0] != ':') continue;
        const name = segment[1..];
        for (names[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, name)) {
                @compileError("route " ++ pattern ++ ": parameter '" ++ name ++ "' occurs two times");
            }
        }
        names[i] = name;
        i += 1;
    }
    return names;
}

fn Route(comptime pattern: []const u8) type {
    const parts = segments(pattern);
    const names = paramNames(pattern);
    return struct {
        // One `[]const u8` field for each parameter in the pattern.
        pub const Params = @Struct(.auto, null, &names, &@splat([]const u8), &@splat(.{}));

        pub fn match(path: []const u8) ?Params {
            var it = std.mem.tokenizeScalar(u8, path, '/');
            var params: Params = undefined;
            // One copy of the body for each segment of the pattern.
            inline for (parts) |part| {
                const got = it.next() orelse return null;
                if (part[0] == ':') {
                    @field(params, part[1..]) = got;
                } else if (!std.mem.eql(u8, got, part)) {
                    return null;
                }
            }
            if (it.next() != null) return null;
            return params;
        }
    };
}

const UserPost = Route("/users/:user/posts/:post");
const Health = Route("/health");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const fields = @typeInfo(UserPost.Params).@"struct".field_names;
    try out.print("UserPost.Params has {d} fields:", .{fields.len});
    inline for (fields) |name| try out.print(" {s}", .{name});
    try out.print("\n", .{});

    const paths = [_][]const u8{
        "/users/42/posts/7",
        "/users/tejas/posts/hello-world",
        "/users/42/posts",
        "/users/42/comments/7",
        "/users/42/posts/7/edit",
    };
    for (paths) |path| {
        if (UserPost.match(path)) |p| {
            // `p.user` and `p.post` are real fields. A wrong field name is a
            // compile error. A map gives `null` at runtime for a wrong key.
            try out.print("{s}: user={s} post={s}\n", .{ path, p.user, p.post });
        } else {
            try out.print("{s}: no match\n", .{path});
        }
    }

    try out.print("/health: {s}\n", .{if (Health.match("/health") != null) "match" else "no match"});
    try out.print("Health.Params has {d} fields\n", .{@typeInfo(Health.Params).@"struct".field_names.len});
}
