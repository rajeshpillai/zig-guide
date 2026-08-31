//! A policy that plays the game.
//!
//! This exists for two reasons. It drives the attract mode behind the title
//! screen, so the game demonstrates itself. More importantly it is how the
//! course generator is tested: a level designer can promise that every row
//! leaves a gap, but the promise that matters is that a player can actually
//! reach the gap in the time available, at every speed on the ramp. That is a
//! claim about four constants interacting, and the honest way to check it is to
//! play the game for an hour and see. The tests do, at every seed, in about a
//! second.
//!
//! The bot reasons about where the player physically *is*, never about which
//! lane they are steering towards. Those differ for `lane_change_time` after
//! every press, and a bot that confuses them will happily slide its body
//! through a block it believes it has already dodged.

const std = @import("std");
const sim = @import("sim.zig");
const config = @import("config.zig");

/// Vertical half-span within which a block and the player overlap. A block is
/// dangerous from `+reach` ahead of the player until `-reach` behind: using
/// only the block's own half-height here is the classic off-by-one-body bug.
const reach = config.player_half_h + config.block_half_h;

/// Horizontal overlap between player and block, in lanes. A slide from lane 0
/// to lane 2 clips anything sitting within this much of the path.
const sweep = (config.player_half_w + config.block_half_w) / config.lane_w;

/// Refuse a crossing that would finish this close to the deadline.
const margin = config.lane_change_time * 0.3;

const max_rows = 16;

const Row = struct {
    /// Rows are laid down at a single y and advance together, so y identifies
    /// a row exactly.
    y: f32,
    /// Seconds until this row begins to overlap the player.
    seconds: f32,
    blocked: [config.lane_count]bool,
    coin_lane: ?u8,
};

const View = struct {
    /// Lanes with a block level with the player right now. Entering one is an
    /// immediate crash, and crossing one is the same crash a moment later.
    blocked_now: [config.lane_count]bool,
    /// The next row that has not arrived yet, and the one after it.
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

    // The two soonest rows are all the lookahead this game needs: the spacing
    // rule guarantees the board can be crossed between any two of them.
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

/// Where the player's body actually is, as a continuous lane coordinate.
fn position(w: *const sim.World) f32 {
    return w.player.x / config.lane_w - 0.5;
}

/// Would sliding from `from` to `to` clip a block that is level with us?
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

/// The lane the bot wants to be in.
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
        // Prefer somewhere that is still good one row later, so the bot is not
        // forever solving the problem it just created.
        if (view.after) |after| {
            if (after.blocked[lane]) cost += 1.5;
        }
        // Take a coin when it is on the way and there is comfortable time.
        // Greed is capped: a missed dodge costs the run, a missed coin costs a
        // multiplier.
        if (view.next) |next| {
            if (next.coin_lane == lane and next.seconds > travel * 2) cost -= 0.5;
        }
        if (cost < best_cost) {
            best_cost = cost;
            best = lane;
        }
    }

    // Nothing safe is reachable. The spacing rule in config.zig is supposed to
    // make this impossible and the tests assert as much, but a policy that
    // panics here would be a policy that turns a tuning mistake into a crash.
    return best orelse current;
}

/// One tick of input. Lane changes are edge-triggered and take effect
/// immediately, so stepping one lane per tick converges in a few ticks and the
/// slide itself is what takes real time.
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
    // The regression that the fairness test caught: a block whose centre is
    // behind the player's centre can still be overlapping it. Treating it as
    // passed makes the bot steer straight into its side.
    var w: sim.World = .init(1);
    w.start();
    w.entities.clear();
    const beside: u8 = w.player.lane + 1;
    _ = w.entities.create(.{
        .kind = .block,
        .lane = beside,
        // Behind the player's centre, but well inside the overlap band.
        .y = config.player_y + reach * 0.8,
        .y_prev = config.player_y + reach * 0.8,
    });
    try std.testing.expect(targetLane(&w) != beside);
}

test "the bot will not cross a lane that is level with a block" {
    var w: sim.World = .init(1);
    w.start();
    w.entities.clear();
    // Player in lane 0, middle lane occupied right now, far lane invitingly
    // empty. Reaching it means sliding through the block.
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
