//! A watercolour experiment: water and pigment moving on a grid of paper.
//!
//! The paper is divided into cells, and each cell keeps three numbers:
//!
//! - `water`, how wet the paper is: 0 is dry and 1 is fully wet
//! - `mobile`, pigment still floating in the water, which can move
//! - `deposited`, pigment that has settled into the paper, which cannot
//!
//! Each step, water spreads to neighbouring cells, floating pigment spreads
//! with it, the paper dries a little, and some floating pigment settles.
//!
//! This is a simple model chosen to be understood, not a fluid simulation.
//! It has no water velocity and one pigment colour.
//!
//! `step` always advances 1/30 of a second and takes no time argument, so a
//! run is the same on every machine. The front end decides how many steps a
//! frame gets.

const std = @import("std");
const Random = @import("random.zig").Random;
const Rgba = @import("pixel.zig").Rgba;

/// The length of one step, in seconds.
pub const dt: f32 = 1.0 / 30.0;

pub const Watercolor = struct {
    width: u32,
    height: u32,
    water: []f32,
    mobile: []f32,
    deposited: []f32,
    /// How quickly pigment settles in each cell, from 0.6 to 1.4 times the
    /// base rate. Made once, so the paper's grain stays where it is.
    grain: []f32,
    /// The second buffer for spreading. A step reads one buffer and writes
    /// the other, then swaps them.
    next: []f32,

    /// How fast water and pigment spread. At most 0.25: see `spread`.
    spread_rate: f32 = 0.18,
    /// How much of its wetness the paper keeps after one second.
    retention: f32 = 0.8,
    /// How fast floating pigment settles, per second.
    settle_rate: f32 = 0.8,
    /// The pigment's colour.
    color: [3]u8 = .{ 40, 90, 160 },

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, seed: u32) !Watercolor {
        const n = @as(usize, width) * height;
        const all = try gpa.alloc(f32, n * 5);
        @memset(all, 0);
        const w: Watercolor = .{
            .width = width,
            .height = height,
            .water = all[0..n],
            .mobile = all[n .. 2 * n],
            .deposited = all[2 * n .. 3 * n],
            .grain = all[3 * n .. 4 * n],
            .next = all[4 * n .. 5 * n],
        };
        var random: Random = .init(seed);
        for (w.grain) |*g| g.* = 0.6 + 0.8 * random.next();
        return w;
    }

    pub fn deinit(w: *Watercolor, gpa: std.mem.Allocator) void {
        // The five fields are one allocation, starting at `water`.
        gpa.free(w.water.ptr[0 .. w.water.len * 5]);
    }

    pub fn index(w: Watercolor, x: u32, y: u32) usize {
        return @as(usize, y) * w.width + x;
    }

    /// Wet a disc of cells and drop pigment into it.
    pub fn drop(w: *Watercolor, cx: f32, cy: f32, radius: f32, water: f32, pigment: f32) void {
        var y: u32 = 0;
        while (y < w.height) : (y += 1) {
            var x: u32 = 0;
            while (x < w.width) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                if (dx * dx + dy * dy > radius * radius) continue;
                const i = w.index(x, y);
                w.water[i] = @min(w.water[i] + water, 1);
                w.mobile[i] += pigment;
            }
        }
    }

    pub fn clear(w: *Watercolor) void {
        @memset(w.water, 0);
        @memset(w.mobile, 0);
        @memset(w.deposited, 0);
    }

    /// One step of 1/30 of a second.
    pub fn step(w: *Watercolor) void {
        // Water spreads to drier neighbours. Pigment spreads too, but only as
        // far as the paper is wet: between two cells, it moves in proportion
        // to the wetness of the drier one.
        w.spread(w.water, null, .forward);
        w.spread(w.mobile, w.water, .forward);

        // Drying. `retention` is what is left after a whole second, so one
        // step of `dt` seconds keeps `retention` to the power `dt`. Thirty
        // steps then keep exactly `retention`, at any step size.
        const keep = std.math.pow(f32, w.retention, dt);
        for (w.water) |*v| v.* *= keep;

        // Settling. A share of the floating pigment moves into the paper.
        // Moved, not removed: the total pigment does not change.
        for (w.mobile, w.deposited, w.grain) |*m, *d, g| {
            const share = 1.0 - @exp(-w.settle_rate * g * dt);
            const moved = m.* * share;
            m.* -= moved;
            d.* += moved;
        }
    }

    pub const Order = enum { forward, reverse };

    /// Spread `field` between neighbouring cells, reading the old values and
    /// writing the new ones to a second buffer.
    ///
    /// Each cell moves towards its neighbours by `spread_rate` times each
    /// difference. A cell with four neighbours keeps `1 - 4 * rate` of its
    /// own value, so `rate` must be at most 0.25 or that weight goes negative
    /// and values can overshoot, flip sign and grow without limit.
    ///
    /// `order` only exists to show that it does not matter. Because no cell
    /// reads a value written in the same step, scanning backwards gives the
    /// same result.
    pub fn spread(w: *Watercolor, field: []f32, wet: ?[]const f32, order: Order) void {
        const n = field.len;
        for (0..n) |k| {
            const i = if (order == .forward) k else n - 1 - k;
            const x: u32 = @intCast(i % w.width);
            const y: u32 = @intCast(i / w.width);
            var change: f32 = 0;
            for (w.neighbours(x, y)) |maybe| {
                const j = maybe orelse continue;
                var amount = w.spread_rate;
                if (wet) |water| amount *= @min(@min(water[i], water[j]), 1);
                change += amount * (field[j] - field[i]);
            }
            w.next[i] = field[i] + change;
        }
        @memcpy(field, w.next);
    }

    /// Left, right, above and below, or null where that neighbour would be
    /// off the paper. Checking the coordinate first stops a cell on the left
    /// edge from reaching the right edge of the row above.
    pub fn neighbours(w: Watercolor, x: u32, y: u32) [4]?usize {
        return .{
            if (x > 0) w.index(x - 1, y) else null,
            if (x + 1 < w.width) w.index(x + 1, y) else null,
            if (y > 0) w.index(x, y - 1) else null,
            if (y + 1 < w.height) w.index(x, y + 1) else null,
        };
    }

    pub fn total(field: []const f32) f64 {
        var sum: f64 = 0;
        for (field) |v| sum += v;
        return sum;
    }

    /// Draw the grid, one pixel per cell: white paper that turns pale blue
    /// where it is wet, and the pigment laid over it.
    pub fn render(w: Watercolor, out: []Rgba) void {
        const wet_paper = [3]f32{ 225, 235, 248 };
        for (out, w.water, w.mobile, w.deposited) |*px, water, m, d| {
            const wet = std.math.clamp(water, 0, 1);
            const pigment = std.math.clamp(m + d, 0, 1);
            var c: [3]u8 = undefined;
            for (&c, wet_paper, w.color) |*o, tint, p| {
                const paper = 255.0 + (tint - 255.0) * wet;
                o.* = @intFromFloat(@round(paper + (@as(f32, @floatFromInt(p)) - paper) * pigment));
            }
            px.* = .{ .r = c[0], .g = c[1], .b = c[2], .a = 255 };
        }
    }
};

