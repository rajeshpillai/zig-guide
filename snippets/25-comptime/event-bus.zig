//! title: "Project: A Typed Event Bus"
//! Handlers are plain functions. The bus reads their parameter types.

const std = @import("std");
const Writer = std.Io.Writer;

const Click = struct { x: i32, y: i32 };
const Key = struct { code: u8 };
const Resize = struct { width: u32, height: u32 };

const Event = union(enum) {
    click: Click,
    key: Key,
    resize: Resize,
};

// The payload type that a handler accepts: its second parameter.
fn Payload(comptime handler: anytype) type {
    const info = @typeInfo(@TypeOf(handler)).@"fn";
    if (info.param_types.len != 2) @compileError("a handler takes (*Writer, payload)");
    return info.param_types[1].?;
}

fn Bus(comptime E: type, comptime handlers: anytype) type {
    const variants = @typeInfo(E).@"union";
    // Each handler must accept the payload of one variant. A check here
    // gives one clear message, before any event exists.
    for (handlers, 0..) |handler, i| {
        const P = Payload(handler);
        for (variants.field_types) |V| {
            if (V == P) break;
        } else @compileError(std.fmt.comptimePrint(
            "handler {d} takes {s}, which is not a payload of {s}",
            .{ i, @typeName(P), @typeName(E) },
        ));
    }

    return struct {
        // The number of handlers for each variant, counted by the compiler.
        pub fn count(comptime tag: std.meta.Tag(E)) usize {
            var n: usize = 0;
            for (handlers) |handler| {
                if (Payload(handler) == @FieldType(E, @tagName(tag))) n += 1;
            }
            return n;
        }

        // One branch for each variant. Each branch calls only the handlers
        // for that variant, directly, in the order of the list.
        pub fn emit(out: *Writer, event: E) !void {
            switch (event) {
                inline else => |payload| {
                    inline for (handlers) |handler| {
                        if (comptime Payload(handler) == @TypeOf(payload)) {
                            try handler(out, payload);
                        }
                    }
                },
            }
        }
    };
}

var keys_pressed: usize = 0;

fn logClick(out: *Writer, c: Click) !void {
    try out.print("  logClick: ({d}, {d})\n", .{ c.x, c.y });
}

fn countKey(out: *Writer, k: Key) !void {
    keys_pressed += 1;
    try out.print("  countKey: code {d}, {d} so far\n", .{ k.code, keys_pressed });
}

fn quitOnEscape(out: *Writer, k: Key) !void {
    if (k.code == 27) try out.print("  quitOnEscape: escape, quit\n", .{});
}

const UiBus = Bus(Event, .{ logClick, countKey, quitOnEscape });

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    inline for (.{ .click, .key, .resize }) |tag| {
        try out.print("handlers for .{s}: {d}\n", .{ @tagName(tag), comptime UiBus.count(tag) });
    }

    const events = [_]Event{
        .{ .click = .{ .x = 10, .y = 20 } },
        .{ .key = .{ .code = 65 } },
        .{ .resize = .{ .width = 800, .height = 600 } },
        .{ .key = .{ .code = 27 } },
    };
    for (events) |event| {
        try out.print("emit .{t}\n", .{event});
        try UiBus.emit(out, event);
    }
}
