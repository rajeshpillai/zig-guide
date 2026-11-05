# Transactions and errdefer

> COMMIT on success, ROLLBACK on each error path, enforced by four lines.

In Zig, a transaction wrapper does these steps:

1. Run `BEGIN`.
2. Register an `errdefer` that runs `ROLLBACK`.
3. Run the work of the caller.
4. Run `COMMIT`.

An error at any point after the `errdefer`, also in `COMMIT`, rolls the
transaction back and returns the original error.

## The problem

A transaction wrapper has one job: no path can leave the transaction open.
Languages solve this problem with `defer`, context managers or RAII.

The bugs are in the paths that a programmer forgot: the early return, the error
between two statements, the failed COMMIT. The designers of Zig made `errdefer`
for this case, and a library API is a good place to use it.

## The pattern

This is the full contract:

```zig
try r.driver.exec("BEGIN");
errdefer r.driver.exec("ROLLBACK") catch {};
try body.run(r);
try r.driver.exec("COMMIT");
```

The `errdefer` covers each `try` after it. On success, the `errdefer` does not
run. No path reaches the end of the function with the transaction open. You can
verify that when you read four lines, and you do not have to examine each
return.

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

        // These four lines are the transaction contract. errdefer runs on
        // each error return between BEGIN and COMMIT. Thus no path leaves
        // the transaction open: not an early return, not a failure inside
        // the callback, and not a failed COMMIT.
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

    // The work ran, and then the wrapper rolled it back. No commit occurred.
    try expect(driver.log.items.len == 3);
    try expect(std.mem.eql(u8, driver.log.items[0], "BEGIN"));
    try expect(std.mem.eql(u8, driver.log.items[2], "ROLLBACK"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`07-building-libraries.transactions`)*

## Why the ROLLBACK discards its own error

The wrapper discards the error from the ROLLBACK on purpose. A real library
must document this decision.

The wrapper already returns with the error of the caller, and that error
explains the problem. A second error, "and also the rollback failed", in place
of the first error, hides the cause. A production library logs the rollback
failure, but it still returns the original error.

## The callback shape

`body` is `anytype` with a `run` method. In the snippet, it takes the place of
a closure. The work of the caller runs *inside* the frame of the wrapper. Thus
`errdefer` can see the errors of that work.

The same shape occurs each time that a library puts user code between a start
and an end:

- Handlers with one arena for each request.
- File locks.
- The pool checkout of the draft (acquire, run, always release).

## In a full ORM

Real transactions nest: the inner one uses SAVEPOINT in place of BEGIN. The
draft keeps the depth in a counter on the connection. The `errdefer` shape is
the same at each depth.

The tests with `RecordingDriver` from [the previous
page](https://www.ziglang.in/learn/orm/repo/) extend easily to this case. They assert the
BEGIN/SAVEPOINT/ROLLBACK sequences for the nested cases.
