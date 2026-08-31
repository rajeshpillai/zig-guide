//! Everything that touches raylib.
//!
//! Reads the world, draws it, and never writes to it. The simulation works in a
//! fixed 360x640 field; `View` maps that onto whatever the window happens to
//! be, letterboxed, so the visible playfield is identical at every window size.
//! A game that gave a wider window more warning of oncoming blocks would be a
//! game where resizing is a strategy.

const std = @import("std");
const rl = @import("rl");
const sim = @import("sim");
const palette = @import("palette.zig");
const particles = @import("particles.zig");

const config = sim.config;

fn color(c: palette.Color) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// Field units to screen pixels.
pub const View = struct {
    scale: f32,
    origin_x: f32,
    origin_y: f32,
    shake_x: f32 = 0,
    shake_y: f32 = 0,

    pub fn init(screen_w: f32, screen_h: f32) View {
        const scale = @min(screen_w / config.field_w, screen_h / config.field_h);
        return .{
            .scale = scale,
            .origin_x = (screen_w - config.field_w * scale) * 0.5,
            .origin_y = (screen_h - config.field_h * scale) * 0.5,
        };
    }

    pub fn x(self: View, field_x: f32) f32 {
        return self.origin_x + field_x * self.scale + self.shake_x;
    }

    pub fn y(self: View, field_y: f32) f32 {
        return self.origin_y + field_y * self.scale + self.shake_y;
    }

    pub fn len(self: View, value: f32) f32 {
        return value * self.scale;
    }

    fn rect(self: View, cx: f32, cy: f32, half_w: f32, half_h: f32) rl.Rectangle {
        return .{
            .x = self.x(cx - half_w),
            .y = self.y(cy - half_h),
            .width = self.len(half_w * 2),
            .height = self.len(half_h * 2),
        };
    }
};

/// Interpolate between the last two simulation ticks. Without this the game
/// visibly steps at 120 Hz on a 144 Hz display.
fn lerp(previous: f32, current: f32, alpha: f32) f32 {
    return previous + (current - previous) * alpha;
}

pub fn frame(
    world: *const sim.World,
    system: *particles.System,
    view: View,
    alpha: f32,
    /// Total distance scrolled, used only to animate the road stripes.
    scroll: f32,
    /// False behind the title screen, where the score on show would be the
    /// attract mode's rather than the player's.
    show_hud: bool,
) void {
    rl.ClearBackground(color(palette.background));
    drawRoad(view, scroll);
    drawEntities(world, view, alpha);
    drawParticles(system, view);
    if (world.phase != .dead) drawPlayer(world, view, alpha);
    if (show_hud) drawHud(world, view);
}

fn drawRoad(view: View, scroll: f32) void {
    const road = view.rect(
        config.field_w * 0.5,
        config.field_h * 0.5,
        config.field_w * 0.5,
        config.field_h * 0.5,
    );
    rl.DrawRectangleRec(road, color(palette.road));

    // Lane separators.
    for (1..config.lane_count) |i| {
        const lane_x = view.x(@as(f32, @floatFromInt(i)) * config.lane_w);
        rl.DrawRectangleV(
            .{ .x = lane_x - view.len(1), .y = view.y(0) },
            .{ .x = view.len(2), .y = view.len(config.field_h) },
            color(palette.lane_line),
        );
    }

    // Dashes scrolling down each separator, so speed is legible even when the
    // field happens to be empty.
    const period: f32 = 80;
    const offset = @mod(scroll, period);
    for (1..config.lane_count) |i| {
        const lane_x = view.x(@as(f32, @floatFromInt(i)) * config.lane_w);
        var dash_y: f32 = -period + offset;
        while (dash_y < config.field_h) : (dash_y += period) {
            rl.DrawRectangleV(
                .{ .x = lane_x - view.len(2), .y = view.y(dash_y) },
                .{ .x = view.len(4), .y = view.len(36) },
                color(palette.stripe),
            );
        }
    }
}

