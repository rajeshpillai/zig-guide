# Project: Units of Measure

> A number type that carries its unit. Metres times metres is an area, and metres plus seconds does not compile.

A program that calculates with physical values must keep the units correct. A value in metres plus a value in seconds has no meaning, but two `f64` values add without a complaint.

This project puts the unit into the type. The compiler then checks each calculation, and a wrong unit stops the build. At runtime, each value is one `f64` and nothing more.

The project uses these chapters:

- [Know What the Compiler Knows](https://www.ziglang.in/learn/metaprogramming/compiler-knows/), for a struct value as a `comptime` parameter.
- [Reject Bad Input with @compileError](https://www.ziglang.in/learn/metaprogramming/compile-error/), for the message.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`25-comptime.units`)*

## A unit is a list of powers

```zig
const Dim = struct {
    m: i8 = 0,
    s: i8 = 0,
    kg: i8 = 0,
};
```

Each physical unit in this program is a product of three base units. `Dim` keeps the power of each one:

- Metres is `.{ .m = 1 }`.
- Metres per second is `.{ .m = 1, .s = -1 }`.
- Newtons, the unit of force, is `.{ .kg = 1, .m = 1, .s = -2 }`.

To multiply two units, add their powers. To divide, subtract the powers. `Dim.mul` and `Dim.div` do this. They are usual functions, and the compiler runs them.

## A type for each unit

```zig
fn Quantity(comptime dim: Dim) type {
    return struct {
        value: f64,
        ...
    };
}

const Metres = Quantity(.{ .m = 1 });
const Seconds = Quantity(.{ .s = 1 });
```

A `comptime` parameter can be a struct value, not only a type. Each different `Dim` makes a different type. Each type has one field, thus the size of a `Quantity` is the size of an `f64`:

```
size of a Quantity: 8 bytes
```

## Multiply and divide

```zig
pub fn div(a: Self, b: anytype) Quantity(dim.div(@TypeOf(b).dim_value)) {
    return .{ .value = a.value / b.value };
}
```

The return type is a calculation. The compiler reads the `Dim` of `b`, subtracts it from the `Dim` of `a`, and calls `Quantity` with the result. The body only divides two numbers.

The program calculates the values for a 100 m sprint in 9.58 s, by a runner of 94 kg:

```
distance = 100 m
speed = 10.438413361169102 m/s
acceleration = 1.0896047349863363 m/s^2
force = 102.4228450887156 kg*m/s^2
area = 10000 m^2
```

Each unit name in the output comes from the type. `Dim.name` builds the text during compilation, with `++` and `comptimePrint`. Each `Quantity` type keeps its name in the constant `unit`.

## The same unit is the same type

```
area / distance = 100 m
area / distance is Metres: true
```

`area.div(distance)` calculates `.{ .m = 2 }` minus `.{ .m = 1 }`, and the result is `.{ .m = 1 }`. The compiler keeps one type for each set of comptime arguments. Thus `Quantity(.{ .m = 1 })` from this calculation is the same type as `Metres`. A function that takes `Metres` accepts the result.

## Add two values

```zig
pub fn add(a: Self, b: anytype) Self {
    const other = @TypeOf(b).dim_value;
    if (comptime !dim.eql(other)) {
        @compileError("cannot add " ++ Dim.name(other) ++ " to " ++ unit);
    }
    return .{ .value = a.value + b.value };
}
```

Addition needs the same unit on both sides. The check is comptime, thus it costs nothing at runtime. Add seconds to metres:

```zig
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
```

The compiler says:

```
error: cannot add s to m
```

*Compiled by CI, but not runnable in the browser sandbox. (`25-comptime.units-mismatch`)*

The message uses the unit names, not the type names. The `referenced by` list under the message names the line in `main` that called `add`.

## Limits of this design

- The program has three base units. To add a base unit such as amperes, add a field to `Dim`, and add it in `mul`, `div`, `eql` and `name`.
- A value in kilometres has the same `Dim` as a value in metres. This design checks the dimension, not the scale. A scale needs a second comptime value, for example a factor of 1000.
- `add` accepts any type with a `dim_value` declaration. A type from another library with the same declaration name also passes the check.

## Check yourself

What is the unit of `speed.mul(time)`, and which type is it?

`speed` is `.{ .m = 1, .s = -1 }` and `time` is `.{ .s = 1 }`. The product adds the powers: `.{ .m = 1, .s = 0 }`. That `Dim` is equal to `.{ .m = 1 }`, thus the result is the `Metres` type, and its name is `m`.
