//! title: Dispatch with Comptime
//! One handler for each command, connected at compile time.

const std = @import("std");

const Op = enum { add, sub, mul, neg };

// One function for each tag of `Op`, with the same name as the tag.
const Handlers = struct {
    pub fn add(a: i64, b: i64) i64 {
        return a + b;
    }
    pub fn sub(a: i64, b: i64) i64 {
        return a - b;
    }
    pub fn mul(a: i64, b: i64) i64 {
        return a * b;
    }
    pub fn neg(a: i64, _: i64) i64 {
        return -a;
    }
};

// 1. A switch with `inline else`. The compiler makes one branch for each
//    tag, and each branch calls its handler directly.
fn runSwitch(op: Op, a: i64, b: i64) i64 {
    return switch (op) {
        inline else => |tag| @field(Handlers, @tagName(tag))(a, b),
    };
}

// 2. A table of function pointers, built during compilation.
//    The program indexes it with the tag at runtime.
const Handler = *const fn (i64, i64) i64;
const table: std.EnumArray(Op, Handler) = blk: {
    var t: std.EnumArray(Op, Handler) = undefined;
    for (std.enums.values(Op)) |tag| {
        t.set(tag, @field(Handlers, @tagName(tag)));
    }
    break :blk t;
};

fn runTable(op: Op, a: i64, b: i64) i64 {
    return table.get(op)(a, b);
}

// 3. Data for each tag, in a table that the compiler checks: an
//    `EnumArray` must have a value for each tag.
const symbols: std.EnumArray(Op, []const u8) = .init(.{
    .add = "+",
    .sub = "-",
    .mul = "*",
    .neg = "neg",
});

const script =
    \\add 2 3
    \\mul 4 5
    \\neg 7 0
    \\sub 10 4
    \\div 8 2
;

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const name = words.next() orelse continue;
        const a = try std.fmt.parseInt(i64, words.next().?, 10);
        const b = try std.fmt.parseInt(i64, words.next().?, 10);

        // `stringToEnum` compares the text with each tag name. The
        // compiler makes the list of names from `Op`.
        const op = std.meta.stringToEnum(Op, name) orelse {
            try out.print("{s}: unknown command\n", .{name});
            continue;
        };
        const by_switch = runSwitch(op, a, b);
        const by_table = runTable(op, a, b);
        try out.print("{s} {d} {d} = {d} (switch), {d} (table), symbol {s}\n", .{
            name, a, b, by_switch, by_table, symbols.get(op),
        });
    }
}
