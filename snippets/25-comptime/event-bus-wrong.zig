//! title: "Project: A Typed Event Bus, a Wrong Handler"
//! compile-fails
//! The bus from this chapter, given a handler for an event that `Event` does not have.

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

const Scroll = struct { dy: i32 };

fn logClick(out: *Writer, c: Click) !void {
    try out.print("click ({d}, {d})\n", .{ c.x, c.y });
}

fn logScroll(out: *Writer, s: Scroll) !void {
    try out.print("scroll {d}\n", .{s.dy});
}

const UiBus = Bus(Event, .{ logClick, logScroll });

pub fn main() void {
    std.debug.print("{d}\n", .{UiBus.count(.click)});
}
