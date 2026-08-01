//! title: Who Owns This Memory
//! Memory that outlives a call has to come from somewhere, and go back.

const std = @import("std");

/// Fills a caller-supplied buffer. This function allocates nothing, so there
/// is nothing for it to own and nothing for the caller to release.
fn writeGreeting(into: []u8, name: []const u8) []u8 {
    return std.mem.print(into, "hello, {s}", .{name}) catch into[0..0];
}

/// Returns memory of its own. The doc comment is where the rule lives: the
/// caller owns the result and has to free it with the same allocator.
fn makeGreeting(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return allocator.print("hello, {s}", .{name});
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // Memory you can point at. It lives in this call's frame and is gone when
    // main returns, which is exactly why the function above cannot return it.
    var scratch: [64]u8 = undefined;
    try out.print("{s}\n", .{writeGreeting(&scratch, "stack")});

    // Memory that has to be asked for. Nothing in Zig allocates without an
    // allocator argument, so the places that can are the places that say so.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const allocator = safe.allocator();

    {
        const greeting = try makeGreeting(allocator, "heap");
        defer allocator.free(greeting); // runs when this block ends
        try out.print("{s}\n", .{greeting});
    }

    // deinit answers one question: how many allocations were never returned.
    try out.print("allocations never freed: {d}\n\n", .{safe.deinit()});

    // The same program with the `defer` removed. The allocator is asked at the
    // end whether everything it handed out came back, and it says so.
    var leaky: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    {
        const greeting = try makeGreeting(leaky.allocator(), "forgotten");
        try out.print("{s}\n", .{greeting});
    }
    try out.print("allocations never freed: {d}\n", .{leaky.deinit()});

    try out.flush();
}
