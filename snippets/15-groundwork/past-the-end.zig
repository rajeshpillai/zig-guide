//! title: Reading Past the End
//! fails
//! What `slice[4]` does in a build with safety checks turned on.
//!
//! This snippet uses the fails marker, not the norun marker. The build is
//! `.safe`, not the `.small` of the other snippets. Thus the bounds check is
//! present. CI runs the program, and the program must stop with the message
//! in `past-the-end.expected-error`. The reader gets a Run button and sees the
//! stop. CI checks the message in the chapter each night.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    const row = [_]u32{ 10, 20, 30, 40 };
    const slice: []const u32 = &row;

    // `index` is a `var`, and the compiler cannot fold its value. Thus the
    // compiler does not reject this line. The compiler cannot know the index.
    // Thus the check that stops the read runs when the program runs.
    var index: usize = 4;
    _ = &index;

    std.debug.print("value: {d}\n", .{slice[index]});
}
