//! title: Unwrap a Null Optional
//! fails
//! `.?` asserts the optional is not null. When it is, the check fires.
//!
//! Built `.safe` rather than the site-wide `.small`. In `.small` the check
//! is gone, and a read of the payload of a null optional is undefined. CI
//! runs it and requires the message in `safety-null-unwrap.expected-error`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    var maybe: ?u32 = null;
    _ = &maybe; // stop comptime evaluation

    // `.?` is a claim: "this is not null, give me the payload". Here the claim
    // is false. Thus the check stops the program. The program does not return
    // the unknown bits that are in the payload.
    const value = maybe.?;

    std.debug.print("never printed: {d}\n", .{value});
}
