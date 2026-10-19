//! A policy that plays the game.
//!
//! The bot has two purposes. First, it controls the attract mode behind the
//! title screen, thus the game shows itself. Second, and more important, the
//! tests use the bot to test the course generator. A level designer can
//! promise that each row leaves a gap. But the important promise is that a
//! player can really get to the gap in the available time, at each speed on
//! the ramp.
//!
//! That is a claim about how four constants act together. The correct way to
//! check it is to play the game for an hour and see the result. The tests do
//! this at each seed, in about a second.
//!
//! The bot uses the physical position of the player, and never the lane that
//! the player steers toward. The two are different for `lane_change_time`
//! after each press. If a bot confuses them, the bot slides its body through a
//! block that it thinks it already passed.

const std = @import("std");
const sim = @import("sim.zig");
const config = @import("config.zig");

/// The vertical half-span in which a block and the player overlap. A block is
/// dangerous from `+reach` in front of the player to `-reach` behind the
/// player. If this value used only the half-height of the block, the result
/// would be the off-by-one-body bug that the fairness test found.
const reach = config.player_half_h + config.block_half_h;

/// The horizontal overlap between the player and a block, in lanes. A slide
/// from lane 0 to lane 2 touches each object that is this near to the path.
const sweep = (config.player_half_w + config.block_half_w) / config.lane_w;

/// Do not start a move across the board that would end this near to the
/// deadline.
const margin = config.lane_change_time * 0.3;

const max_rows = 16;

const Row = struct {
    /// The game puts down a row at one y, and the blocks of a row move
    /// together. Thus y identifies a row exactly.
    y: f32,
    /// The seconds until this row starts to overlap the player.
    seconds: f32,
    blocked: [config.lane_count]bool,
    coin_lane: ?u8,
};

const View = struct {
    /// The lanes that have a block level with the player now. A move into one
    /// of these lanes is an immediate crash. A move across one of these lanes
    /// is the same crash a moment later.
    blocked_now: [config.lane_count]bool,
    /// The next row that did not arrive yet, and the row after it.
    next: ?Row,
    after: ?Row,
};

fn look(w: *const sim.World) View {
    const speed = w.speed();
    var view: View = .{ .blocked_now = @splat(false), .next = null, .after = null };

    var rows: [max_rows]Row = undefined;
    var count: usize = 0;

    var it = @constCast(&w.entities).iterator();
    while (it.next()) |entry| {
        const e = entry.value;
        const gap = config.player_y - e.y;
        if (gap < -reach) continue; // fully behind the player

        if (e.kind == .block and gap < reach) {
            view.blocked_now[e.lane] = true;
            continue;
        }

        const seconds = (gap - reach) / speed;
        if (seconds <= 0) continue;

        var index: ?usize = null;
        for (rows[0..count], 0..) |*row, i| {
            if (row.y == e.y) {
                index = i;
                break;
            }
        }
        if (index == null) {
            if (count == max_rows) continue;
            rows[count] = .{
                .y = e.y,
                .seconds = seconds,
                .blocked = @splat(false),
                .coin_lane = null,
            };
            index = count;
            count += 1;
        }
        switch (e.kind) {
            .block => rows[index.?].blocked[e.lane] = true,
            .coin => rows[index.?].coin_lane = e.lane,
        }
    }

    // This game needs to look ahead only two rows. The spacing rule makes sure
    // that the player can cross the board between any two rows.
    for (rows[0..count]) |row| {
        if (view.next == null or row.seconds < view.next.?.seconds) {
            view.after = view.next;
            view.next = row;
        } else if (view.after == null or row.seconds < view.after.?.seconds) {
            view.after = row;
        }
    }
    return view;
}

/// The real position of the body of the player, as a continuous lane
/// coordinate.
fn position(w: *const sim.World) f32 {
    return w.player.x / config.lane_w - 0.5;
}

/// True if a slide from `from` to `to` touches a block that is level with the
/// player.
fn pathClear(from: f32, to: f32, blocked_now: [config.lane_count]bool) bool {
    const lo = @min(from, to) - sweep;
    const hi = @max(from, to) + sweep;
    for (blocked_now, 0..) |blocked, i| {
        if (!blocked) continue;
        const lane: f32 = @floatFromInt(i);
        if (lane > lo and lane < hi) return false;
    }
    return true;
}

