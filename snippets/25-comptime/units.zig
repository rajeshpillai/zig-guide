//! title: "Project: Units of Measure"
//! A number that carries its unit in its type. The compiler checks the units.

const std = @import("std");

// The power of each base unit. Metres per second squared is
// .{ .m = 1, .s = -2 }.
const Dim = struct {
    m: i8 = 0,
    s: i8 = 0,
    kg: i8 = 0,

    fn mul(a: Dim, b: Dim) Dim {
        return .{ .m = a.m + b.m, .s = a.s + b.s, .kg = a.kg + b.kg };
    }

    fn div(a: Dim, b: Dim) Dim {
        return .{ .m = a.m - b.m, .s = a.s - b.s, .kg = a.kg - b.kg };
    }

    fn eql(a: Dim, b: Dim) bool {
        return a.m == b.m and a.s == b.s and a.kg == b.kg;
    }

    // "kg*m/s^2". The compiler makes this text one time for each Dim.
    fn name(comptime d: Dim) []const u8 {
        comptime var top: []const u8 = "";
        comptime var bottom: []const u8 = "";
        inline for (.{ "kg", "m", "s" }) |unit| {
            const p = @field(d, unit);
            const text = if (@abs(p) == 1) unit else std.fmt.comptimePrint("{s}^{d}", .{ unit, @abs(p) });
            if (p > 0) top = top ++ (if (top.len == 0) "" else "*") ++ text;
            if (p < 0) bottom = bottom ++ (if (bottom.len == 0) "" else "*") ++ text;
        }
        if (top.len == 0) top = "1";
        return if (bottom.len == 0) top else top ++ "/" ++ bottom;
    }
};

fn Quantity(comptime dim: Dim) type {
    return struct {
        value: f64,

        const Self = @This();
        pub const unit = dim.name();

        pub fn add(a: Self, b: anytype) Self {
            const other = @TypeOf(b).dim_value;
            if (comptime !dim.eql(other)) {
                @compileError("cannot add " ++ Dim.name(other) ++ " to " ++ unit);
            }
            return .{ .value = a.value + b.value };
        }

        pub fn mul(a: Self, b: anytype) Quantity(dim.mul(@TypeOf(b).dim_value)) {
            return .{ .value = a.value * b.value };
        }

        pub fn div(a: Self, b: anytype) Quantity(dim.div(@TypeOf(b).dim_value)) {
            return .{ .value = a.value / b.value };
        }

        pub const dim_value = dim;
    };
}

const Metres = Quantity(.{ .m = 1 });
const Seconds = Quantity(.{ .s = 1 });
const Kilograms = Quantity(.{ .kg = 1 });

fn show(out: *std.Io.Writer, label: []const u8, q: anytype) !void {
    try out.print("{s} = {d} {s}\n", .{ label, q.value, @TypeOf(q).unit });
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const distance: Metres = .{ .value = 100 };
    const time: Seconds = .{ .value = 9.58 };
    const mass: Kilograms = .{ .value = 94 };

    const speed = distance.div(time);
    const accel = speed.div(time);
    const force = mass.mul(accel);
    const area = distance.mul(distance);

    try show(out, "distance", distance);
    try show(out, "speed", speed);
    try show(out, "acceleration", accel);
    try show(out, "force", force);
    try show(out, "area", area);
    try show(out, "distance + distance", distance.add(distance));
    try show(out, "area / distance", area.div(distance));

    // The same units give the same type, whatever path made them.
    try out.print("area / distance is Metres: {}\n", .{@TypeOf(area.div(distance)) == Metres});
    try out.print("size of a Quantity: {d} bytes\n", .{@sizeOf(@TypeOf(force))});
}
