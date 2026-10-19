//! title: Who Owns This Memory
//! Memory that stays valid after a call must come from a source and return.

const std = @import("std");

/// Fills a buffer from the caller. This function allocates nothing. Thus the
/// function owns nothing, and the caller has nothing to release.
fn writeGreeting(into: []u8, name: []const u8) []u8 {
    return std.mem.print(into, "hello, {s}", .{name}) catch into[0..0];
}

/// Returns memory of its own. The doc comment holds the rule: the caller owns
/// the result, and must free it with the same allocator.
fn makeGreeting(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return allocator.print("hello, {s}", .{name});
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // This memory is in the frame of this call, and it ends when main
    // returns. For the same reason, the function above cannot return memory
    // from its own frame.
    var scratch: [64]u8 = undefined;
    try out.print("{s}\n", .{writeGreeting(&scratch, "stack")});

    // This memory needs a request. Nothing in Zig allocates without an
    // allocator argument. Thus each place that can allocate says so.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const allocator = safe.allocator();

    {
        const greeting = try makeGreeting(allocator, "heap");
        defer allocator.free(greeting); // runs at the end of this block
        try out.print("{s}\n", .{greeting});
    }

    // deinit answers one question: how many allocations did the program not free?
    try out.print("allocations never freed: {d}\n\n", .{safe.deinit()});

    // The same program without the `defer`. At the end, the program asks the
    // allocator if the program freed all its memory, and the allocator answers.
    var leaky: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    {
        const greeting = try makeGreeting(leaky.allocator(), "forgotten");
        try out.print("{s}\n", .{greeting});
    }
    try out.print("allocations never freed: {d}\n", .{leaky.deinit()});

    try out.flush();
}
