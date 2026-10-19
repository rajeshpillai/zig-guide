//! title: Logging
//! std.log sends each message through one function that you can replace.

const std = @import("std");

// Zig reads `std_options` from the root of the program at compile time. The
// declaration has an effect here only because this snippet is an executable.
// A `zig test` file is not the root, and Zig ignores its std_options. The
// level .debug compiles in each level. By default, a release build removes
// the lower levels. A maximum for one scope overrides the global level.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .noisy, .level = .warn }, // .noisy logs only at warn and higher
    },
};

// A scoped logger puts the subsystem name on each line. Thus you can make the
// level of one area higher or lower, and not change the other areas.
const net = std.log.scoped(.net);

pub fn main(init: std.process.Init) void {
    _ = init;

    // Each level goes to stderr through std.options.logFn. The configured
    // level decides at compile time if each call is in the build.
    std.log.debug("resolving host", .{});
    std.log.info("connected in {d}ms", .{12});
    std.log.warn("slow response, retrying", .{});
    std.log.err("giving up after {d} tries", .{3});

    net.info("scoped line, tagged (net)", .{});

    // logEnabled is known at comptime. Thus an unused level costs nothing.
    std.debug.assert(std.log.logEnabled(.debug, .default)); // on, because the level is .debug
    std.debug.assert(!std.log.logEnabled(.info, .noisy)); // capped at .warn
    std.debug.assert(std.log.logEnabled(.warn, .noisy));
}
