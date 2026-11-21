# Draw It

> Field units mapped onto a window, the road, the entities, and a particle system that contains no raylib types.

The simulation uses a fixed field of 360 by 640. The window can have any size
that the reader gives it. One struct maps between the field and the window.

```zig
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
```

*Quoted from the source: `View` from `examples/lane-dodger/src/render/draw.zig`.*

The scale is the smaller of the two ratios. Thus the renderer letterboxes the
field. A
wider window gets bars on the sides. It does not get more road.

If the view filled the window, a wide window would show blocks earlier. Then a
player could get an advantage when the player changes the size of the window.

The transform adds `shake_x` and `shake_y` at the end. Thus the screen shake
moves the full field, and it costs nothing in other places.

## A frame

```zig
pub fn frame(
    world: *const sim.World,
    system: *particles.System,
    view: View,
    alpha: f32,
    /// The total distance that the road moved. Only the animation of the road
    /// stripes uses it.
    scroll: f32,
    /// False behind the title screen. There, the visible score would be the
    /// score of the attract mode, and not the score of the player.
    show_hud: bool,
) void {
    rl.ClearBackground(color(palette.background));
    drawRoad(view, scroll);
    drawEntities(world, view, alpha);
    drawParticles(system, view);
    if (world.phase != .dead) drawPlayer(world, view, alpha);
    if (show_hud) drawHud(world, view);
}
```

*Quoted from the source: `frame` from `examples/lane-dodger/src/render/draw.zig`.*

The order is from back to front: road, entities, particles, player, HUD. This
file reads the world and never writes it. No code in this file can change the
result of a run.

## The road

```zig
fn drawRoad(view: View, scroll: f32) void {
    const road = view.rect(
        config.field_w * 0.5,
        config.field_h * 0.5,
        config.field_w * 0.5,
        config.field_h * 0.5,
    );
    rl.DrawRectangleRec(road, color(palette.road));

    // The lines between the lanes.
    for (1..config.lane_count) |i| {
        const lane_x = view.x(@as(f32, @floatFromInt(i)) * config.lane_w);
        rl.DrawRectangleV(
            .{ .x = lane_x - view.len(1), .y = view.y(0) },
            .{ .x = view.len(2), .y = view.len(config.field_h) },
            color(palette.lane_line),
        );
    }

    // Dashes move down each line. Thus the speed is visible also when the
    // field is empty.
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
```

*Quoted from the source: `drawRoad` from `examples/lane-dodger/src/render/draw.zig`.*

The dashes move with the distance that the player travelled. When the field is
empty, the dashes are the only thing on the screen that shows the speed. In the
first few seconds, the field is empty more frequently than you think.

## The entities

```zig
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
                // A slow spin. The code makes the width smaller, and does not
                // really rotate the coin. The minimum width is 55%. A coin that
                // turns its full edge to the player is not visible for a few
                // frames. A player does not try to get a coin that the player
                // cannot see.
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
```

*Quoted from the source: `drawEntities` from `examples/lane-dodger/src/render/draw.zig`.*

