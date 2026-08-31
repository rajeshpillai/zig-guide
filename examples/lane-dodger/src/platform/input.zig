//! raylib input, turned into the edge-triggered ticks the simulation wants.
//!
//! The simulation runs at a fixed 120 Hz and the window runs at whatever the
//! display does. Those do not divide evenly, so a frame may owe the simulation
//! zero ticks or three. A press has to be delivered to exactly one of them:
//! drop it and the game eats inputs, repeat it and one tap crosses three lanes.
//! So presses are latched here as they arrive and handed over once.

const rl = @import("rl");
const sim = @import("sim");

pub const Latch = struct {
    left: bool = false,
    right: bool = false,
    confirm: bool = false,

    /// Called once per rendered frame, before the tick loop.
    pub fn poll(self: *Latch) void {
        if (rl.IsKeyPressed(rl.KEY_LEFT) or
            rl.IsKeyPressed(rl.KEY_A)) self.left = true;
        if (rl.IsKeyPressed(rl.KEY_RIGHT) or
            rl.IsKeyPressed(rl.KEY_D)) self.right = true;
        if (rl.IsKeyPressed(rl.KEY_SPACE) or
            rl.IsKeyPressed(rl.KEY_ENTER)) self.confirm = true;

        // Touch and mouse: tap a side of the screen to steer, which is how the
        // game is actually played on a phone.
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

    /// Hand the latched presses to one tick and forget them.
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