/// The lane where the bot wants to be.
pub fn targetLane(w: *const sim.World) u8 {
    const current = w.player.lane;
    const pos = position(w);
    const view = look(w);

    var best: ?u8 = null;
    var best_cost: f32 = std.math.floatMax(f32);

    for (0..config.lane_count) |i| {
        const lane: u8 = @intCast(i);
        const lane_f: f32 = @floatFromInt(i);

        if (view.blocked_now[lane]) continue;
        if (view.next) |next| {
            if (next.blocked[lane]) continue;
        }
        if (!pathClear(pos, lane_f, view.blocked_now)) continue;

        const distance = @abs(lane_f - pos);
        const travel = distance * config.lane_change_time;
        if (view.next) |next| {
            if (travel + margin > next.seconds) continue;
        }

        var cost = distance;
        // Prefer a lane that is still good one row later. Then the bot does
        // not always have to solve the problem that it just made.
        if (view.after) |after| {
            if (after.blocked[lane]) cost += 1.5;
        }
        // Take a coin when the coin is on the path and the time is
        // sufficient. The bot limits its effort for coins. A dodge that fails
        // stops the run, but a coin that the bot does not get costs only a
        // multiplier.
        if (view.next) |next| {
            if (next.coin_lane == lane and next.seconds > travel * 2) cost -= 0.5;
        }
        if (cost < best_cost) {
            best_cost = cost;
            best = lane;
        }
    }

    // The bot cannot get to a safe lane. The spacing rule in config.zig must
    // make this impossible, and the tests check that. But if the policy
    // panicked here, a bad adjustment would crash the program.
    return best orelse current;
}

/// One tick of input. Lane changes are edge-triggered and have an effect
/// immediately. Thus a step of one lane in each tick gets to the target in a
/// few ticks. The slide itself is the part that takes real time.
pub fn play(w: *const sim.World) sim.Input {
    switch (w.phase) {
        .ready => return .{ .confirm = true },
        .dead => return .{ .confirm = w.death_time >= config.death_hold },
        .playing => {},
    }
    const target = targetLane(w);
    if (target < w.player.lane) return .{ .left = true };
    if (target > w.player.lane) return .{ .right = true };
    return .none;
}

test "the bot holds still on an empty field" {
    var w: sim.World = .init(1);
    w.start();
    w.entities.clear();
    try std.testing.expectEqual(sim.Input.none, play(&w));
}

test "the bot leaves a lane that is about to be blocked" {
    var w: sim.World = .init(1);
    w.start();
    w.entities.clear();
    _ = w.entities.create(.{
        .kind = .block,
        .lane = w.player.lane,
        .y = config.player_y - 300,
        .y_prev = config.player_y - 300,
    });
    try std.testing.expect(targetLane(&w) != w.player.lane);
}

test "the bot takes a coin in a lane it is already safe in" {
    var w: sim.World = .init(1);
    w.start();
    w.entities.clear();
    const other: u8 = w.player.lane + 1;
    _ = w.entities.create(.{
        .kind = .block,
        .lane = w.player.lane,
        .y = config.player_y - 400,
        .y_prev = config.player_y - 400,
    });
    _ = w.entities.create(.{
        .kind = .coin,
        .lane = other,
        .y = config.player_y - 400,
        .y_prev = config.player_y - 400,
    });
    try std.testing.expectEqual(other, targetLane(&w));
}

test "the bot refuses a move it cannot finish in time" {
    var w: sim.World = .init(1);
    w.start();
    w.entities.clear();
    _ = w.entities.create(.{
        .kind = .block,
        .lane = w.player.lane,
        .y = config.player_y - reach - 2,
        .y_prev = config.player_y - reach - 2,
    });
    try std.testing.expectEqual(w.player.lane, targetLane(&w));
}

test "the bot will not slide into a block that is still level with it" {
    // The regression that the fairness test found. A block whose centre is
    // behind the centre of the player can still overlap the player. If the bot
    // thinks that the block is behind it, the bot steers into the side of the
    // block.
    var w: sim.World = .init(1);
    w.start();
    w.entities.clear();
    const beside: u8 = w.player.lane + 1;
    _ = w.entities.create(.{
        .kind = .block,
        .lane = beside,
        // Behind the centre of the player, but well inside the overlap band.
        .y = config.player_y + reach * 0.8,
        .y_prev = config.player_y + reach * 0.8,
    });
    try std.testing.expect(targetLane(&w) != beside);
}

test "the bot will not cross a lane that is level with a block" {
    var w: sim.World = .init(1);
    w.start();
    w.entities.clear();
    // The player is in lane 0. A block is in the middle lane now. The far lane
    // is empty. To get to the far lane, the player must slide through the
    // block.
    w.player = .{ .lane = 0, .x = config.laneCenter(0), .x_prev = config.laneCenter(0) };
    _ = w.entities.create(.{
        .kind = .block,
        .lane = 1,
        .y = config.player_y,
        .y_prev = config.player_y,
    });
    _ = w.entities.create(.{
        .kind = .coin,
        .lane = 2,
        .y = config.player_y - 30,
        .y_prev = config.player_y - 30,
    });
    try std.testing.expectEqual(@as(u8, 0), targetLane(&w));
}
