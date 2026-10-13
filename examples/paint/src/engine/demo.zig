//! A fixed drawing, made of the same calls a person's hand would make.
//!
//! It uses every tool, so its picture depends on every part of the engine.
//! The native tests draw it and compare a hash of the result with `hash`
//! below. The browser build draws it too, when the page asks, and compares
//! with the same number. If the two builds ever disagree by one pixel, one of
//! those checks fails.

const std = @import("std");
const Document = @import("document.zig").Document;
const Brush = @import("brush.zig").Brush;
const Point = @import("geometry.zig").Point;

/// The display hash after `draw` on a fresh 640 by 400, two-layer document.
/// If a change to the engine changes the picture on purpose, run the tests,
/// look at the new picture, and update this.
pub const hash: u32 = 0x3870db57;

/// Draw the demo. The points are computed with integer arithmetic only, so the
/// script itself cannot differ between machines.
pub fn draw(d: *Document) !void {
    // Bottom layer: a soft, wide wash, back and forth across the page.
    const wash: Brush = .{ .radius = 46, .hardness = 0.1, .flow = 0.12, .opacity = 0.7, .color = .{ 90, 150, 210 } };
    d.beginStroke(wash, .brush, .{ .x = 40, .y = 330 });
    var i: i32 = 0;
    while (i <= 44) : (i += 1) {
        d.moveStroke(.{
            .x = @floatFromInt(40 + i * 13),
            .y = @floatFromInt(330 - @rem(i * 29, 70)),
        });
    }
    d.endStroke();

    // Bottom layer: a flat nib held at 45 degrees, like a calligraphy pen.
    // Strokes along the nib come out thin, strokes across it come out wide.
    const nib: Brush = .{ .radius = 16, .hardness = 0.95, .flow = 1, .aspect = 0.2, .angle = -45, .spacing = 0.1, .color = .{ 25, 30, 45 } };
    d.beginStroke(nib, .brush, .{ .x = 70, .y = 150 });
    i = 0;
    while (i <= 64) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        d.moveStroke(.{ .x = 70 + t * 4, .y = 150 - 80 + (t - 32) * (t - 32) * 80 / 1024 });
    }
    d.endStroke();

    // Bottom layer: a ribbon. The tip turns with the stroke and lies across
    // it, and the stroke presses harder as it goes.
    const ribbon: Brush = .{ .radius = 14, .hardness = 0.8, .flow = 1, .aspect = 0.25, .angle = 90, .follow_direction = true, .pressure = 1, .spacing = 0.1, .color = .{ 160, 40, 90 } };
    d.beginStroke(ribbon, .brush, .{ .x = 360, .y = 120, .pressure = 0.1 });
    i = 0;
    while (i <= 60) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        d.moveStroke(.{ .x = 360 + t * 4, .y = 60 + @abs(t - 30) * 2, .pressure = 0.1 + t / 70 });
    }
    d.endStroke();

    // Bottom layer: a dry bristle brush. Separate hair tracks, broken where
    // the paper's grain is too low for the brush to reach.
    const dry: Brush = .{ .radius = 22, .bristles = 9, .contact = 0.55, .hardness = 0.8, .flow = 0.9, .spacing = 0.04, .follow = 0.5, .color = .{ 120, 70, 40 } };
    d.beginStroke(dry, .brush, .{ .x = 40, .y = 380 });
    i = 0;
    while (i <= 30) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        d.moveStroke(.{ .x = 40 + t * 10, .y = 380 - t * t / 30 });
    }
    d.endStroke();

    // Bottom layer: an oil brush dragged up through the wash and the nib's
    // stroke. It picks up their colours as it goes and runs dry towards the
    // end.
    const oil: Brush = .{ .radius = 18, .hardness = 0.7, .flow = 1, .spacing = 0.05, .follow = 0.5, .pickup = 0.12, .drain = 0.2, .color = .{ 200, 50, 40 } };
    d.beginStroke(oil, .brush, .{ .x = 170, .y = 340 });
    i = 0;
    while (i <= 28) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        d.moveStroke(.{ .x = 170 + t * 2, .y = 340 - t * 10 });
    }
    d.endStroke();

    // Top layer: a closed outline with a hard brush, then a fill inside it.
    // The fill stops at the outline.
    _ = d.setActiveLayer(1);
    const outline: Brush = .{ .radius = 3, .hardness = 1, .flow = 1, .color = .{ 40, 40, 40 } };
    const corners = [_]Point{
        .{ .x = 420, .y = 200 }, .{ .x = 560, .y = 180 }, .{ .x = 600, .y = 300 },
        .{ .x = 470, .y = 360 }, .{ .x = 400, .y = 290 }, .{ .x = 420, .y = 200 },
    };
    d.beginStroke(outline, .brush, corners[0]);
    for (corners[1..]) |c| d.moveStroke(c);
    d.endStroke();
    _ = try d.fillAt(500, 270, .{ 250, 200, 60 });

    // Top layer: scattered, jittered dabs from a fixed seed.
    const spray: Brush = .{ .radius = 7, .spacing = 1.2, .scatter = 3, .jitter = 0.6, .flow = 0.8, .seed = 2026, .color = .{ 230, 110, 20 } };
    d.beginStroke(spray, .brush, .{ .x = 60, .y = 240 });
    d.moveStroke(.{ .x = 380, .y = 250 });
    d.endStroke();

    // Top layer: erase a cut through the spray and the filled shape, so the
    // bottom layer shows through it.
    d.beginStroke(.{ .radius = 10, .hardness = 0.5, .flow = 1 }, .eraser, .{ .x = 200, .y = 380 });
    d.moveStroke(.{ .x = 620, .y = 160 });
    d.endStroke();

    // Undo the cut and do it again, so history is part of the picture.
    _ = d.undo();
    _ = d.redo();
    _ = d.render();
}

test "the demo draws the same picture it always has" {
    var d = try Document.init(std.testing.allocator, 640, 400, 2, 16 << 20);
    defer d.deinit();
    try draw(&d);
    try std.testing.expectEqual(hash, d.displayHash());
}
