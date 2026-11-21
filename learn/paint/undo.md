# Undo

> Keep only the changed rectangle. Undo and redo are one swap, two stacks are an array and an index, and a memory failure costs an undo step, not the stroke.

People expect one Undo to remove one action. One action is one stroke or one fill. It is not one dab, and it is not one pointer sample.

Thus the history saves data one time for each action, immediately before the action changes a layer. The question is which data to save.

## A copy of the full picture is expensive

The simplest answer is a copy of each layer.

At 640 by 400 with two layers, one copy is 2 × 640 × 400 × 4 = 2,048,000 bytes. Eight undo steps need 16,384,000 bytes, about 15.6 MiB.

That is much memory for a short line in one corner. Most of each copy is pixels that the action did not touch.

## Save only the changes

Each action in this program knows the rectangle that it touches:

- A stroke gets the rectangle from the `dirty` rectangle of the stroke buffer.
- A fill knows the bounds of the area that it found.

Thus the history copies that rectangle, from that one layer, immediately before the action changes it.

A stroke 100 pixels wide and 60 pixels high saves 100 × 60 × 4 = 24,000 bytes. That is about 1% of a full copy.

```zig
pub const Entry = struct {
    layer: u32,
    rect: Rect,
    /// `rect.area()` pixels, row by row.
    pixels: []Rgba,

    fn bytes(e: Entry) usize {
        return e.pixels.len * @sizeOf(Rgba);
    }
};
```

*Quoted from the source: `Entry` from `examples/paint/src/engine/history.zig`.*

## Undo and redo are one swap

To undo, put the saved pixels back into the layer.

But redo needs the pixels that the action made. If undo puts the old pixels back with a copy, the new pixels are lost.

Thus undo does not copy. It **swaps**: the saved pixels go into the layer, and the current pixels of the layer go into the entry. Now the entry holds the newer pixels. Redo is the same swap again.

```zig
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
```

*Quoted from the source: `swap` from `examples/paint/src/engine/history.zig`.*

One function does the two jobs. Thus undo and redo cannot become different.

## Two stacks in one array

The usual design has two stacks:

- Undo removes an entry from the **past** stack and adds it to the **future** stack.
- Redo does the opposite.

In this program, the two stacks are one array and an index, `cursor`. You can undo the entries before the cursor. You can redo the entries from the cursor to the end.

```
entries   [ A ][ B ][ C ][ D ]
                         ^
                       cursor
```

In this example, you can undo A, B and C, and you can redo D.

```zig
pub const History = struct {
    entries: std.ArrayList(Entry) = .empty,
    cursor: usize = 0,
    budget: usize,
    used: usize = 0,

    // ...
};
```

*Quoted from the source: `History` (fields only) from `examples/paint/src/engine/history.zig`.*

Undo moves the cursor back one position and swaps. Redo swaps and moves the cursor forward:

```zig
    /// Undo the newest action. Returns the entry so the caller knows which
    /// layer and rectangle to redraw, or null when there is nothing to undo.
    pub fn undo(h: *History, layers: []const []Rgba, width: u32) ?Entry {
        if (!h.canUndo()) return null;
        h.cursor -= 1;
        const e = h.entries.items[h.cursor];
        swap(e, layers[e.layer], width);
        return e;
    }
```

*Quoted from the source: `undo` from `examples/paint/src/engine/history.zig`.*

To move an entry from one stack to the other, the code needs space in the other stack. An allocation for that space can fail. A change to an index cannot fail. Thus undo and redo never allocate, and they never fail.

## A new action removes the future

Draw A, then draw B. Undo B. Then draw C.

Can Redo put B back now?

It must not. You drew B on top of A, before C existed. If Redo puts B over C, the result is a picture that never existed.

Thus, before `record` saves a new action, it deletes all entries from the cursor to the end. That is the first step of `record`.

## A memory budget

The history has a limit in bytes. If a new entry goes over the limit, the history removes the oldest entries until the new entry fits.

When the history removes the oldest entry, you cannot undo the earliest actions. That is the cost of a limit.

