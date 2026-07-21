//! title: Defer
//! Run something at scope exit, on every path.

const std = @import("std");
const expect = std.testing.expect;

test "defer runs at scope exit" {
    var x: i16 = 5;
    {
        defer x += 2;
        try expect(x == 5); // not yet
    }
    try expect(x == 7); // now
}

test "defers run in reverse order" {
    // Last registered runs first, so cleanup unwinds in the order things
    // were acquired.
    var order: [3]u8 = undefined;
    var index: usize = 0;
    {
        defer {
            order[index] = 1;
            index += 1;
        }
        defer {
            order[index] = 2;
            index += 1;
        }
        defer {
            order[index] = 3;
            index += 1;
        }
    }
    try expect(order[0] == 3);
    try expect(order[2] == 1);
}

fn mightFail(fail: bool) !u8 {
    var cleaned = false;
    // `errdefer` runs only when the function returns an error.
    errdefer cleaned = true;
    if (fail) return error.Nope;
    return @intFromBool(cleaned);
}

test "errdefer only fires on the error path" {
    try expect(try mightFail(false) == 0);
    try std.testing.expectError(error.Nope, mightFail(true));
}
