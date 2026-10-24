//! title: "Project: Units of Measure, a Mismatch"
//! compile-fails
//! The `Quantity` type from this chapter, used to add metres to seconds.

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

pub fn main() void {
    const distance: Metres = .{ .value = 100 };
    const time: Seconds = .{ .value = 9.58 };
    const wrong = distance.add(time);
    std.debug.print("{d}\n", .{wrong.value});
}