One entry can also be larger than the full budget. An example is a fill of the full page with a small budget. Then the history removes all of its entries.

If the history kept the older entries, the result would be worse. Undo would skip the action that the history could not save. Then the older entries would put back pixels from before that action, in some areas and not in others. The result would be a picture that never existed.

## When the memory is not sufficient

This is the full `record` function:

```zig
    /// Copy `rect` of `layer` before an action changes it. Returns false when
    /// the history cannot keep the copy. The copy alone can be larger than the
    /// budget, or the memory can be full. In both cases, do the action.
    pub fn record(
        h: *History,
        gpa: std.mem.Allocator,
        layer: u32,
        pixels: []const Rgba,
        width: u32,
        rect: Rect,
    ) bool {
        if (rect.isEmpty()) return true;

        // A new action starts a new branch. The entries for redo do not agree
        // with the picture now. Thus the code removes them.
        h.dropFrom(gpa, h.cursor);

        const need = rect.area() * @sizeOf(Rgba);
        if (need > h.budget) {
            // An empty history also cannot hold this entry. If the code kept the
            // old entries, undo would skip this action and restore a picture that
            // never existed. Thus the code also removes the old entries.
            h.dropFrom(gpa, 0);
            return false;
        }
        while (h.used + need > h.budget) h.dropOldest(gpa);

        // Make space in the list first. Then a failure after the copy cannot
        // leave a copy that nothing owns.
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
```

*Quoted from the source: `record` from `examples/paint/src/engine/history.zig`.*

`record` returns `bool`, not an error.

In Zig, a failed allocation is an ordinary error value, `error.OutOfMemory`. The program decides what to do with it.

In this program, the stroke is more important than its undo step. If the code cannot make the copy, the stroke still goes onto the layer. Only the undo step is lost, and `record` returns `false`. Then the studio shows a line below the canvas: you cannot undo the last action.

Before `record` stops, it removes the oldest entries one at a time and tries again. Old undo steps are less important than the new undo step.

The order of the two allocations is also important. The code first makes space in the list, and then makes the copy. If the code made the copy first and then the list could not grow, the copy would have no owner. Then the memory of the copy would leak.

## Checks

This test does undo, redo, and then the two again:

```zig
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
```

*Quoted from the source: `undo restores, redo repeats, and both can go back and forth` from `examples/paint/src/engine/history.zig`.*

This test is the A, B, C example:

```zig
test "drawing after an undo drops the redo branch" {
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

    try testing.expect(!h.canRedo()); // redo cannot restore B
    try testing.expectEqual(@as(usize, 2), h.entries.items.len);
}
```

*Quoted from the source: `drawing after an undo drops the redo branch` from `examples/paint/src/engine/history.zig`.*

This test examines the budget, with space for exactly three entries and five actions:

```zig
test "the budget drops the oldest entries" {
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
```

*Quoted from the source: `the budget drops the oldest entries` from `examples/paint/src/engine/history.zig`.*

This test examines memory failures. The testing allocator of Zig can fail on purpose. The test runs the same four actions many times. Each time, a different allocation fails, until each allocation failed one time:

```zig
test "running out of memory loses undo steps, never pixels, and leaks nothing" {
    // Run the same four actions one time for each allocation that they make.
    // In each run, that one allocation fails.
    // `std.testing.checkAllAllocationFailures` cannot do this job. It expects
    // an error as the result of the failure, and here the failure must not
    // give an error.
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
```

*Quoted from the source: `running out of memory loses undo steps, never pixels, and leaks nothing` from `examples/paint/src/engine/history.zig`.*

Each run examines three things:

- Each action changed the layer.
- Each undo step that the history kept puts back the correct pixels.
- The test freed each byte that it allocated.

## Explain before you read the answer

The budget is 16 MiB. You fill the full 640 by 400 top layer. Then you draw 20 small strokes.

How many undo steps are there?

There are 21 undo steps. The fill saved one full layer, 1,024,000 bytes, and the strokes saved only their rectangles. The total is much less than 16 MiB. Thus the history removed nothing.
