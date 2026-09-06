# Transactions and errdefer

> COMMIT on success, ROLLBACK on every error path, enforced by four lines.

## The problem

A transaction wrapper has one job: no path may leave the transaction open.
Languages solve it with `defer`, context managers, or RAII. The bugs live in
the paths someone forgot: the early return, the error between two statements,
the failed COMMIT itself. Zig's `errdefer` was built for exactly this shape,
and a library API is where it earns its keep.

## The pattern

The entire contract:

```zig
try r.driver.exec("BEGIN");
errdefer r.driver.exec("ROLLBACK") catch {};
try body.run(r);
try r.driver.exec("COMMIT");
```

Every `try` after the `errdefer` is covered by it: an error inside the
caller's body, or in COMMIT itself, fires the ROLLBACK and propagates the
original error. Success skips the `errdefer` entirely. There is no path that
reaches the function's end with the transaction open, and you can verify that
by reading four lines rather than auditing every return.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`07-building-libraries.transactions`)*

## Why the ROLLBACK swallows its own error

Discarding the error from the ROLLBACK is deliberate, and worth documenting in
a real library. The wrapper is already unwinding with the caller's error,
which is the one that explains what went wrong. Replacing it with a secondary
"and also the rollback failed" error would hide the cause. A production
library logs the rollback failure; it still propagates the original.

## The callback shape

`body` is anytype with a `run` method, the snippet's stand-in for a closure.
The caller's work runs *inside* the wrapper's frame, which is what lets
`errdefer` see its errors. The same shape appears anywhere a library brackets
user code: arena-per-request handlers, file locks, the draft's pool checkout
(acquire, run, always release).

## In a full ORM

Real transactions nest (SAVEPOINT instead of BEGIN when already inside one),
which the draft tracks with a depth counter on the connection; the errdefer
shape is identical at every depth. The recording-driver tests from [the
previous page](https://www.ziglang.in/learn/orm/repo/) extend naturally: assert
BEGIN/SAVEPOINT/ROLLBACK sequences for the nested cases.
