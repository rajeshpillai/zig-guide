# Fill

> A flood fill finds its area a small number of pixels at a time. A queue and a visited map do this in fixed memory. Recursion uses all of the stack.

The Fill tool paints a full area in one action.

You click one pixel. Each pixel that has the same colour and connects to that pixel changes to the new colour. The fill stops at all other colours.

That set of pixels is the **region**. The work is to find the region.

## The fill finds the region a small number of pixels at a time

The fill cannot know the shape of the region before it starts. It knows only the first pixel.

The neighbours of the first pixel that have the same colour are also in the region. Their neighbours with the same colour are in the region too, and so on.

Thus each pixel that the fill accepts can give more pixels to examine.

## Recursion is short, but it is the wrong answer

The shortest code is a function that fills one pixel and then calls itself on the four neighbours of that pixel. The code is short, but it is incorrect for a paint program.

Each call waits for the calls that it makes, thus the calls nest. A fill of an empty 640 by 400 layer nests 256,000 calls deep. Each call needs some stack space. The stack of a thread is usually 8 MiB or less, and in a browser it is much less. The program stops before the fill is complete.

## A queue and a visited map

Instead, the code keeps a list of the pixels that it must examine. This list is a **queue**, and the code takes pixels from the front:

1. Put the clicked pixel in the queue.
2. Take the next pixel from the queue.
3. Examine each of the four neighbours of that pixel. If a neighbour has the target colour and it has no mark, put a mark on it and add it to the queue.
4. Do step 2 again until the queue is empty.

The marks are in a **bit set**, with one bit for each pixel of the image. A 640 by 400 image needs 256,000 bits, which is 32,000 bytes.

```zig
/// Find the region of `pixels` connected to (`x`, `y`) that has exactly the
/// colour at (`x`, `y`).
pub fn find(
    gpa: std.mem.Allocator,
    pixels: []const Rgba,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
) !Region {
    const total = @as(usize, width) * height;
    var inside: std.bit_set.Dynamic = try .initEmpty(gpa, total);
    errdefer inside.deinit(gpa);

    // Each pixel goes into the queue one time at most, because the code marks
    // it when it goes in, not when it comes out. Thus the queue never needs
    // more space than the number of pixels in the image. A plain array with a
    // read position is sufficient, because the code never moves an entry.
    const queue = try gpa.alloc(u32, total);
    defer gpa.free(queue);
    var head: usize = 0;
    var tail: usize = 0;

    const target = pixels[@as(usize, y) * width + x];
    const start: u32 = y * width + x;
    inside.set(start);
    queue[tail] = start;
    tail += 1;

    var bounds: Rect = .{ .x0 = x, .y0 = y, .x1 = x + 1, .y1 = y + 1 };
    while (head < tail) {
        const i = queue[head];
        head += 1;
        const px = i % width;
        const py = i / width;
        bounds = bounds.join(.{ .x0 = px, .y0 = py, .x1 = px + 1, .y1 = py + 1 });

        // The four neighbours. Skip each neighbour that is outside an edge.
        const neighbours = [4]?u32{
            if (px > 0) i - 1 else null,
            if (px + 1 < width) i + 1 else null,
            if (py > 0) i - width else null,
            if (py + 1 < height) i + width else null,
        };
        for (neighbours) |maybe| {
            const n = maybe orelse continue;
            if (inside.isSet(n)) continue;
            if (!std.meta.eql(pixels[n], target)) continue;
            inside.set(n);
            queue[tail] = n;
            tail += 1;
        }
    }
    return .{ .inside = inside, .bounds = bounds, .count = tail };
}
```

*Quoted from the source: `find` from `examples/paint/src/engine/fill.zig`.*

## Why the queue never needs to grow

The code puts a mark on a pixel when the pixel goes into the queue, not when it comes out.

Because of this small decision, no pixel can go into the queue two times. Thus the queue never holds more entries than the number of pixels in the image. The code can allocate exactly that size at the start.

The code never removes entries from the front, thus it never moves entries. The code reads at `head` and writes at `tail`. Both indexes move only forward.

For 640 by 400, the queue is 256,000 `u32` values, which is 1,024,000 bytes. The code frees the queue when `find` returns.

## Four neighbours, and the soft edge