fn drawEntities(world: *const sim.World, view: View, alpha: f32) void {
    var it = @constCast(&world.entities).iterator();
    while (it.next()) |entry| {
        const e = entry.value;
        const cx = config.laneCenter(e.lane);
        const cy = lerp(e.y_prev, e.y, alpha);
        switch (e.kind) {
            .block => {
                const body = view.rect(cx, cy, config.block_half_w, config.block_half_h);
                rl.DrawRectangleRounded(body, 0.28, 6, color(palette.block_dark));
                const face = view.rect(
                    cx,
                    cy - config.block_half_h * 0.28,
                    config.block_half_w * 0.9,
                    config.block_half_h * 0.55,
                );
                rl.DrawRectangleRounded(face, 0.4, 6, color(palette.block));
                const gloss = view.rect(
                    cx,
                    cy - config.block_half_h * 0.55,
                    config.block_half_w * 0.7,
                    config.block_half_h * 0.14,
                );
                rl.DrawRectangleRounded(gloss, 1, 6, color(palette.block_top));
            },
            .coin => {
                // A slow spin, faked by squashing the width. The squash bottoms
                // out at 55%: a coin that turns fully edge-on disappears for a
                // few frames, and a pickup the player cannot see is a pickup
                // they will not go for.
                const spin = 0.55 + 0.45 * @abs(@cos(cy * 0.028));
                const half_w = config.coin_half * spin;
                rl.DrawEllipse(
                    @intFromFloat(view.x(cx)),
                    @intFromFloat(view.y(cy)),
                    view.len(half_w),
                    view.len(config.coin_half),
                    color(palette.coin_dark),
                );
                rl.DrawEllipse(
                    @intFromFloat(view.x(cx)),
                    @intFromFloat(view.y(cy)),
                    view.len(half_w * 0.62),
                    view.len(config.coin_half * 0.62),
                    color(palette.coin),
                );
            },
        }
    }
}

fn drawPlayer(world: *const sim.World, view: View, alpha: f32) void {
    const cx = lerp(world.player.x_prev, world.player.x, alpha);
    const cy = config.player_y;

    // Lean into the turn. Reads as intent, and makes the slide feel driven
    // rather than dragged.
    const drift = (config.laneCenter(world.player.lane) - cx) / config.lane_w;
    const lean = std.math.clamp(drift, -1, 1) * config.player_half_w * 0.55;

    const shadow = view.rect(cx, cy + config.player_half_h * 0.75, config.player_half_w * 0.9, config.player_half_h * 0.22);
    rl.DrawRectangleRounded(shadow, 1, 6, color(palette.background.alpha(0.55)));

    const nose: rl.Vector2 = .{ .x = view.x(cx + lean), .y = view.y(cy - config.player_half_h) };
    const left: rl.Vector2 = .{ .x = view.x(cx - config.player_half_w), .y = view.y(cy + config.player_half_h) };
    const right: rl.Vector2 = .{ .x = view.x(cx + config.player_half_w), .y = view.y(cy + config.player_half_h) };
    // raylib wants counter-clockwise winding or the triangle is culled.
    rl.DrawTriangle(nose, left, right, color(palette.player));

    const core: rl.Vector2 = .{ .x = view.x(cx + lean * 0.5), .y = view.y(cy) };
    const core_left: rl.Vector2 = .{ .x = view.x(cx - config.player_half_w * 0.45), .y = view.y(cy + config.player_half_h * 0.7) };
    const core_right: rl.Vector2 = .{ .x = view.x(cx + config.player_half_w * 0.45), .y = view.y(cy + config.player_half_h * 0.7) };
    rl.DrawTriangle(core, core_left, core_right, color(palette.player_dark));
}

fn drawParticles(system: *particles.System, view: View) void {
    var it = system.iterator();
    while (it.next()) |entry| {
        const p = entry.value;
        const fade = p.fade();
        rl.DrawCircleV(
            .{ .x = view.x(p.x), .y = view.y(p.y) },
            view.len(p.size * fade),
            color(p.color.alpha(fade)),
        );
    }
}