const testing = std.testing;

fn lab(width: u32, height: u32) !Watercolor {
    return Watercolor.init(testing.allocator, width, height, 1);
}

test "the cell (3, 2) on an 80-wide grid is number 163" {
    var w = try lab(80, 50);
    defer w.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 163), w.index(3, 2));
    try testing.expectEqual(@as(usize, 4000), w.water.len);
}

test "a middle cell has four neighbours, a corner two, and an edge does not wrap" {
    var w = try lab(80, 50);
    defer w.deinit(testing.allocator);
    var count: usize = 0;
    for (w.neighbours(10, 10)) |n| count += @intFromBool(n != null);
    try testing.expectEqual(@as(usize, 4), count);
    count = 0;
    for (w.neighbours(0, 0)) |n| count += @intFromBool(n != null);
    try testing.expectEqual(@as(usize, 2), count);
    // The left neighbour of (0, 5) would be index 399, the end of row 4.
    try testing.expectEqual(@as(?usize, null), w.neighbours(0, 5)[0]);
}

test "a wet centre at rate 0.18 keeps 0.28 and gives each neighbour 0.18" {
    var w = try lab(5, 5);
    defer w.deinit(testing.allocator);
    w.water[w.index(2, 2)] = 1;
    w.spread(w.water, null, .forward);
    try testing.expectApproxEqAbs(@as(f32, 0.28), w.water[w.index(2, 2)], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.18), w.water[w.index(1, 2)], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.18), w.water[w.index(2, 3)], 1e-6);
}

