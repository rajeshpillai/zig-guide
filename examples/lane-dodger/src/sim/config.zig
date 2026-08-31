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

/// Seconds to slide one full lane. The single most important feel number in
/// the game: too slow and it is unfair, too fast and there is no commitment.
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
/// The spacing is not a hand-picked pair of numbers. There is a hard floor
/// under it, set by physics rather than taste: between one row arriving and the
/// next, the player must be able to cross the whole board (`2 *
/// lane_change_time`), and they cannot begin while the current row is level
/// with them (`2 * (player_half_h + block_half_h) / speed`). Spacing rows any
/// tighter than that sum makes the game unwinnable, and it would fail silently,
/// because every row would still leave a lane open, just not one anybody could
/// reach.
///
/// So `sim.rowGapSeconds` computes that floor, adds this margin, and decays
/// towards it. The game therefore gets harder forever and stays solvable
/// forever, and the constant a designer is free to move is the one that says
/// how much room to leave rather than the one that decides whether the game
/// works.
pub const gap_safety: f32 = 0.06;

/// Seconds for the row spacing to close most of the distance to that floor.
/// The approach is exponential and never arrives, which is deliberate: a game
/// whose difficulty stops rising is a game a good player never loses, and an
/// endless runner nobody can lose has no score worth chasing.
pub const gap_tau: f32 = 30;

/// A row never blocks every lane. This is what makes the course solvable at
/// all; the gap above is what makes it reachable.
pub const max_blocked_lanes: u8 = lane_count - 1;

/// Probability that a row blocks two lanes rather than one.
pub const two_block_chance_easy: f32 = 0.05;
pub const two_block_chance_hard: f32 = 0.55;

/// Opening seconds during which no row blocks more than one lane.
///
/// Measured, not guessed. Modelling a player with a 200 ms reaction showed a
/// mean survival of 29 s but a worst seed of 3.9 s: some openings happened to
/// demand a two lane crossing before anyone had settled in, and a hyper casual
/// game that can kill you in four seconds on your first go does not get a
/// second one. Inside the grace window every row leaves two lanes open, so a
/// single sideways nudge always answers it.
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
/// `player_half_w + block_half_w` the two have collided and it is not a near
/// miss, it is a crash. At or above `lane_w` it would fire every time a block
/// went by in the next lane, which is most of the game, and a bonus that pays
/// out constantly is not a bonus. In between it means what it says: the block
/// went past while the player was still partly in its lane. Only a late dodge
/// earns it.
pub const near_miss_dist: f32 = player_half_w + block_half_w + 38;

/// Seconds the crash plays out before a restart is accepted, so a mashed input
/// cannot skip the death and immediately lose the next run.
pub const death_hold: f32 = 0.6;

/// Fixed simulation rate. The renderer may run at any frame rate it likes.
pub const tick_hz: f32 = 120;
pub const tick_dt: f32 = 1.0 / tick_hz;

/// Centre of a lane in field units.
pub fn laneCenter(lane: u8) f32 {
    return (@as(f32, @floatFromInt(lane)) + 0.5) * lane_w;
}
