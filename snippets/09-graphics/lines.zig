//! title: Lines Without Floats
//! Bresenham's algorithm: one add and one compare per pixel, integers only.

const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// The error term `err` tracks twice the distance from the ideal line to the
/// pixel centre, scaled so it stays an integer. Each step it decides whether
/// the minor axis has drifted far enough to advance too.
///
/// Written in the symmetric form: `dy` is kept negative so both axes are
/// handled by the same two ifs, with no separate case for steep lines and no
/// swapping of endpoints.
fn drawLine(x0: i32, y0: i32, x1: i32, y1: i32, color: u32) usize {
    var x = x0;
    var y = y0;

    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;

    var err = dx + dy;
    var drawn: usize = 0;

    while (true) {
        canvas.putPixel(&pixels, x, y, color);
        drawn += 1;
        if (x == x1 and y == y1) break;

        const e2 = 2 * err;
        // Two independent tests, not an if/else: on a perfect diagonal both
        // fire and the line steps in both axes at once.
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }

    return drawn;
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.fill(&pixels, canvas.rgb(0, 0, 40));

    const cx: i32 = @intCast(canvas.width / 2);
    const cy: i32 = @intCast(canvas.height / 2);
    const w: i32 = @intCast(canvas.width);
    const h: i32 = @intCast(canvas.height);

    // A fan out to evenly spaced points along the border. Every slope from
    // near-horizontal to near-vertical goes through the same code path.
    var i: i32 = 0;
    while (i < 16) : (i += 1) {
        const t = @divTrunc(i * (w - 1), 16);
        _ = drawLine(cx, cy, t, 0, canvas.rgb(255, 200, 60));
        _ = drawLine(cx, cy, w - 1 - t, h - 1, canvas.rgb(120, 200, 255));
    }

    // A border, drawn as four lines, to show the endpoints land exactly.
    _ = drawLine(0, 0, w - 1, 0, canvas.rgb(255, 255, 255));
    _ = drawLine(w - 1, 0, w - 1, h - 1, canvas.rgb(255, 255, 255));
    _ = drawLine(w - 1, h - 1, 0, h - 1, canvas.rgb(255, 255, 255));
    _ = drawLine(0, h - 1, 0, 0, canvas.rgb(255, 255, 255));

    try canvas.dump(out, &pixels);

    // A line lights up max(|dx|, |dy|) + 1 pixels: exactly one per step of the
    // major axis, whatever the slope.
    const probe = canvas.rgb(0, 0, 40);
    try out.print("\n(0,0)->(40,10): {d} pixels\n", .{drawLine(0, 0, 40, 10, probe)});
    try out.print("(0,0)->(10,30): {d} pixels\n", .{drawLine(0, 0, 10, 30, probe)});
    try out.print("(0,0)->(20,20): {d} pixels\n", .{drawLine(0, 0, 20, 20, probe)});
    try out.print("(40,10)->(0,0): {d} pixels (same line, drawn backwards)\n", .{
        drawLine(40, 10, 0, 0, probe),
    });

    try out.flush();
}
