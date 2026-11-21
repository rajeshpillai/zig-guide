# The Repo

> The composition root, and the fake driver that lets you test the full ORM.

The Repo is the one stateful object in an Ecto-style ORM. It is also the only
part that talks to the database. In Zig, it is `Repo(Driver)`, and the driver
is a comptime parameter. Thus a test can give it a driver that records the SQL
and does not run it.

## The problem

Each part so far (schema, statements, dialects, plans) is pure. At some point,
the library must talk to a real database, and that point decides if you can
test the library.

- If database calls are in all parts of the code, each test needs Postgres.
- If the calls are behind one seam, you can test the full ORM against a fake.

The Ecto answer is the Repo, which holds the connection. Each operation goes
through the Repo. This page builds the skeleton of the Repo.

## The pattern

1. `Repo(Driver)` is a type function, as all other parts of this library are.
   The driver is a comptime parameter with a structural contract: an `exec`
   function that takes SQL.
2. The methods of the Repo combine the pure parts (the derived SQL of a Table)
   with one effect (`driver.exec`).
3. The test driver *records* the SQL and does not run it. The assertions read
   the log: the SQL that the database gets, and the order of that SQL.

```zig
const std = @import("std");
const expect = std.testing.expect;

// The test double for a database driver. It records each statement that the
// repo tells it to run. The test suite of the ORM runs against this driver.
// Only integration tests need a real database.
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

// Repo(Driver) is the composition root of the library. The driver arrives
// as a comptime parameter, in the same way that an allocator arrives as a
// runtime parameter. The caller selects the policy, and the library gives
// the mechanism.
fn Repo(comptime Driver: type) type {
    return struct {
        driver: *Driver,

        pub fn createTable(r: @This(), comptime T: type) !void {
            try r.driver.exec(T.create_sql);
        }

        pub fn insert(r: @This(), comptime T: type, row: T.Row) !void {
            // A real repo puts values into the parameter slots of the
            // statement. A record of the template shows exactly the SQL that
            // the database gets.
            _ = row;
            try r.driver.exec(T.insert_sql);
        }
    };
}

// A minimal Table. It has only enough code to show that the composition works.
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

## `RecordingDriver` is the test suite of the ORM

`RecordingDriver` is thirteen lines. With it, you can test each feature of the
library (inserts, transactions, migrations). Each test has one form: "for these
calls, exactly this SQL, in exactly this order". These tests check the behavior of
your library, and the database is not part of them.

A thin layer of integration tests against real SQLite and Postgres then tests
the drivers. No other test needs the drivers.

Look at the second test. A driver error (`error.ConnectionLost`) comes out
through the repo with no change. To pass errors through is a design decision,
so test it. If a library wraps or hides driver errors, the caller cannot react
to a specific error.

## Comptime parameter, runtime state

`Repo(Driver)` fixes the driver *type* at compile time. The driver *value*
arrives at runtime through the struct field, and it holds the connection
state.

This split follows the allocator convention of the standard library. The compiler
fixes the type of the driver, and the program gives its settings and state at
runtime. The split also makes the fake free at runtime. The repo that
compiles against `RecordingDriver` never contains a branch that asks which
driver it has.

## In a full ORM

The `repo.zig` file of the draft adds more to the Repo:

- The query path (`all`, `get`, `one`).
- The decode of results back into schema structs.
- Validation before writes.
- A pool checkout around each operation.

Each of these runs against `RecordingDriver` in its tests. Below them, the
shape of the skeleton on this page does not change.
