//! raylib input, changed into the edge-triggered ticks that the simulation
//! needs.
//!
//! The simulation runs at a fixed 120 Hz. The window runs at the rate of the
//! display. The two rates do not divide evenly. Thus a frame can need zero
//! ticks or three ticks from the simulation.
//!
//! A press must go to exactly one of these ticks. If the game drops a press,
//! the game loses inputs. If the game repeats a press, one tap moves the
//! player across three lanes. Thus this file latches each press when it
//! arrives, and gives it to one tick.

const rl = @import("rl");
const sim = @import("sim");

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
