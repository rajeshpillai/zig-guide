//! Every tunable number in the game, in one place.
//!
//! The simulation works in a fixed virtual field of `field_w` x `field_h`
//! units, never in pixels. The renderer scales that field to whatever the
//! window happens to be. So resizing the window cannot change the difficulty,
//! and a test can assert on positions without opening one.

/// Play field, in simulation units. Portrait, because the game is a thumb game.
pub const field_w: f32 = 360;
pub const field_h: f32 = 640;

pub const lane_count: u8 = 3;
pub const lane_w: f32 = field_w / @as(f32, lane_count);

/// The player sits at a fixed height and the world comes to them.
pub const player_y: f32 = 520;
pub const player_half_w: f32 = 24;
pub const player_half_h: f32 = 26;

pub const block_half_w: f32 = 50;
pub const block_half_h: f32 = 26;

pub const coin_half: f32 = 16;

/// Seconds to slide one full lane. This number decides much of how steering
/// feels: too slow and the game is unfair, too fast and a lane change costs
/// nothing to undo.
pub const lane_change_time: f32 = 0.11;

/// Entities appear above the field and are freed below it.
pub const spawn_y: f32 = -60;
pub const despawn_y: f32 = field_h + 80;

/// Scroll speed in units per second, from the first row to the hardest.
///
/// Speed is capped, unlike the spacing. A block moves `speed / tick_hz` units
/// per tick, and once that approaches the block's own height the collision test
/// starts missing: the block is above the player on one tick and below them on
/// the next, having passed through. The cap keeps the step to a few units.
pub const speed_start: f32 = 260;
pub const speed_max: f32 = 620;

/// Seconds of play to reach full difficulty.
pub const ramp_seconds: f32 = 60;

/// Seconds between rows at the very start.
pub const row_gap_easy: f32 = 0.85;

/// How much slack the row spacing keeps above the point where the game stops
/// being winnable.
///
/// The spacing has a hard floor under it, set by the game's physics: between
/// one row arriving and the next, the player must be able to cross the whole
/// board (`2 * lane_change_time`), and they cannot begin while the current
/// row is level with them (`2 * (player_half_h + block_half_h) / speed`).
/// Spacing rows any tighter than that sum makes the game unwinnable, and it
/// would fail silently, because every row would still leave a lane open, just
/// not one anybody could reach.
///
/// So `sim.rowGapSeconds` computes that floor, adds this margin, and decays
/// towards it. The game gets harder forever and stays solvable forever. This
/// margin is the constant a designer tunes, and it only sets how much room to
/// leave. The floor, which decides whether the game can be won, is computed.
pub const gap_safety: f32 = 0.06;

/// Seconds for the row spacing to close most of the distance to that floor.
/// The approach is exponential and never reaches the floor. This is
/// deliberate. If the difficulty stops rising, a good player never loses, and
/// then the score in an endless runner measures nothing.
pub const gap_tau: f32 = 30;

/// A row never blocks every lane, so every row has an open lane. The row gap
/// above makes sure the player has time to reach it.
pub const max_blocked_lanes: u8 = lane_count - 1;

/// Probability that a row blocks two lanes rather than one.
pub const two_block_chance_easy: f32 = 0.05;
pub const two_block_chance_hard: f32 = 0.55;

/// Opening seconds during which no row blocks more than one lane.
///
/// This is a judgement call, not a measurement. The reaction time model in the
/// tests already knows the controls, so it cannot show a first-time player
/// who is still looking for the keys. Turning the window off moves the
/// modelled 200 ms average from 29.5 s to 29.2 s. Inside the grace window
/// every row leaves two lanes open, so one lane change is always enough to
/// pass it.
pub const grace_seconds: f32 = 7;

/// Seconds of clear road before the first row arrives.
pub const opening_lead: f32 = 1.8;

/// Probability that a row also carries a coin in one of its free lanes.
pub const coin_chance: f32 = 0.55;

/// Points per unit of distance travelled.
pub const points_per_unit: f32 = 0.1;

pub const coin_points: u32 = 25;
pub const near_miss_points: u32 = 5;
pub const max_combo: u32 = 8;

/// How close a block has to pass to count as a near miss, measured centre to
/// centre at the moment it draws level.
///
/// This has to sit in a band, and the band is narrow. Below
/// `player_half_w + block_half_w` the two have collided, so it is a crash. At
/// or above `lane_w` it would fire every time a block went by in the next
/// lane. That happens for most of the game, so the bonus would pay out all the
/// time. In between, it means the block went past while the player was still
/// partly in its lane. Only a late dodge earns it.
pub const near_miss_dist: f32 = player_half_w + block_half_w + 38;

/// Seconds the crash plays out before a restart is accepted, so a key pressed
/// many times during the crash cannot skip it and immediately lose the next
/// run.
pub const death_hold: f32 = 0.6;

/// Fixed simulation rate. The renderer may run at any frame rate it likes.
pub const tick_hz: f32 = 120;
pub const tick_dt: f32 = 1.0 / tick_hz;

/// Centre of a lane in field units.
pub fn laneCenter(lane: u8) f32 {
    return (@as(f32, @floatFromInt(lane)) + 0.5) * lane_w;
}
