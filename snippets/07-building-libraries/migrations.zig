//! title: Migrations as Data
//! Schema changes are a versioned list; applying them is a pure plan.

const std = @import("std");
const expect = std.testing.expect;

const Migration = struct {
    version: u32,
    up: []const u8,
    down: []const u8,
};

// The whole history, in order. Append-only: released migrations are
// never edited, because someone's database already ran them.
const history = [_]Migration{
    .{
        .version = 1,
        .up = "CREATE TABLE users (id INTEGER, name TEXT)",
        .down = "DROP TABLE users",
    },
    .{
        .version = 2,
        .up = "CREATE TABLE posts (id INTEGER, title TEXT)",
        .down = "DROP TABLE posts",
    },
    .{
        .version = 3,
        .up = "ALTER TABLE users ADD COLUMN active INTEGER",
        .down = "ALTER TABLE users DROP COLUMN active",
    },
};

const Step = struct { version: u32, sql: []const u8 };

// The planner is a pure function from (current, target) to steps. All
// the subtle cases (no-op, partial upgrade, rollback ordering) are
// testable without a database anywhere in sight.
fn plan(current: u32, target: u32, buf: []Step) []Step {
    var n: usize = 0;
    if (target > current) {
        for (history) |m| {
            if (m.version > current and m.version <= target) {
                buf[n] = .{ .version = m.version, .sql = m.up };
                n += 1;
            }
        }
    } else {
        // Downgrades run the down steps newest-first.
        var i = history.len;
        while (i > 0) {
            i -= 1;
            const m = history[i];
            if (m.version <= current and m.version > target) {
                buf[n] = .{ .version = m.version, .sql = m.down };
                n += 1;
            }
        }
    }
    return buf[0..n];
}

test "a fresh database applies everything in order" {
    var buf: [8]Step = undefined;
    const steps = plan(0, 3, &buf);
    try expect(steps.len == 3);
    try expect(steps[0].version == 1);
    try expect(steps[2].version == 3);
    try expect(std.mem.startsWith(u8, steps[0].sql, "CREATE TABLE users"));
}

test "partial upgrade takes only the gap" {
    var buf: [8]Step = undefined;
    const steps = plan(1, 3, &buf);
    try expect(steps.len == 2);
    try expect(steps[0].version == 2);
    try expect(steps[1].version == 3);
}

test "rollback runs down steps newest-first" {
    var buf: [8]Step = undefined;
    const steps = plan(3, 1, &buf);
    try expect(steps.len == 2);
    try expect(steps[0].version == 3);
    try expect(std.mem.startsWith(u8, steps[0].sql, "ALTER TABLE users DROP"));
    try expect(steps[1].version == 2);
}

test "already there is a no-op" {
    var buf: [8]Step = undefined;
    try expect(plan(3, 3, &buf).len == 0);
}
