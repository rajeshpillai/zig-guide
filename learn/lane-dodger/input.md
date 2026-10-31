# Input

> The game latches presses one time in each frame and gives each press to exactly one tick. A held key must not cross the board.

The simulation runs at a fixed 120 Hz. The window runs at the rate of the
display. The two rates do not divide evenly. Thus a rendered frame can need zero
ticks, one tick, or three ticks from the simulation.

A press must get to exactly one of these ticks:

- If the game drops a press, the game ignores the player.
- If the game gives a press to more than one tick, one tap moves the player
  across three lanes.

```zig
pub const Latch = struct {
    left: bool = false,
    right: bool = false,
    confirm: bool = false,

    /// The caller calls this one time for each rendered frame, before the tick
    /// loop.
    pub fn poll(self: *Latch) void {
        if (rl.IsKeyPressed(rl.KEY_LEFT) or
            rl.IsKeyPressed(rl.KEY_A)) self.left = true;
        if (rl.IsKeyPressed(rl.KEY_RIGHT) or
            rl.IsKeyPressed(rl.KEY_D)) self.right = true;
        if (rl.IsKeyPressed(rl.KEY_SPACE) or
            rl.IsKeyPressed(rl.KEY_ENTER)) self.confirm = true;

        // Touch and mouse: tap a side of the screen to steer. On a phone, the
        // player uses these taps.
        if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
            const x = rl.GetMousePosition().x;
            if (x < @as(f32, @floatFromInt(rl.GetScreenWidth())) * 0.5) {
                self.left = true;
            } else {
                self.right = true;
            }
            self.confirm = true;
        }
    }

    /// Give the latched presses to one tick, then clear them.
    pub fn take(self: *Latch) sim.Input {
        const input: sim.Input = .{
            .left = self.left,
            .right = self.right,
            .confirm = self.confirm,
        };
        self.* = .{};
        return input;
    }

    pub fn pending(self: *const Latch) bool {
        return self.left or self.right or self.confirm;
    }
};
```

*Quoted from the source: `Latch` from `examples/lane-dodger/src/platform/input.zig`.*

`poll` runs one time in each rendered frame, before the tick loop. `take` gives
the latched presses to one tick and clears them.

## Why the fields are booleans and not key states

`IsKeyPressed` is true on the frame when a key goes down. It is false while the
key stays down. The game needs that behaviour. If the player holds `D`, the
player must move one lane. The player must not slide across the board at a
hundred lanes each second.

The simulation states this rule in its own type:

```zig
/// Edge-triggered: each field means "pressed during this tick", not "held".
/// A key that the player holds must not slide the player across the board.
pub const Input = struct {
    left: bool = false,
    right: bool = false,
    confirm: bool = false,

    pub const none: Input = .{};
};
```

*Quoted from the source: `Input` from `examples/lane-dodger/src/sim/sim.zig`.*

A test checks the rule:

```zig
test "a held direction moves exactly one lane" {
    // Input is edge-triggered. If the game read a held key as a press on each
    // tick, the player would cross the board in two frames.
    var w: World = .init(1);
    w.start();
    const start_lane = w.player.lane;
    w.step(.{ .right = true });
    try std.testing.expectEqual(start_lane + 1, w.player.lane);
    for (0..60) |_| w.step(.none);
    try std.testing.expectEqual(start_lane + 1, w.player.lane);
}
```

*Quoted from the source: `a held direction moves exactly one lane` from `examples/lane-dodger/src/sim/tests.zig`.*

## A frame that needs no ticks

If a frame makes no ticks, nothing calls `take`. The latch keeps its presses for
the next frame. Thus the game remembers a tap between two ticks, and does not
lose it.

If a frame makes three ticks, the first tick gets the press. The other two ticks
get nothing. This works because `take` clears the latch.

## Touch

The same poll reads the mouse. It divides the window into a left half and a
right half.

A tap on the left half steers left. A tap on the right half steers right. A tap
on either half is also the confirm that starts a run. A phone needs only these
controls. The touch input needed only one more branch in `poll`, because the
simulation already uses lanes and not keys.

## What the platform layer does not do

Mute is a key press, and the key press never gets to the simulation:

```zig
if (rl.IsKeyPressed(rl.KEY_M)) self.audio.toggleMute();
```

Mute changes only the audio device. No code in `sim/` knows that sound exists. A
mute key inside the simulation would change that.
