//! All the numbers in the game that you can adjust, in one place.
//!
//! The simulation uses a fixed virtual field of `field_w` x `field_h` units,
//! and never pixels. The renderer scales that field to the size of the window.
//! Thus a change to the size of the window cannot change the difficulty. A
//! test can assert positions and not open a window.

/// The play field, in simulation units. The field is portrait, because the
/// player uses a thumb to play.
pub const field_w: f32 = 360;
pub const field_h: f32 = 640;

pub const lane_count: u8 = 3;
pub const lane_w: f32 = field_w / @as(f32, lane_count);

/// The player is at a fixed height, and the world moves toward the player.
pub const player_y: f32 = 520;
pub const player_half_w: f32 = 24;
pub const player_half_h: f32 = 26;

pub const block_half_w: f32 = 50;
pub const block_half_h: f32 = 26;

pub const coin_half: f32 = 16;

/// The seconds for a slide of one full lane. This number has a large effect on
/// how the controls feel. If it is too slow, the game is unfair. If it is
/// too fast, a lane change costs nothing to cancel.
pub const lane_change_time: f32 = 0.11;

/// Entities appear above the field. The game frees them below the field.
pub const spawn_y: f32 = -60;
pub const despawn_y: f32 = field_h + 80;

/// The scroll speed in units for each second, from the first row to the most
/// difficult row.
///
/// The speed has a maximum, and the spacing does not. A block moves
/// `speed / tick_hz` units in each tick. When that distance comes near the
/// height of the block, the collision test starts to miss collisions. The
/// block is above the player on one tick and below the player on the next
/// tick, because it moved through the player. The maximum keeps the step to a
/// few units.
pub const speed_start: f32 = 260;
pub const speed_max: f32 = 620;

/// The seconds of play until the game gets to full difficulty.
pub const ramp_seconds: f32 = 60;

/// The seconds between rows at the start.
pub const row_gap_easy: f32 = 0.85;

/// The margin that the row spacing keeps above the point where a player can
/// no longer survive.
///
/// The physics of the game sets a minimum for the spacing. Between the arrival
/// of one row and the next row, the player must be able to cross the full
/// board (`2 * lane_change_time`). Also, the player cannot start while the
/// current row is level with the player (`2 * (player_half_h + block_half_h) / speed`).
/// If the rows are closer than that sum, no player can survive. That failure
/// would be silent, because each row would still leave a lane open. But
/// nobody could get to that lane.
///
/// Thus `sim.rowGapSeconds` calculates that minimum, adds this margin, and
/// decays toward it. The game always becomes more difficult, and it always
/// stays solvable. A designer adjusts this margin, and the margin sets only
/// the quantity of extra space. The code calculates the minimum, and the
/// minimum decides if a player can survive.
pub const gap_safety: f32 = 0.06;

/// The seconds until the row spacing moves most of the distance to that
/// minimum. The approach is exponential, and it never gets to the minimum.
/// This is intentional. If the difficulty stops its increase, a good player
/// never loses. Then the score in an endless runner measures nothing.
pub const gap_tau: f32 = 30;

/// A row never blocks all the lanes, thus each row has an open lane. The row
/// gap above makes sure that the player has time to get to that lane.
pub const max_blocked_lanes: u8 = lane_count - 1;

/// The probability that a row blocks two lanes and not one lane.
pub const two_block_chance_easy: f32 = 0.05;
pub const two_block_chance_hard: f32 = 0.55;

/// The seconds at the start when no row blocks more than one lane.
///
/// This value is a decision, not a measurement. The reaction time model in the
/// tests already knows the controls. Thus the model cannot show a new player
/// who still looks for the keys. When the window is off, the modelled 200 ms
/// average moves from 29.5 s to 29.2 s. In the grace window, each row leaves
/// two lanes open. Thus one lane change is always sufficient to pass the row.
pub const grace_seconds: f32 = 7;

/// The seconds of empty road before the first row arrives.
pub const opening_lead: f32 = 1.8;

/// The probability that a row also has a coin in one of its free lanes.
pub const coin_chance: f32 = 0.55;

/// The points for each unit of distance that the player travels.
pub const points_per_unit: f32 = 0.1;

pub const coin_points: u32 = 25;
pub const near_miss_points: u32 = 5;
pub const max_combo: u32 = 8;

/// The maximum distance for a near miss. The distance is from centre to
/// centre, when the block becomes level with the player.
///
/// This value must be in a narrow band. Below `player_half_w + block_half_w`,
/// the block and the player touch, thus the result is a crash. At `lane_w` or
/// more, a near miss would occur each time a block moved past in the next
/// lane. That occurs for most of the game, thus the bonus would pay all the
/// time. Between these limits, a near miss means that the block moved past
/// while a part of the player was still in its lane. Only a late dodge gets
/// the bonus.
pub const near_miss_dist: f32 = player_half_w + block_half_w + 38;

/// The seconds that the crash plays before the game accepts a restart. Thus a
/// key that the player presses many times during the crash cannot skip the
/// crash and immediately lose the next run.
pub const death_hold: f32 = 0.6;

/// The fixed simulation rate. The renderer can run at any frame rate.
pub const tick_hz: f32 = 120;
pub const tick_dt: f32 = 1.0 / tick_hz;

/// The centre of a lane, in field units.
pub fn laneCenter(lane: u8) f32 {
    return (@as(f32, @floatFromInt(lane)) + 0.5) * lane_w;
}
