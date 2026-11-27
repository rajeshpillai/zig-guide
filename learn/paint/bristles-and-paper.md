# Bristles and Paper

> A row of thin hairs across the stroke gives separate tracks. A fixed grid of paper heights decides where a dry brush touches.

A real brush is not a solid disc. It is a bundle of hairs.

When the brush has much paint, the hairs push together and make one solid mark. When the brush is almost dry, each hair makes its own thin track. The tracks break at each dip in the surface of the paper.

The Dry brush in the studio does both. It needs two new brush settings:

- **bristles**: the number of hairs, from 0 (a solid tip) to 16.
- **contact**: how much of the paper the brush touches, from 0 to 1.

## Hairs across the stroke

A bristle brush stamps one small round dab for each hair, instead of one large dab.

The hairs are in a row across the stroke, at right angles to its movement. If the stroke moves in direction `θ`, the direction straight across the stroke is:

```
(−sin θ, cos θ)
```

For a movement to the right, θ is 0, and the result is (0, 1): straight down the page. For a movement down the page, θ is a quarter turn, and the result is (−1, 0): to the left. In both cases, the direction is across the stroke.

Each hair has an **offset** from −1 (one edge of the tip) to 1 (the other edge). The position of the hair is the centre of the dab, plus the product of the direction across, the offset and the radius.

With radius 20 and offset −0.5, a stroke that moves to the right puts that hair 10 pixels above the centre.

```zig
        pub fn dab(p: Painter, d: Dab) void {
            const b = p.brush;
            const doc = p.doc;
            if (b.bristles == 0) {
                doc.mask.stampOn(&doc.paper, b.contact, d, b.hardness, b.aspect, b.flow);
                doc.stale = doc.stale.join(Rect.around(d.x, d.y, d.radius, doc.width, doc.height));
                return;
            }

            // A bristle brush is a row of thin hairs across the stroke. Each
            // hair is a small round dab on the line at right angles to the
            // direction of movement.
            const across_x = -@sin(d.direction);
            const across_y = @cos(d.direction);
            const count: f32 = @floatFromInt(b.bristles);
            // Each hair is half as wide as its space. Thus the tracks stay apart,
            // also after the small random movements in `Hairs`.
            const hair_radius = @max(d.radius / count * 0.5, 0.75);
            for (p.hairs.offset[0..b.bristles], p.hairs.flow[0..b.bristles]) |offset, flow| {
                var hair = d;
                hair.x += across_x * offset * d.radius;
                hair.y += across_y * offset * d.radius;
                hair.radius = hair_radius;
                doc.mask.stampOn(&doc.paper, b.contact, hair, b.hardness, 1, b.flow * flow);
            }
            doc.stale = doc.stale.join(Rect.around(d.x, d.y, d.radius + hair_radius, doc.width, doc.height));
        }
```

*Quoted from the source: `dab` from `examples/paint/src/engine/document.zig`.*

The direction comes from the stroke. Each dab now has its direction of movement, and also the angle of the tip. The two values are separate because you can turn a tip to any angle, but the hairs must always spread across the path.

## The positions of the hairs

Hairs at exactly equal distances look like a comb. Thus the code moves each hair by a small random distance. It also gives each hair its own part of the flow, so that some tracks are fainter than others:

```zig
    /// The position of each hair of a bristle brush across the tip, and how
    /// much paint the hair carries. The code makes the hairs from the seed of
    /// the brush. Thus the same brush always has the same hairs, and a painter
    /// can make them again on each call. It does not have to store them.
    const Hairs = struct {
        /// From -1 (one edge of the tip) to 1 (the other).
        offset: [max_bristles]f32,
        /// A part of the flow of the brush, from 0.55 to 1.
        flow: [max_bristles]f32,

        fn layOut(b: Brush) Hairs {
            var h: Hairs = undefined;
            var random: Random = .init(b.seed +% 0x9e37);
            const n: f32 = @floatFromInt(@max(b.bristles, 1));
            for (0..max_bristles) |i| {
                const even = -1.0 + (2.0 * @as(f32, @floatFromInt(i)) + 1.0) / n;
                // Equal distances, then a movement of up to a third of the gap.
                // Thus the tracks are not a perfect comb.
                h.offset[i] = even + (random.next() - 0.5) * (2.0 / n) / 3.0;
                h.flow[i] = 0.55 + 0.45 * random.next();
            }
            return h;
        }
    };
```

