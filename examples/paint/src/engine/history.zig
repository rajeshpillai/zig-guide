//! Undo and redo.
//!
//! Before an action changes a layer, the history copies the rectangle the
//! action is about to change. That copy is all it keeps. A stroke across a
//! corner of a 640 by 400 layer stores the corner, not the layer.
//!
//! Undo swaps the copy with what the layer holds now. After the swap the copy
//! holds the newer pixels, so redo is the same swap again. One operation does
//! both jobs.
//!
//! Lesson 60 keeps two stacks, past and future. Here they are one array and an
//! index: entries before `cursor` can be undone, entries from `cursor` on can
//! be redone. Moving between them is moving the index, so undo and redo never
//! allocate and cannot fail.
//!
//! The history has a memory budget in bytes (lesson 61). When a new entry
//! would go over it, the oldest entries are dropped. When memory runs out,
//! the action still happens. Only the undo for it is lost, and `record` says
//! so.

const std = @import("std");
const Rect = @import("geometry.zig").Rect;
const Rgba = @import("pixel.zig").Rgba;

pub const Entry = struct {
    layer: u32,
    rect: Rect,
    /// `rect.area()` pixels, row by row.
    pixels: []Rgba,

    fn bytes(e: Entry) usize {
        return e.pixels.len * @sizeOf(Rgba);
    }
};

pub const History = struct {
    entries: std.ArrayList(Entry) = .empty,
    cursor: usize = 0,
    budget: usize,
    used: usize = 0,

    pub fn init(budget: usize) History {
        return .{ .budget = budget };
    }

    pub fn deinit(h: *History, gpa: std.mem.Allocator) void {
        for (h.entries.items) |e| gpa.free(e.pixels);
        h.entries.deinit(gpa);
    }

    pub fn canUndo(h: History) bool {
        return h.cursor > 0;
    }

    pub fn canRedo(h: History) bool {
        return h.cursor < h.entries.items.len;
    }

    /// Copy `rect` of `layer` before an action changes it. Returns false when
    /// the copy could not be kept, either because it alone is larger than the
    /// budget or because memory ran out. The action should go ahead anyway.
    pub fn record(
        h: *History,
        gpa: std.mem.Allocator,
        layer: u32,
        pixels: []const Rgba,
        width: u32,
        rect: Rect,
    ) bool {
        if (rect.isEmpty()) return true;

        // A new action starts a new branch. What could have been redone no
        // longer follows from the picture, so it goes (lesson 60).
        h.dropFrom(gpa, h.cursor);

        const need = rect.area() * @sizeOf(Rgba);
        if (need > h.budget) {
            // Even an empty history could not hold this one. Keeping the old
            // entries would let undo skip over this action and restore a
            // picture that never existed, so they go too.
            h.dropFrom(gpa, 0);
            return false;
        }
        while (h.used + need > h.budget) h.dropOldest(gpa);

        // Make room in the list first, so a failure after the copy has been
        // made cannot leave a copy that nothing owns.
        while (true) {
            if (h.entries.ensureUnusedCapacity(gpa, 1)) |_| break else |_| {}
            if (h.entries.items.len == 0) return false;
            h.dropOldest(gpa);
        }
        const copy = while (true) {
            if (gpa.alloc(Rgba, rect.area())) |buf| break buf else |_| {}
            if (h.entries.items.len == 0) return false;
            h.dropOldest(gpa);
        };

        var i: usize = 0;
        var y = rect.y0;
        while (y < rect.y1) : (y += 1) {
            const row = @as(usize, y) * width;
            @memcpy(copy[i..][0..rect.width()], pixels[row + rect.x0 .. row + rect.x1]);
            i += rect.width();
        }
        h.entries.appendAssumeCapacity(.{ .layer = layer, .rect = rect, .pixels = copy });
        h.cursor = h.entries.items.len;
        h.used += need;
        return true;
    }

    /// Undo the newest action. Returns the entry so the caller knows which
    /// layer and rectangle to redraw, or null when there is nothing to undo.
    pub fn undo(h: *History, layers: []const []Rgba, width: u32) ?Entry {
        if (!h.canUndo()) return null;
        h.cursor -= 1;
        const e = h.entries.items[h.cursor];
        swap(e, layers[e.layer], width);
        return e;
    }

    pub fn redo(h: *History, layers: []const []Rgba, width: u32) ?Entry {
        if (!h.canRedo()) return null;
        const e = h.entries.items[h.cursor];
        swap(e, layers[e.layer], width);
        h.cursor += 1;
        return e;
    }

    fn swap(e: Entry, layer: []Rgba, width: u32) void {
        var i: usize = 0;
        var y = e.rect.y0;
        while (y < e.rect.y1) : (y += 1) {
            const row = @as(usize, y) * width;
            for (layer[row + e.rect.x0 .. row + e.rect.x1], e.pixels[i..][0..e.rect.width()]) |*a, *b| {
                std.mem.swap(Rgba, a, b);
            }
            i += e.rect.width();
        }
    }

    fn dropOldest(h: *History, gpa: std.mem.Allocator) void {
        const e = h.entries.orderedRemove(0);
        h.used -= e.bytes();
        gpa.free(e.pixels);
        if (h.cursor > 0) h.cursor -= 1;
    }

    fn dropFrom(h: *History, gpa: std.mem.Allocator, start: usize) void {
        for (h.entries.items[start..]) |e| {
            h.used -= e.bytes();
            gpa.free(e.pixels);
        }
        h.entries.shrinkRetainingCapacity(start);
        h.cursor = @min(h.cursor, start);
    }
};

