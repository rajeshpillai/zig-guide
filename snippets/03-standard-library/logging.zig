//! title: Logging
//! std.log routes every message through one replaceable function.

const std = @import("std");

// `std_options` is read from the root of the program at compile time, so it
// only takes effect here because this snippet is an executable (a `zig test`
// file is not the root, and its std_options would be ignored). Setting the
// level to .debug compiles in every level; a release build drops the chatty
// ones by default. A per-scope cap overrides the global level for one area.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .noisy, .level = .warn }, // .noisy logs only from warn up
    },
};

// A scoped logger tags every line with its subsystem, so you can raise or
// lower one area without touching the rest.
const net = std.log.scoped(.net);

pub fn main(init: std.process.Init) void {
    _ = init;

    // Every level goes to stderr through std.options.logFn. Each call is
    // compiled in or out by the configured level, not gated at run time.
    std.log.debug("resolving host", .{});
    std.log.info("connected in {d}ms", .{12});
    std.log.warn("slow response, retrying", .{});
    std.log.err("giving up after {d} tries", .{3});

    net.info("scoped line, tagged (net)", .{});

    // logEnabled is comptime-known, so an unused level costs nothing at all.
    std.debug.assert(std.log.logEnabled(.debug, .default)); // on, we set .debug
    std.debug.assert(!std.log.logEnabled(.info, .noisy)); // capped at .warn
    std.debug.assert(std.log.logEnabled(.warn, .noisy));
}