*Quoted from the source: `Hairs` from `examples/paint/src/engine/document.zig`.*

The code makes the layout from the seed of the brush. The same brush always has the same hairs. Thus the program does not store the layout. The painter makes the layout again on each call.

This decision also prevents a bug that this file had before. The code puts the first dab of a stroke before the document stores the stroke. Thus the painter must not get any data from the stored stroke.

Each hair is half as wide as its space. A test found a problem at 90%: after the random movements, the hairs touched each other, and five hairs made only three tracks.

## Paper

Real paper has a surface of very small hills and dips.

The engine stores the surface as a grid of **heights**, with one height for each cell of 4 by 4 pixels. The heights are random, from a seed. The code makes them one time, when it makes the document:

```zig
pub const Paper = struct {
    /// Width and height of one cell, in pixels.
    cell: u32,
    columns: u32,
    rows: u32,
    /// One height per cell, row by row: 0 is the bottom of a dip, 255 the
    /// top of a hill.
    heights: []u8,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, cell: u32, seed: u32) !Paper {
        const columns = (width + cell - 1) / cell;
        const rows = (height + cell - 1) / cell;
        const heights = try gpa.alloc(u8, @as(usize, columns) * rows);
        var random: Random = .init(seed);
        for (heights) |*h| h.* = @intFromFloat(@round(random.next() * 255.0));
        return .{ .cell = cell, .columns = columns, .rows = rows, .heights = heights };
    }

    pub fn deinit(p: *Paper, gpa: std.mem.Allocator) void {
        gpa.free(p.heights);
    }

    /// The height below pixel (`x`, `y`). All pixels in a cell have one
    /// height, thus the grain is `cell` pixels across.
    pub fn at(p: Paper, x: u32, y: u32) u8 {
        const column = @min(x / p.cell, p.columns - 1);
        const row = @min(y / p.cell, p.rows - 1);
        return p.heights[@as(usize, row) * p.columns + column];
    }

    /// Whether a brush with this `contact` (0 to 1) reaches the paper at
    /// (`x`, `y`). Full contact reaches every height. Less contact reaches
    /// only the hills: at 0.3, only heights in the top 30%.
    pub fn touches(p: Paper, x: u32, y: u32, contact: f32) bool {
        const threshold = (1.0 - contact) * 255.0;
        return @as(f32, @floatFromInt(p.at(x, y))) >= threshold;
    }
};
```

*Quoted from the source: `Paper` from `examples/paint/src/engine/paper.zig`.*

The paper does not move. If you draw two strokes across the same area, both strokes touch the same hills. Real grain does the same.

To find the height below a pixel, divide by the cell size:

```
column = x / 4
row    = y / 4
index  = row × columns + column
```

The pixel at (22, 10) is in column 5 and row 2. A 640-pixel document has 160 columns. Thus the cell of the pixel is number 2 × 160 + 5 = 325.

## Contact

A wet brush pushes into the dips. A dry brush touches only the tops of the hills.

**Contact** tells how deep the brush goes. A pixel gets paint only if its paper is sufficiently high:

```zig
    /// Whether a brush with this `contact` (0 to 1) reaches the paper at
    /// (`x`, `y`). Full contact reaches every height. Less contact reaches
    /// only the hills: at 0.3, only heights in the top 30%.
    pub fn touches(p: Paper, x: u32, y: u32, contact: f32) bool {
        const threshold = (1.0 - contact) * 255.0;
        return @as(f32, @floatFromInt(p.at(x, y))) >= threshold;
    }
```

*Quoted from the source: `touches` from `examples/paint/src/engine/paper.zig`.*

At contact 0.3, the brush touches only heights in the top 30%. A height of 0.8 gets paint, and a height of 0.4 does not. At contact 0.9, both heights get paint. At 1, all heights get paint. That is why all of the other brushes work exactly as before.

