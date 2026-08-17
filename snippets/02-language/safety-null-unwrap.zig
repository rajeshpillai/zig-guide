//! title: Unwrapping a Null Optional
//! fails
//! `.?` asserts the optional is not null. When it is, the check fires.
//!
//! Built `.safe` rather than the site-wide `.small`, because in `.small` the
//! check is gone and reading the payload of a null optional is undefined. CI
//! runs it and requires the message in `safety-null-unwrap.expected-error`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    var maybe: ?u32 = null;
    _ = &maybe; // defeat comptime evaluation

    // `.?` is a claim: "this is not null, give me the payload". The claim is
    // false here, so the check stops the program rather than handing back
    // whatever bits happened to be in the payload.
    const value = maybe.?;

    std.debug.print("never printed: {d}\n", .{value});
}