/// raylib takes C strings, so formatting crosses that boundary exactly here.
pub fn fmtZ(buffer: []u8, comptime template: []const u8, args: anytype) [*:0]const u8 {
    const written = std.mem.printSentinel(buffer, template, args, 0) catch return "?";
    return written.ptr;
}

fn drawHud(world: *const sim.World, view: View) void {
    var buffer: [64]u8 = undefined;
    drawText(fmtZ(&buffer, "{d}", .{world.score}), view, 18, 16, 44, palette.text);

    var best_buffer: [64]u8 = undefined;
    drawTextRight(
        fmtZ(&best_buffer, "BEST {d}", .{world.best}),
        view,
        config.field_w - 18,
        24,
        20,
        palette.text_dim,
    );

    if (world.combo > 1 and world.phase == .playing) {
        var combo_buffer: [32]u8 = undefined;
        drawText(fmtZ(&combo_buffer, "x{d}", .{world.combo}), view, 20, 66, 26, palette.coin);
    }
}

/// Text with a hard drop shadow.
///
/// The HUD sits over the top of the field, which is exactly where blocks enter,
/// so the score spends part of every run on top of a bright red rectangle. A
/// shadow is cheaper than reserving a strip of the playfield for the HUD, and
/// keeps the whole field playable.
fn shadowed(text: [*:0]const u8, px: i32, py: i32, size: i32, c: palette.Color) void {
    const offset = @max(@divTrunc(size, 14), 1);
    rl.DrawText(text, px + offset, py + offset, size, color(palette.background.alpha(0.75)));
    rl.DrawText(text, px, py, size, color(c));
}

fn drawText(text: [*:0]const u8, view: View, fx: f32, fy: f32, size: f32, c: palette.Color) void {
    shadowed(
        text,
        @intFromFloat(view.x(fx)),
        @intFromFloat(view.y(fy)),
        @intFromFloat(view.len(size)),
        c,
    );
}

fn drawTextRight(text: [*:0]const u8, view: View, fx: f32, fy: f32, size: f32, c: palette.Color) void {
    const size_px: i32 = @intFromFloat(view.len(size));
    const pixels = rl.MeasureText(text, size_px);
    shadowed(
        text,
        @as(i32, @intFromFloat(view.x(fx))) - pixels,
        @intFromFloat(view.y(fy)),
        size_px,
        c,
    );
}

/// Centred overlay text, used by the title and game over screens.
pub fn centred(text: [*:0]const u8, view: View, fy: f32, size: f32, c: palette.Color) void {
    const size_px: i32 = @intFromFloat(view.len(size));
    const pixels = rl.MeasureText(text, size_px);
    shadowed(
        text,
        @as(i32, @intFromFloat(view.x(config.field_w * 0.5))) - @divTrunc(pixels, 2),
        @intFromFloat(view.y(fy)),
        size_px,
        c,
    );
}

/// A slab behind overlay text. The attract mode keeps playing underneath the
/// title, which is the nicest thing about it and also means a block or a coin
/// can drift straight through a line of copy. Dimming the whole field is not
/// enough, because the thing that ruins legibility is a bright shape at full
/// opacity, not the average brightness.
pub fn panel(view: View, top: f32, bottom: f32, amount: f32) void {
    const inset: f32 = 14;
    const box: rl.Rectangle = .{
        .x = view.x(inset),
        .y = view.y(top),
        .width = view.len(config.field_w - inset * 2),
        .height = view.len(bottom - top),
    };
    rl.DrawRectangleRounded(box, 0.06, 8, color(palette.background.alpha(amount)));
}

pub fn dim(view: View, amount: f32) void {
    rl.DrawRectangle(
        @intFromFloat(view.x(0)),
        @intFromFloat(view.y(0)),
        @intFromFloat(view.len(config.field_w)),
        @intFromFloat(view.len(config.field_h)),
        color(palette.background.alpha(amount)),
    );
}