The renderer draws each entity between its last two positions. It uses the
`alpha` value that the [loop](https://www.ziglang.in/learn/lane-dodger/the-loop/) gives it. Without
`alpha`, the game moves in visible steps at 120 Hz on a faster display.

The coin spin makes the width smaller, and it does not rotate the coin. The
minimum width is 55 percent, thus the coin is always visible. An earlier version
used the full range. Then the coin turned its edge to the player and was not
visible for a few frames. Players do not try to get a coin that they cannot see.

## The player

```zig
fn drawPlayer(world: *const sim.World, view: View, alpha: f32) void {
    const cx = lerp(world.player.x_prev, world.player.x, alpha);
    const cy = config.player_y;

    // Tilt toward the turn. The tilt shows where the player wants to go. It
    // makes the slide look like a steered movement, and not like a pull.
    const drift = (config.laneCenter(world.player.lane) - cx) / config.lane_w;
    const lean = std.math.clamp(drift, -1, 1) * config.player_half_w * 0.55;

    const shadow = view.rect(cx, cy + config.player_half_h * 0.75, config.player_half_w * 0.9, config.player_half_h * 0.22);
    rl.DrawRectangleRounded(shadow, 1, 6, color(palette.background.alpha(0.55)));

    const nose: rl.Vector2 = .{ .x = view.x(cx + lean), .y = view.y(cy - config.player_half_h) };
    const left: rl.Vector2 = .{ .x = view.x(cx - config.player_half_w), .y = view.y(cy + config.player_half_h) };
    const right: rl.Vector2 = .{ .x = view.x(cx + config.player_half_w), .y = view.y(cy + config.player_half_h) };
    // raylib needs counter-clockwise winding. If not, raylib culls the
    // triangle.
    rl.DrawTriangle(nose, left, right, color(palette.player));

    const core: rl.Vector2 = .{ .x = view.x(cx + lean * 0.5), .y = view.y(cy) };
    const core_left: rl.Vector2 = .{ .x = view.x(cx - config.player_half_w * 0.45), .y = view.y(cy + config.player_half_h * 0.7) };
    const core_right: rl.Vector2 = .{ .x = view.x(cx + config.player_half_w * 0.45), .y = view.y(cy + config.player_half_h * 0.7) };
    rl.DrawTriangle(core, core_left, core_right, color(palette.player_dark));
}
```

*Quoted from the source: `drawPlayer` from `examples/lane-dodger/src/render/draw.zig`.*

The renderer calculates the lean from the distance between the target lane and
the actual position. That distance is exactly the gap that
[the previous chapter](https://www.ziglang.in/learn/lane-dodger/the-world/) described. The lean costs
three lines. The lean is the main reason that the movement looks deliberate.

## Colours are plain data

```zig
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn alpha(self: Color, value: f32) Color {
        const clamped = if (value < 0) 0 else if (value > 1) 1 else value;
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = @intFromFloat(clamped * 255) };
    }

    pub fn mix(a: Color, b: Color, t: f32) Color {
        const clamped = if (t < 0) 0 else if (t > 1) 1 else t;
        return .{
            .r = lerp(a.r, b.r, clamped),
            .g = lerp(a.g, b.g, clamped),
            .b = lerp(a.b, b.b, clamped),
            .a = lerp(a.a, b.a, clamped),
        };
    }

    fn lerp(a: u8, b: u8, t: f32) u8 {
        const af: f32 = @floatFromInt(a);
        const bf: f32 = @floatFromInt(b);
        return @intFromFloat(af + (bf - af) * t);
    }
};
```

*Quoted from the source: `Color` from `examples/lane-dodger/src/render/palette.zig`.*

The palette file has no raylib types. `draw.zig` converts the colours at the
edge:

```zig
fn color(c: palette.Color) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}
```

*Quoted from the source: `color` from `examples/lane-dodger/src/render/draw.zig`.*

The reason is the particle system below. The particle system needs colours. When
raylib stays out of the particle system, you can test the particle system
without a window.

## Particles

The particles are presentation. The simulation reports that the player collected
a coin. The particle system changes that report into ten amber dots that fly
outward.

```zig
pub const System = struct {
    pub const capacity = 256;
    const Pool = sim.Pool(Particle, capacity);

    pool: Pool,
    rng: Rng,

    pub fn init(seed: u64) System {
        return .{ .pool = .empty, .rng = .init(seed, 0xBEEF) };
    }

    pub fn clear(self: *System) void {
        self.pool.clear();
    }

    pub fn live(self: *const System) u16 {
        return self.pool.live;
    }

    /// The oldest particles stay. When the pool is full, the system drops new
    /// particles. Nobody sees a spark that is not there, but a frame that stops
    /// to make space is visible.
    fn emit(self: *System, p: Particle) void {
        _ = self.pool.create(p);
    }

    pub fn update(self: *System, dt: f32) void {
        var it = self.pool.iterator();
        while (it.next()) |entry| {
            const p = entry.value;
            p.life -= dt;
            if (p.life <= 0) {
                self.pool.destroy(entry.handle);
                continue;
            }
            p.vy += p.gravity * dt;
            p.x += p.vx * dt;
            p.y += p.vy * dt;
        }
    }

    pub fn iterator(self: *System) Pool.Iterator {
        return self.pool.iterator();
    }

    /// A ring of sparks, used for coins.
    pub fn burst(self: *System, x: f32, y: f32, count: usize, color: Color, speed: f32) void {
        for (0..count) |i| {
            const turn = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
            const angle = turn * std.math.tau + self.rng.float() * 0.4;
            const magnitude = speed * (0.6 + self.rng.float() * 0.8);
            const life = 0.35 + self.rng.float() * 0.3;
            self.emit(.{
                .x = x,
                .y = y,
                .vx = @cos(angle) * magnitude,
                .vy = @sin(angle) * magnitude,
                .life = life,
                .life_max = life,
                .size = 3 + self.rng.float() * 3,
                .gravity = 420,
                .color = color,
            });
        }
    }

    /// A wider, slower and heavier burst, for the crash.
    pub fn debris(self: *System, x: f32, y: f32) void {
        for (0..28) |_| {
            const angle = (self.rng.float() - 0.5) * std.math.pi * 1.6 - std.math.pi / 2.0;
            const magnitude = 120 + self.rng.float() * 340;
            const life = 0.5 + self.rng.float() * 0.6;
            self.emit(.{
                .x = x,
                .y = y,
                .vx = @cos(angle) * magnitude,
                .vy = @sin(angle) * magnitude,
                .life = life,
                .life_max = life,
                .size = 3 + self.rng.float() * 5,
                .gravity = 900,
                .color = if (self.rng.chance(0.5)) palette.block else palette.block_top,
            });
        }
    }

    /// A short horizontal smear behind the player, when the player moves to a
    /// new lane.
    pub fn dust(self: *System, x: f32, y: f32, direction: f32) void {
        for (0..6) |_| {
            const life = 0.18 + self.rng.float() * 0.16;
            self.emit(.{
                .x = x,
                .y = y + (self.rng.float() - 0.5) * 30,
                .vx = -direction * (60 + self.rng.float() * 120),
                .vy = (self.rng.float() - 0.5) * 40,
                .life = life,
                .life_max = life,
                .size = 2 + self.rng.float() * 3,
                .gravity = 0,
                .color = palette.player_dark,
            });
        }
    }

    /// Two vertical streaks that mark a block that moved past near the player.
    pub fn graze(self: *System, x: f32, y: f32) void {
        for (0..8) |_| {
            const life = 0.25 + self.rng.float() * 0.2;
            self.emit(.{
                .x = x + (self.rng.float() - 0.5) * 40,
                .y = y + (self.rng.float() - 0.5) * 50,
                .vx = (self.rng.float() - 0.5) * 60,
                .vy = 260 + self.rng.float() * 200,
                .life = life,
                .life_max = life,
                .size = 2 + self.rng.float() * 2,
                .gravity = 0,
                .color = palette.good,
            });
        }
    }
};
```

*Quoted from the source: `System` from `examples/lane-dodger/src/render/particles.zig`.*

The particle system uses the same [pool](https://www.ziglang.in/learn/lane-dodger/entities/) as the
entities, with a different element type and a capacity of 256.

A full pool drops new particles. It does not stop a frame to make space. A
player can see a stopped frame, but cannot see a spark that is not there.

```zig
    /// A ring of sparks, used for coins.
    pub fn burst(self: *System, x: f32, y: f32, count: usize, color: Color, speed: f32) void {
        for (0..count) |i| {
            const turn = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
            const angle = turn * std.math.tau + self.rng.float() * 0.4;
            const magnitude = speed * (0.6 + self.rng.float() * 0.8);
            const life = 0.35 + self.rng.float() * 0.3;
            self.emit(.{
                .x = x,
                .y = y,
                .vx = @cos(angle) * magnitude,
                .vy = @sin(angle) * magnitude,
                .life = life,
                .life_max = life,
                .size = 3 + self.rng.float() * 3,
                .gravity = 420,
                .color = color,
            });
        }
    }
```

*Quoted from the source: `burst` from `examples/lane-dodger/src/render/particles.zig`.*

None of this code uses raylib. Thus the tests check the behaviour without a
window:

- Particles expire and free their slots.
- A full pool stays inside its capacity.
- Gravity pulls the particles down.

## Text over a moving field

The HUD is at the top of the field, and the blocks enter at exactly that
position. During each run, the score is on top of a bright red rectangle for some
of the time.

```zig
/// Text with a hard drop shadow.
///
/// The HUD is at the top of the field, and the blocks enter at exactly that
/// position. Thus, during each run, the score is on top of a bright red
/// rectangle for some of the time. A shadow costs less than a strip of the
/// field that only the HUD uses. The shadow also keeps the full field
/// available for play.
fn shadowed(text: [*:0]const u8, px: i32, py: i32, size: i32, c: palette.Color) void {
    const offset = @max(@divTrunc(size, 14), 1);
    rl.DrawText(text, px + offset, py + offset, size, color(palette.background.alpha(0.75)));
    rl.DrawText(text, px, py, size, color(c));
}
```

*Quoted from the source: `shadowed` from `examples/lane-dodger/src/render/draw.zig`.*

A shadow of one pixel costs less than a strip of the field that only the HUD
uses. The shadow also keeps the full field available for play.
