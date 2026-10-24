//! title: A Route With a Repeated Parameter
//! compile-fails
//! The route parser from this chapter, given `:id` two times.

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

const Friend = Route("/users/:id/friends/:id");

pub fn main() void {
    if (Friend.match("/users/1/friends/2")) |p| std.debug.print("{s}\n", .{p.id});
}
