//! title: Rasterizing a Triangle
//! Edge functions: one signed area per edge decides inside from outside, and
//! the same three numbers interpolate colour across the face for free.

const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

const Point = struct { x: i32, y: i32 };

/// Twice the signed area of triangle (a, b, p). Positive on one side of the
/// line ab, negative on the other, zero exactly on it. That sign is the whole
/// inside test, and the magnitude is the barycentric weight.
fn edge(a: Point, b: Point, p: Point) i32 {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}

fn fillTriangle(a: Point, b: Point, c: Point, ca: u32, cb: u32, cc: u32) void {
    // Wind consistently, so "inside" is always the non-negative side. Without
    // this a triangle given the other way round disappears.
    var v0 = a;
    var v1 = b;
    const v2 = c;
    var col0 = ca;
    var col1 = cb;
    const col2 = cc;
    const area = edge(v0, v1, v2);
    if (area < 0) {
        std.mem.swap(Point, &v0, &v1);
        std.mem.swap(u32, &col0, &col1);
    }
    const total = edge(v0, v1, v2);
    if (total == 0) return; // degenerate: three collinear points have no face

    const min_x = @min(v0.x, @min(v1.x, v2.x));
    const max_x = @max(v0.x, @max(v1.x, v2.x));
    const min_y = @min(v0.y, @min(v1.y, v2.y));
    const max_y = @max(v0.y, @max(v1.y, v2.y));

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const p = Point{ .x = x, .y = y };
            const w0 = edge(v1, v2, p);
            const w1 = edge(v2, v0, p);
            const w2 = edge(v0, v1, p);
            if (w0 < 0 or w1 < 0 or w2 < 0) continue;

            // The three edge values, divided by the total, are the barycentric
            // coordinates: they sum to 1 and weight each vertex's colour by
            // how close the pixel is to it.
            const g0 = canvas.channels(col0);
            const g1 = canvas.channels(col1);
            const g2 = canvas.channels(col2);
            canvas.putPixel(&pixels, x, y, canvas.rgb(
                mix(w0, w1, w2, g0.r, g1.r, g2.r, total),
                mix(w0, w1, w2, g0.g, g1.g, g2.g, total),
                mix(w0, w1, w2, g0.b, g1.b, g2.b, total),
            ));
        }
    }
}

fn mix(w0: i32, w1: i32, w2: i32, c0: u8, c1: u8, c2: u8, total: i32) u8 {
    const sum = w0 * @as(i32, c0) + w1 * @as(i32, c1) + w2 * @as(i32, c2);
    return @intCast(@divTrunc(sum, total));
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.fill(&pixels, canvas.rgb(0, 0, 30));

    // Gouraud shading in three lines: one colour per vertex, interpolated.
    fillTriangle(
        .{ .x = 4, .y = 28 },
        .{ .x = 30, .y = 2 },
        .{ .x = 40, .y = 26 },
        canvas.rgb(30, 30, 60),
        canvas.rgb(255, 255, 255),
        canvas.rgb(120, 120, 160),
    );

    // Wound the other way round, and drawn flat. It still appears, because
    // fillTriangle normalises the winding.
    fillTriangle(
        .{ .x = 62, .y = 4 },
        .{ .x = 44, .y = 20 },
        .{ .x = 62, .y = 30 },
        canvas.rgb(255, 200, 60),
        canvas.rgb(255, 200, 60),
        canvas.rgb(255, 200, 60),
    );

    try canvas.dump(out, &pixels);

    const a = Point{ .x = 0, .y = 0 };
    const b = Point{ .x = 10, .y = 0 };
    try out.print("\nedge value below the line ab: {d}\n", .{edge(a, b, .{ .x = 5, .y = 4 })});
    try out.print("edge value on the line ab:    {d}\n", .{edge(a, b, .{ .x = 5, .y = 0 })});
    try out.print("edge value above the line ab: {d}\n", .{edge(a, b, .{ .x = 5, .y = -4 })});

    try out.flush();
}
