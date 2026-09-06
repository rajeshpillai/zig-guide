# Migrations as Data

> Schema history as an append-only list, and applying it as a pure plan.

## The problem

Schemas change after they ship. This is the discipline every mature ORM
converges on. Each change is a versioned migration with an up and a down, the
list is append-only, and the database records which version it is at. The
interesting engineering question is where the logic lives, because "compute
what to run" tends to get tangled into "run it", and then nothing is testable
without a database.

## The pattern

1. The history is data: an ordered array of `{version, up, down}`.
   Released entries are never edited, because someone's database already
   ran them.
2. The planner is a pure function: `plan(current, target)` returns the
   steps to execute, in order. Upgrades walk forward; downgrades walk
   the affected range newest-first.
3. Executing the plan is a separate, boring loop that belongs to the
   [repo](https://www.ziglang.in/learn/orm/repo/).

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`07-building-libraries.migrations`)*

## Purity is what makes the edge cases cheap

The four tests cover the cases that go wrong in real systems: the fresh
database, the partial upgrade, the rollback (in reverse order; forward order
corrupts), and the no-op. Each is an assertion about a function from two
integers to a slice. No fixtures, no containers, no cleanup. When the planner
and the executor are one function, every one of those tests needs a live
database and most never get written.

The split also buys `--dry-run` for free: print the plan instead of executing
it. Any operation your library can plan without performing is one users can
review before trusting.

## Append-only is a social contract, not a technical one

Nothing in the code stops someone editing migration 2 after release; the
guarantee is convention plus review. A library can help enforce it: the draft
stores a checksum of each applied migration and refuses to proceed when
history was rewritten under it. That check is, again, pure logic over data,
testable the same way.

## In a full ORM

The draft's migrations are Zig files discovered by the build, each exposing an
up and a down, with a CLI that creates, applies, and rolls back. The applied
version lives in a `schema_migrations` table; reading it and executing the
plan are the only parts that touch the database.
