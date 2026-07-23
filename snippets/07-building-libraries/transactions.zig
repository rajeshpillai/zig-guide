//! title: Transactions and errdefer
//! COMMIT on success, ROLLBACK on any error path, enforced by the shape.

const std = @import("std");
const expect = std.testing.expect;

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

fn Repo(comptime Driver: type) type {
    return struct {
        driver: *Driver,

        // The whole transaction contract in four lines. errdefer fires
        // on every error return between BEGIN and COMMIT, so there is
        // no path that leaves the transaction open: not an early return,
        // not a failure inside the callback, not a failed COMMIT.
        pub fn transaction(r: @This(), body: anytype) !void {
            try r.driver.exec("BEGIN");
            errdefer r.driver.exec("ROLLBACK") catch {};
            try body.run(r);
            try r.driver.exec("COMMIT");
        }
    };
}

const R = Repo(RecordingDriver);

test "success path commits" {
    var driver = RecordingDriver{ .gpa = std.testing.allocator };
    defer driver.deinit();

    const body = struct {
        fn run(_: @This(), repo: R) !void {
            try repo.driver.exec("INSERT INTO users");
        }
    }{};
    try (R{ .driver = &driver }).transaction(body);

    try expect(driver.log.items.len == 3);
    try expect(std.mem.eql(u8, driver.log.items[0], "BEGIN"));
    try expect(std.mem.eql(u8, driver.log.items[1], "INSERT INTO users"));
    try expect(std.mem.eql(u8, driver.log.items[2], "COMMIT"));
}

test "a failing body rolls back and the error escapes" {
    var driver = RecordingDriver{ .gpa = std.testing.allocator };
    defer driver.deinit();

    const body = struct {
        fn run(_: @This(), repo: R) !void {
            try repo.driver.exec("INSERT INTO users");
            return error.ValidationFailed;
        }
    }{};
    try std.testing.expectError(
        error.ValidationFailed,
        (R{ .driver = &driver }).transaction(body),
    );

    // The work happened, then was rolled back; nothing was committed.
    try expect(driver.log.items.len == 3);
    try expect(std.mem.eql(u8, driver.log.items[0], "BEGIN"));
    try expect(std.mem.eql(u8, driver.log.items[2], "ROLLBACK"));
}
