//! title: Know the Limits
//! What comptime code cannot do, and what to use instead.

const std = @import("std");

// Comptime code cannot open a file. `@embedFile` is the exception: the
// compiler reads the file and the bytes become a string constant.
const colors_txt = @embedFile("colors.txt");

// `parseColors` calls this function in its return type, before the quota
// line in its own body runs. Thus this function sets its own quota.
fn lineCount(comptime text: []const u8) usize {
    @setEvalBranchQuota(100_000);
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |_| n += 1;
    return n;
}

const Entry = struct { []const u8, u24 };

// Parse "name=rrggbb" lines into key and value pairs. There is no runtime
// allocator at comptime, thus the result is an array with a size that
// the compiler calculates.
fn parseColors(comptime text: []const u8) [lineCount(text)]Entry {
    @setEvalBranchQuota(100_000);
    var entries: [lineCount(text)]Entry = undefined;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    for (&entries) |*entry| {
        const line = it.next().?;
        const eq = std.mem.findScalar(u8, line, '=') orelse
            @compileError("colors.txt: no '=' in line: " ++ line);
        const value = std.fmt.parseInt(u24, line[eq + 1 ..], 16) catch
            @compileError("colors.txt: bad hex in line: " ++ line);
        entry.* = .{ line[0..eq], value };
    }
    return entries;
}

const colors = std.StaticStringMap(u24).initComptime(parseColors(colors_txt));

// Strings join with `++` during compilation. The result has a length
// that the compiler knows.
const names = blk: {
    var joined: []const u8 = "";
    for (parseColors(colors_txt), 0..) |entry, i| {
        joined = joined ++ (if (i == 0) "" else ", ") ++ entry[0];
    }
    break :blk joined;
};

fn List(comptime T: type) type {
    return struct { items: []T };
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("1. colors.txt: {d} bytes, {d} colors\n", .{ colors_txt.len, colors.keys().len });
    for ([_][]const u8{ "saffron", "blue", "purple" }) |name| {
        if (colors.get(name)) |rgb| {
            try out.print("   {s} = #{x:0>6}\n", .{ name, rgb });
        } else {
            try out.print("   {s}: not in the file\n", .{name});
        }
    }

    try out.print("2. names: {s} ({d} bytes)\n", .{ names, names.len });

    // The compiler keeps one result for each set of comptime arguments.
    // The same arguments give the same type. New arguments give a new copy.
    try out.print("3. List(u8) == List(u8): {}\n", .{List(u8) == List(u8)});
    try out.print("   List(u8) == List(u16): {}\n", .{List(u8) == List(u16)});
}