test "reading the old grid makes the scan order irrelevant" {
    var a = try lab(20, 12);
    defer a.deinit(testing.allocator);
    var b = try lab(20, 12);
    defer b.deinit(testing.allocator);
    a.drop(6, 6, 3, 1, 0);
    b.drop(6, 6, 3, 1, 0);
    for (0..10) |_| {
        a.spread(a.water, null, .forward);
        b.spread(b.water, null, .reverse);
    }
    try testing.expectEqualSlices(f32, a.water, b.water);
}

test "spreading keeps the total and never goes negative" {
    var w = try lab(30, 20);
    defer w.deinit(testing.allocator);
    w.retention = 1; // no drying, so all the water must still be there
    w.drop(5, 5, 4, 1, 0.5);
    const water = Watercolor.total(w.water);
    for (0..300) |_| w.step();
    try testing.expectApproxEqRel(water, Watercolor.total(w.water), 1e-4);
    for (w.water) |v| try testing.expect(v >= 0);
    for (w.mobile) |v| try testing.expect(v >= 0);
}

test "a rate above 0.25 is unstable" {
    var w = try lab(9, 9);
    defer w.deinit(testing.allocator);
    w.spread_rate = 0.4;
    w.water[w.index(4, 4)] = 1;
    w.spread(w.water, null, .forward);
    // The centre keeps 1 - 4 * 0.4 = -0.6 of itself: negative water.
    try testing.expect(w.water[w.index(4, 4)] < 0);
}

test "drying at 0.8 a second leaves 0.8 after one second and 0.64 after two" {
    var w = try lab(3, 3);
    defer w.deinit(testing.allocator);
    @memset(w.water, 1);
    for (0..30) |_| w.step();
    try testing.expectApproxEqAbs(@as(f32, 0.8), w.water[0], 1e-4);
    for (0..30) |_| w.step();
    try testing.expectApproxEqAbs(@as(f32, 0.64), w.water[0], 1e-4);
}

test "settling moves pigment into the paper and loses none" {
    var w = try lab(30, 20);
    defer w.deinit(testing.allocator);
    w.drop(15, 10, 5, 1, 0.6);
    const pigment = Watercolor.total(w.mobile);
    for (0..600) |_| w.step();
    const now = Watercolor.total(w.mobile) + Watercolor.total(w.deposited);
    try testing.expectApproxEqRel(pigment, now, 1e-4);
    // After twenty seconds nearly all of it has settled.
    try testing.expect(Watercolor.total(w.deposited) > 0.95 * pigment);
}

test "one step at rate 0.8 settles 2.63% of the floating pigment" {
    var w = try lab(1, 1);
    defer w.deinit(testing.allocator);
    w.grain[0] = 1;
    w.mobile[0] = 0.6;
    w.step();
    try testing.expectApproxEqAbs(@as(f32, 0.0158), w.deposited[0], 1e-4);
}

/// A fixed run: three drops, then three seconds. The native test and the
/// browser build's self-test both compare its picture with `demo_hash`, so
/// the two builds cannot drift apart on `pow` or `exp`.
pub fn demo(w: *Watercolor) void {
    w.drop(20, 20, 9, 1, 0.9);
    for (0..20) |_| w.step();
    w.drop(34, 26, 7, 0.8, 0.6);
    for (0..30) |_| w.step();
    w.drop(52, 18, 5, 1, 0);
    w.drop(58, 30, 6, 0.6, 0.8);
    for (0..40) |_| w.step();
}

pub const demo_hash: u32 = 0x17ca0480;

pub fn hash(w: Watercolor, scratch: []Rgba) u32 {
    w.render(scratch);
    var h = std.hash.Fnv1a_32.init();
    for (scratch) |p| h.update(&.{ p.r, p.g, p.b });
    return h.final();
}

test "the demo run draws the same picture it always has" {
    var w = try Watercolor.init(testing.allocator, 80, 50, 1);
    defer w.deinit(testing.allocator);
    demo(&w);
    var pixels: [80 * 50]Rgba = undefined;
    try testing.expectEqual(demo_hash, hash(w, &pixels));
}