const testing = std.testing;

fn fillRect(layer: []Rgba, width: u32, rect: Rect, value: u8) void {
    var y = rect.y0;
    while (y < rect.y1) : (y += 1) {
        const row = @as(usize, y) * width;
        @memset(layer[row + rect.x0 .. row + rect.x1], .{ .r = value, .g = value, .b = value, .a = 255 });
    }
}

test "undo restores, redo repeats, and both can go back and forth" {
    const gpa = testing.allocator;
    var layer: [8 * 8]Rgba = @splat(.transparent);
    const layers = [_][]Rgba{&layer};
    var h: History = .init(1 << 20);
    defer h.deinit(gpa);

    const rect: Rect = .{ .x0 = 2, .y0 = 2, .x1 = 5, .y1 = 4 };
    try testing.expect(h.record(gpa, 0, &layer, 8, rect));
    fillRect(&layer, 8, rect, 9);
    const drawn = layer;

    _ = h.undo(&layers, 8).?;
    const empty: [8 * 8]Rgba = @splat(.transparent);
    try testing.expectEqual(empty, layer);
    _ = h.redo(&layers, 8).?;
    try testing.expectEqual(drawn, layer);
    _ = h.undo(&layers, 8).?;
    _ = h.redo(&layers, 8).?;
    try testing.expectEqual(drawn, layer);

    try testing.expect(h.redo(&layers, 8) == null);
}

test "lesson 60: drawing after an undo drops the redo branch" {
    const gpa = testing.allocator;
    var layer: [8 * 8]Rgba = @splat(.transparent);
    const layers = [_][]Rgba{&layer};
    var h: History = .init(1 << 20);
    defer h.deinit(gpa);

    const a: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 2 };
    const b: Rect = .{ .x0 = 4, .y0 = 4, .x1 = 6, .y1 = 6 };
    _ = h.record(gpa, 0, &layer, 8, a);
    fillRect(&layer, 8, a, 1);
    _ = h.record(gpa, 0, &layer, 8, b);
    fillRect(&layer, 8, b, 2);

    _ = h.undo(&layers, 8); // B is undone
    _ = h.record(gpa, 0, &layer, 8, b); // C, drawn where B was
    fillRect(&layer, 8, b, 3);

    try testing.expect(!h.canRedo()); // B cannot come back
    try testing.expectEqual(@as(usize, 2), h.entries.items.len);
}

test "lesson 61: the budget drops the oldest entries" {
    const gpa = testing.allocator;
    var layer: [8 * 8]Rgba = @splat(.transparent);
    const layers = [_][]Rgba{&layer};
    // Room for exactly three 2x2 copies.
    var h: History = .init(3 * 4 * @sizeOf(Rgba));
    defer h.deinit(gpa);

    for (0..5) |i| {
        const x: u32 = @intCast(i);
        const r: Rect = .{ .x0 = x, .y0 = 0, .x1 = x + 2, .y1 = 2 };
        try testing.expect(h.record(gpa, 0, &layer, 8, r));
        fillRect(&layer, 8, r, @intCast(i + 1));
        try testing.expect(h.used <= h.budget);
    }
    try testing.expectEqual(@as(usize, 3), h.entries.items.len);
    var undone: usize = 0;
    while (h.undo(&layers, 8) != null) undone += 1;
    try testing.expectEqual(@as(usize, 3), undone);
}

test "an entry larger than the whole budget clears the history" {
    const gpa = testing.allocator;
    var layer: [8 * 8]Rgba = @splat(.transparent);
    var h: History = .init(16 * @sizeOf(Rgba));
    defer h.deinit(gpa);

    try testing.expect(h.record(gpa, 0, &layer, 8, .{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 2 }));
    try testing.expect(!h.record(gpa, 0, &layer, 8, .{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 8 }));
    try testing.expect(!h.canUndo());
    try testing.expectEqual(@as(usize, 0), h.used);
}

test "running out of memory loses undo steps, never pixels, and leaks nothing" {
    // Run the same four actions once per allocation they make, with that one
    // allocation failing. `std.testing.checkAllAllocationFailures` cannot do
    // this job: it expects the failure to come back as an error, and here the
    // whole point is that it does not.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();

        var layer: [8 * 8]Rgba = @splat(.transparent);
        const layers = [_][]Rgba{&layer};
        var h: History = .init(1 << 20);
        var kept: usize = 0;
        for (0..4) |i| {
            const x: u32 = @intCast(i * 2);
            const r: Rect = .{ .x0 = x, .y0 = 0, .x1 = x + 2, .y1 = 2 };
            if (h.record(gpa, 0, &layer, 8, r)) kept += 1;
            fillRect(&layer, 8, r, 200); // the action happens either way
        }
        // Every undo the history still holds must restore real pixels.
        while (h.undo(&layers, 8)) |e| {
            for (e.rect.y0..e.rect.y1) |y| for (e.rect.x0..e.rect.x1) |x| {
                try testing.expectEqual(Rgba.transparent, layer[y * 8 + x]);
            };
        }
        h.deinit(gpa);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (!failing.has_induced_failure) {
            try testing.expectEqual(@as(usize, 4), kept);
            break; // every allocation has now been made to fail once
        }
    }
}
