//! title: The Repo
//! Composition root: schema, SQL, and a driver you can fake in tests.

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
