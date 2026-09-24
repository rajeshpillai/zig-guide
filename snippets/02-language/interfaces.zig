//! title: Interfaces
//! One idea, a sink that takes lines of text, built the four ways std builds an interface.

const std = @import("std");

// Two sinks. Neither knows the other exists.

const Counter = struct {
    lines: usize = 0,
    bytes: usize = 0,

    pub fn write(self: *Counter, line: []const u8) void {
        self.lines += 1;
        self.bytes += line.len;
    }

    pub fn sink(self: *Counter) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Sink.VTable = .{ .write = writeOpaque };

    fn writeOpaque(ptr: *anyopaque, line: []const u8) void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.write(line);
    }
};

const Last = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,

    pub fn write(self: *Last, line: []const u8) void {
        self.len = @min(line.len, self.buf.len);
        @memcpy(self.buf[0..self.len], line[0..self.len]);
    }

    pub fn text(self: *const Last) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn sink(self: *Last) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Sink.VTable = .{ .write = writeOpaque };

    fn writeOpaque(ptr: *anyopaque, line: []const u8) void {
        const self: *Last = @ptrCast(@alignCast(ptr));
        self.write(line);
    }
};

// 1. anytype: the compiler checks the shape at each call site.

fn sendAll(target: anytype, lines: []const []const u8) void {
    comptime requireSink(@TypeOf(target));
    for (lines) |line| target.write(line);
}

fn requireSink(comptime T: type) void {
    if (!std.meta.hasMethod(T, "write")) {
        @compileError(@typeName(T) ++ " is not a sink: it has no write method");
    }
}

// 2. A tagged union: a closed list of implementations.

const AnySink = union(enum) {
    counter: Counter,
    last: Last,

    pub fn write(self: *AnySink, line: []const u8) void {
        switch (self.*) {
            inline else => |*s| s.write(line),
        }
    }
};

// 3. A pointer and a vtable: the shape of std.mem.Allocator and std.Io.

const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, line: []const u8) void,
    };

    pub fn write(self: Sink, line: []const u8) void {
        self.vtable.write(self.ptr, line);
    }
};

// 4. An embedded interface: the shape of std.Io.Writer.

const Out = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (out: *Out, line: []const u8) void,
    };

    pub fn write(self: *Out, line: []const u8) void {
        self.vtable.write(self, line);
    }
};

const Shouter = struct {
    shouted: usize = 0,
    interface: Out = .{ .vtable = &vtable },

    const vtable: Out.VTable = .{ .write = write };

    fn write(out: *Out, line: []const u8) void {
        const self: *Shouter = @fieldParentPtr("interface", out);
        for (line) |c| {
            if (c == '!') self.shouted += 1;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const lines = [_][]const u8{ "boot", "disk ok", "network down!" };

    try out.print("-- anytype\n", .{});
    var counter: Counter = .{};
    var last: Last = .{};
    sendAll(&counter, &lines);
    sendAll(&last, &lines);
    try out.print("counter: {d} lines, {d} bytes\n", .{ counter.lines, counter.bytes });
    try out.print("last: \"{s}\"\n", .{last.text()});

    try out.print("-- tagged union\n", .{});
    var mixed = [_]AnySink{ .{ .counter = .{} }, .{ .last = .{} } };
    for (&mixed) |*s| {
        for (lines) |line| s.write(line);
    }
    try out.print("counter: {d} lines\n", .{mixed[0].counter.lines});
    try out.print("last: \"{s}\"\n", .{mixed[1].last.text()});

    try out.print("-- vtable\n", .{});
    var counter2: Counter = .{};
    var last2: Last = .{};
    const sinks = [_]Sink{ counter2.sink(), last2.sink() };
    for (sinks) |s| {
        for (lines) |line| s.write(line);
    }
    try out.print("counter: {d} lines\n", .{counter2.lines});
    try out.print("last: \"{s}\"\n", .{last2.text()});
    try out.print("a Sink is two pointers: {}\n", .{@sizeOf(Sink) == 2 * @sizeOf(usize)});

    try out.print("-- embedded\n", .{});
    var shouter: Shouter = .{};
    const iface = &shouter.interface;
    for (lines) |line| iface.write(line);
    try out.print("shouted: {d}\n", .{shouter.shouted});

    try out.flush();
}