The check is inside the loop of the tip, immediately after the distance test:

```zig
if (paper) |pp| if (!pp.touches(x, y, contact)) continue;
```

If the brush does not touch a pixel, the pixel gets no coverage from this dab. Another dab of the same stroke does not change the result, because that dab touches the same paper.

## Checks

This test is the grid example from above:

```zig
test "the cell under a pixel: (22, 10) with cells of 4 is column 5, row 2" {
    var p = try Paper.init(std.testing.allocator, 640, 400, 4, 1);
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 160), p.columns);
    try std.testing.expectEqual(p.heights[2 * 160 + 5], p.at(22, 10));
    try std.testing.expectEqual(p.at(20, 8), p.at(23, 11)); // same cell
}
```

*Quoted from the source: `the cell under a pixel: (22, 10) with cells of 4 is column 5, row 2` from `examples/paint/src/engine/paper.zig`.*

This test examines contact at 30% and at 100%:

```zig
test "contact: 30% reaches a high cell but not a low one, 100% reaches both" {
    var heights = [_]u8{ 204, 102 }; // 0.8 and 0.4 of the way up
    const p: Paper = .{ .cell = 1, .columns = 2, .rows = 1, .heights = &heights };
    try std.testing.expect(p.touches(0, 0, 0.3));
    try std.testing.expect(!p.touches(1, 0, 0.3));
    try std.testing.expect(p.touches(0, 0, 1));
    try std.testing.expect(p.touches(1, 0, 1));
}
```

*Quoted from the source: `contact: 30% reaches a high cell but not a low one, 100% reaches both` from `examples/paint/src/engine/paper.zig`.*

This test makes sure that a dry stroke paints only high cells:

```zig
test "a dry brush skips the paper's dips, the same ones every time" {
    var d = try newDoc();
    defer d.deinit();
    const dry: Brush = .{ .radius = 20, .hardness = 1, .flow = 1, .contact = 0.3 };
    d.beginStroke(dry, .brush, .{ .x = 0, .y = 24 });
    d.moveStroke(.{ .x = 64, .y = 24 });
    d.endStroke();
    // Each painted pixel is on a high cell, and the stroke paints each high
    // cell that it crosses.
    var painted: usize = 0;
    for (0..48) |y| for (0..64) |x| {
        const covered = d.layers[0][y * 64 + x].a > 0;
        const high = d.paper.touches(@intCast(x), @intCast(y), 0.3);
        if (covered) {
            painted += 1;
            try testing.expect(high);
        }
    };
    try testing.expect(painted > 0);
    try testing.expect(painted < 64 * 41 / 2); // much less than half of the band
}
```

*Quoted from the source: `a dry brush skips the paper's dips, the same ones every time` from `examples/paint/src/engine/document.zig`.*

This test makes sure that five hairs make five tracks. The test reads one column of pixels across the stroke and counts the separate areas of paint:

```zig
test "a bristle brush leaves separate tracks" {
    var d = try newDoc();
    defer d.deinit();
    const brush: Brush = .{ .radius = 20, .bristles = 5, .hardness = 1, .flow = 1, .spacing = 0.05 };
    d.beginStroke(brush, .brush, .{ .x = 0, .y = 24 });
    d.moveStroke(.{ .x = 64, .y = 24 });
    d.endStroke();
    // Read one column across the stroke and count the separate areas of paint.
    var runs: usize = 0;
    var inside = false;
    for (0..48) |y| {
        const covered = d.layers[0][y * 64 + 32].a > 0;
        if (covered and !inside) runs += 1;
        inside = covered;
    }
    try testing.expectEqual(@as(usize, 5), runs);
}
```

*Quoted from the source: `a bristle brush leaves separate tracks` from `examples/paint/src/engine/document.zig`.*

## Explain before you read the answer

A bristle brush moves along the track of one hair. The hair touches a pixel whose paper is too low for the contact of the brush.

Does the track of the hair continue after the gap?

Yes, it does. The gap is in the paint, not in the stroke. The stroke continues along the path and puts more dabs. The next dab on higher paper paints again. The result is the broken line of a dry brush.
