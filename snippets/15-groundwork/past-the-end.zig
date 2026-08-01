//! title: Reading Past the End
//! fails
//! What `slice[4]` does in a build with safety checks turned on.
//!
//! `//! fails` rather than `//! norun`: this is built `.safe` instead of the
//! site-wide `.small`, so the bounds check is present, and CI runs it and
//! requires it to stop with the message in `past-the-end.expected-error`. The
//! reader gets a Run button and watches it happen, and the message the chapter
//! quotes is checked every night rather than remembered.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    const row = [_]u32{ 10, 20, 30, 40 };
    const slice: []const u32 = &row;

    // `index` is a `var` whose value the compiler cannot fold, so this is not
    // rejected at compile time. The check that stops it runs while the program
    // is running, which is the whole point: the compiler cannot know.
    var index: usize = 4;
    _ = &index;

    std.debug.print("value: {d}\n", .{slice[index]});
}
