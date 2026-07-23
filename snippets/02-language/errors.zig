//! title: Errors
//! Errors are values, returned in an error union, never thrown.

const std = @import("std");
const expect = std.testing.expect;

const FileOpenError = error{
    AccessDenied,
    OutOfMemory,
    FileNotFound,
};

// Error sets coerce into supersets, so a narrow error can be returned
// from a function that declares a wider set.
const AllocationError = error{OutOfMemory};

test "error set coercion" {
    const err: FileOpenError = AllocationError.OutOfMemory;
    try expect(err == FileOpenError.OutOfMemory);
}

fn failingFunction() error{Oops}!void {
    return error.Oops;
}

test "catch supplies a fallback" {
    // `!u8` is shorthand for "some inferred error set, or u8".
    const parsed = std.fmt.parseInt(u8, "not a number", 10) catch 0;
    try expect(parsed == 0);
}

test "try propagates" {
    // `try x` is `x catch |err| return err`.
    try std.testing.expectError(error.Oops, failingFunction());
}

test "capture the error in catch" {
    var captured: anyerror = undefined;
    failingFunction() catch |err| {
        captured = err;
    };
    try expect(captured == error.Oops);
}

fn parseOrDefault(text: []const u8) u32 {
    // `if` can unwrap an error union too, with `else |err|`.
    if (std.fmt.parseInt(u32, text, 10)) |value| {
        return value;
    } else |_| {
        return 0;
    }
}

test "if on an error union" {
    try expect(parseOrDefault("42") == 42);
    try expect(parseOrDefault("abc") == 0);
}
