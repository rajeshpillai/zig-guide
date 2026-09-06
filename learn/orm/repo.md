# The Repo

> The composition root, and the fake driver that makes the whole ORM testable.

## The problem

Every piece so far (schema, statements, dialects, plans) is pure. At
some point the library must actually talk to a database, and that point
decides whether the library is testable. Put database calls everywhere
and every test needs Postgres; put them behind one seam and the entire
ORM tests against a fake.

Ecto's answer is the Repo: the one stateful object, holding the
connection, through which every operation flows. This page builds its
skeleton.

## The pattern

1. `Repo(Driver)` is a type function, like everything else in this
   library: the driver is a comptime parameter with a structural
   contract (an `exec` that takes SQL).
2. Repo methods compose the pure pieces (a Table's derived SQL) with
   one effect (`driver.exec`).
3. The test driver *records* instead of executing. Assertions read the
   log: what would have reached the database, in what order.

```zig
const std = @import("std");
const expect = std.testing.expect;

// The test double for a database driver: it records every statement it
// is asked to execute. The ORM's own test suite runs against this; only
// integration tests need a real database.
const RecordingDriver = struct {
    gpa: std.mem.Allocator,
    log: std.ArrayList([]const u8) = .empty,

    pub fn exec(d: *RecordingDriver, sql: []const u8) !void {
        try d.log.append(d.gpa, try d.gpa.dupe(u8, sql));
    }

    pub fn deinit(d: *RecordingDriver) void {
        for (d.log.items) |sql| d.gpa.free(sql);
        d.log.deinit(d.gpa);
    }
};

// Repo(Driver) is the library's composition root. The driver arrives as
// a comptime parameter, exactly like the allocator arrives as a runtime
// one: the caller owns the policy, the library owns the mechanism.
fn Repo(comptime Driver: type) type {
    return struct {
        driver: *Driver,

        pub fn createTable(r: @This(), comptime T: type) !void {
            try r.driver.exec(T.create_sql);
        }

        pub fn insert(r: @This(), comptime T: type, row: T.Row) !void {
            // A real repo renders values into the statement's parameter
            // slots; recording the template keeps the fake honest about
            // what would reach the wire.
            _ = row;
            try r.driver.exec(T.insert_sql);
        }
    };
}

// A minimal Table, just enough for the composition to be real.
fn Table(comptime T: type, comptime name: []const u8) type {
    return struct {
        pub const Row = T;
        pub const create_sql = "CREATE TABLE " ++ name;
        pub const insert_sql = "INSERT INTO " ++ name;
    };
}

const User = struct { id: i64 };
const Users = Table(User, "users");

test "the repo drives the driver in order" {
    var driver = RecordingDriver{ .gpa = std.testing.allocator };
    defer driver.deinit();

    const repo = Repo(RecordingDriver){ .driver = &driver };
    try repo.createTable(Users);
    try repo.insert(Users, .{ .id = 1 });
    try repo.insert(Users, .{ .id = 2 });

    try expect(driver.log.items.len == 3);
    try expect(std.mem.eql(u8, driver.log.items[0], "CREATE TABLE users"));
    try expect(std.mem.eql(u8, driver.log.items[1], "INSERT INTO users"));
    try expect(std.mem.eql(u8, driver.log.items[2], "INSERT INTO users"));
}

test "a failing driver surfaces its error unchanged" {
    const FailingDriver = struct {
        pub fn exec(_: *@This(), _: []const u8) !void {
            return error.ConnectionLost;
        }
    };
    var driver = FailingDriver{};
    const repo = Repo(FailingDriver){ .driver = &driver };
    try std.testing.expectError(error.ConnectionLost, repo.createTable(Users));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`07-building-libraries.repo`)*

## The recording driver is the ORM's test suite

This is the page's real lesson. `RecordingDriver` is twelve lines, and
with it every feature of the library (inserts, transactions, migration
execution) is testable as "given these calls, exactly this SQL, in
exactly this order". The database's behavior is not being tested; your
library's is. A thin layer of integration tests against real SQLite and
Postgres then covers the drivers themselves, and nothing else needs
them.

Note the second test: a driver error (`error.ConnectionLost`) surfaces
through the repo unchanged. Error passthrough is a design decision worth
testing; a library that wraps or swallows driver errors robs the caller
of the ability to react to specific ones.

## Comptime parameter, runtime state

`Repo(Driver)` fixes the driver *type* at compile time, but the driver
*value* arrives at runtime through the struct field, carrying its
connection state. That split mirrors the standard library's allocator
convention: mechanism chosen early, policy and state injected late.
It is also what makes the fake possible at zero cost; the repo compiled
against `RecordingDriver` never contains a branch asking which driver
it has.

## In a full ORM

The draft's `repo.zig` adds the query path (`all`, `get`, `one`),
result decoding back into schema structs, validation before writes, and
pool checkout around each operation. Every one of those runs against
the recording driver in its tests, and the shape of this page's
skeleton is unchanged underneath.