The fill examines four neighbours: left, right, up and down. Thus two pixels that touch only at a corner are not connected. A fill stops at a diagonal gap.

The match is also exact. A pixel is in the region only if all four of its bytes are equal to the bytes of the start pixel.

The soft edge of a brush stroke has pixels with partial coverage, thus none of them is an exact match. A fill inside a soft circle stops before the edge. It leaves a thin ring of the old colour. For this reason, paint programs have a **tolerance** setting. This engine does not have tolerance, because the region rule stays simple without it.

## Fill and undo

The `fillAt` function of the document finds the region and saves its bounding rectangle for undo. Then it changes each pixel in the region:

```zig
    /// Fill the area around (`x`, `y`) on the active layer with an opaque
    /// colour. Returns false if there was nothing to change.
    pub fn fillAt(d: *Document, x: u32, y: u32, color: [3]u8) !bool {
        if (d.stroke != null or x >= d.width or y >= d.height) return false;
        const layer = d.layers[d.active_layer];
        const new: Rgba = .opaqueRgb(color);
        // If the region already has the fill colour, the fill finds the full
        // region and changes nothing.
        if (std.meta.eql(layer[@as(usize, y) * d.width + x], new)) return false;

        var region = try fill.find(d.gpa, layer, d.width, d.height, x, y);
        defer region.deinit(d.gpa);

        d.history_ok = d.history.record(d.gpa, d.active_layer, layer, d.width, region.bounds);
        var it = region.inside.iterator(.{});
        while (it.next()) |i| layer[i] = new;
        d.stale = d.stale.join(region.bounds);
        return true;
    }
```

*Quoted from the source: `fillAt` from `examples/paint/src/engine/document.zig`.*

`fillAt` also examines the colour first. If a region already has the fill colour, the fill searches the full region and changes nothing. Then it leaves an undo step that does nothing.

The `errdefer` in `find` is important here. If the allocation of the queue fails, the code frees the bit set that it allocated before. Then the error returns to the caller. A test examines this: it causes each allocation to fail, one after the other.

## Checks

This test uses a closed shape with a box inside it. The fill finds the 9 pixels around the box, and not the one pixel inside the box:

```zig
test "a closed shape fills inside and stops at its walls" {
    const p = picture(&.{
        "#######",
        "#.....#",
        "#.###.#",
        "#.#.#.#",
        "#######",
    });
    var r = try find(testing.allocator, &p, 7, 5, 1, 1);
    defer r.deinit(testing.allocator);
    // The 9 dots around the inner box (5 + 2 + 2), not the one inside it.
    try testing.expectEqual(@as(usize, 9), r.count);
    try testing.expect(!r.inside.isSet(3 * 7 + 3));
    try testing.expectEqual(Rect{ .x0 = 1, .y0 = 1, .x1 = 6, .y1 = 4 }, r.bounds);
}
```

*Quoted from the source: `a closed shape fills inside and stops at its walls` from `examples/paint/src/engine/fill.zig`.*

This test examines the diagonal gap:

```zig
test "four neighbours do not leak through a diagonal gap" {
    const p = picture(&.{
        ".#",
        "#.",
    });
    var r = try find(testing.allocator, &p, 2, 2, 0, 0);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.count);
}
```

*Quoted from the source: `four neighbours do not leak through a diagonal gap` from `examples/paint/src/engine/fill.zig`.*

This test fills a full empty 640 by 400 layer, which recursion cannot do:

```zig
test "a whole empty 640 by 400 image fills without recursion" {
    const gpa = testing.allocator;
    const p = try gpa.alloc(Rgba, 640 * 400);
    defer gpa.free(p);
    @memset(p, .transparent);
    var r = try find(gpa, p, 640, 400, 320, 200);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 640 * 400), r.count);
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 640, .y1 = 400 }, r.bounds);
}
```

*Quoted from the source: `a whole empty 640 by 400 image fills without recursion` from `examples/paint/src/engine/fill.zig`.*

## Explain before you read the answer

A queue gives its entries from the front. A **stack** gives its entries from the back.

If `find` took the newest pixel instead of the oldest pixel, would it find the same region?

Yes, it would. It would examine the pixels in a different order. It would go far in one direction before it returns. But it still examines each pixel that it can get to, exactly one time. The region is the same. Only the order of the visits changes.
