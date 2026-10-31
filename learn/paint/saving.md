# Save a PNG

> The program flattens the picture onto white paper and writes it as a PNG. Each row gets the filter, of five, that makes its bytes smallest.

Save PNG in the studio writes the picture that you see: each visible layer over white paper.

The [Write a PNG](https://www.ziglang.in/learn/graphics/png/) chapter makes a PNG writer by hand: the signature, the chunks, a CRC on each chunk, and zlib compression. Read that chapter first. This chapter shows the changes for a real document.

There are two changes. The writer takes an allocator, and it selects a filter for each row.

## Flatten the layers

A PNG can store the transparency of the layers. But people expect to save the picture on the screen, with the white paper behind it.

The screen buffer already holds exactly that picture. Thus the save starts from the screen buffer:

```zig
    /// The picture as a PNG, flattened onto white paper.
    pub fn writePng(d: *Document, out: *std.Io.Writer) !void {
        d.stale = .{ .x0 = 0, .y0 = 0, .x1 = d.width, .y1 = d.height };
        _ = d.render();
        try png.write(d.gpa, out, d.display, d.width, d.height);
    }
```

*Quoted from the source: `writePng` from `examples/paint/src/engine/document.zig`.*

`writePng` marks the full screen as stale and renders it first. Usually the engine draws again only the areas that changed. A saved file must not depend on the last areas that the engine drew.

## An allocator, not global variables

The writer in the PNG chapter kept its buffers in global variables. That works for one fixed size of picture.

A document can be of any size. Thus this writer takes an allocator and gets the memory that it needs:

- The state of the compressor, about 224 KB. This is too large for a small stack.
- The 64 KB window that the compressor needs.
- Two rows of pixels, and five filtered copies of a row.
- The compressed output, which grows while the writer writes it.

Each allocation has a `defer` immediately below it. Thus the code frees each allocation on each path out of the function, and this is also true on the error paths.

## A filter for each row

The PNG chapter tried two filters on the full picture and kept the smaller file. With Sub, a gradient became smaller, from 3801 bytes to 133. The flat test scene became larger.

A real picture has both types of area. The sky in a painting is smooth, and the edge of a stroke is not smooth. Thus the best filter changes from row to row.

There are five filters. Each filter predicts a byte from bytes that the writer wrote before, and stores the difference:

- **None** predicts 0. Thus it stores the byte without a change.
- **Sub** predicts the byte to the left.
- **Up** predicts the byte above.
- **Average** predicts the average of the left byte and the byte above.
- **Paeth** predicts the one of left, above and above-left that is nearest to `left + above − above-left`.

```zig
/// The one of left, above and above-left that is nearest to `left + up - up_left`.
/// Ties go to left, then above, as the specification says.
fn paeth(left: u8, up: u8, up_left: u8) u8 {
    const p = @as(i16, left) + up - up_left;
    const pa = @abs(p - left);
    const pb = @abs(p - up);
    const pc = @abs(p - up_left);
    if (pa <= pb and pa <= pc) return left;
    if (pb <= pc) return up;
    return up_left;
}
```

*Quoted from the source: `paeth` from `examples/paint/src/engine/png.zig`.*

## Select a filter

The writer tries all five filters on each row and keeps one of them.

To compress each row in five ways costs too much time. Thus the writer uses an estimate. A good prediction gives differences near zero. The writer adds the differences, and reads each byte as a signed number from −128 to 127. Then it keeps the filter with the smallest total.

```zig
/// Write `pixels` as an 8-bit RGB PNG. The function ignores alpha. Give it
/// pixels that are already flattened onto the paper.
pub fn write(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    pixels: []const Rgba,
    width: u32,
    height: u32,
) !void {
    const stride = @as(usize, width) * 3;

    // The compressor is about 224 KB. A small stack cannot hold that size.
    // Thus the compressor goes on the heap with its 64 KB window.
    const compressor = try gpa.create(flate.Compress);
    defer gpa.destroy(compressor);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    // Two rows of plain RGB, this one and the one above, and one filtered
    // candidate per filter.
    const rows = try gpa.alloc(u8, stride * 2 + (stride + 1) * 5);
    defer gpa.free(rows);
    var above = rows[0..stride];
    var current = rows[stride .. stride * 2];
    @memset(above, 0); // the row above the first row counts as zeros

    var idat: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer idat.deinit();
    compressor.* = try .init(&idat.writer, window, .zlib, .default);

    for (0..height) |y| {
        for (0..width) |x| {
            const p = pixels[y * width + x];
            current[x * 3 ..][0..3].* = .{ p.r, p.g, p.b };
        }

        // Try all five filters. Keep the filter whose bytes are smallest when
        // the code reads them as signed numbers. Small numbers mean values near
        // their prediction, and those values compress well. The rule is an
        // estimate, but libpng uses the same estimate, and it costs little.
        var best: []const u8 = undefined;
        var best_score: u64 = std.math.maxInt(u64);
        inline for (all_filters, 0..) |filter, k| {
            const candidate = rows[stride * 2 + k * (stride + 1) ..][0 .. stride + 1];
            candidate[0] = @backingInt(filter);
            var score: u64 = 0;
            for (0..stride) |i| {
                const left: u8 = if (i >= 3) current[i - 3] else 0;
                const up = above[i];
                const up_left: u8 = if (i >= 3) above[i - 3] else 0;
                const predict: u8 = switch (filter) {
                    .none => 0,
                    .sub => left,
                    .up => up,
                    .average => @intCast((@as(u16, left) + up) / 2),
                    .paeth => paeth(left, up, up_left),
                };
                const v = current[i] -% predict;
                candidate[1 + i] = v;
                score += @abs(@as(i8, @bitCast(v)));
            }
            if (score < best_score) {
                best_score = score;
                best = candidate;
            }
        }
        try compressor.writer.writeAll(best);
        std.mem.swap([]u8, &above, &current);
    }
    try compressor.finish();

    try out.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 2, 0, 0, 0 }; // 8-bit, RGB, zlib, standard filters, no interlace
    try writeChunk(out, "IHDR", &ihdr);
    try writeChunk(out, "IDAT", idat.written());
    try writeChunk(out, "IEND", "");
}
```

*Quoted from the source: `write` from `examples/paint/src/engine/png.zig`.*

The PNG specification recommends this estimate, and libpng uses it. The estimate costs little: one pass over the row for each filter.

`inline for` runs the loop body one time for each of the five filters, at compile time. Thus the compiler decides the `switch` on the filter inside the body. Each copy of the body does one type of prediction, with no branch in the inner loop.

## Give the file to the browser

The engine writes the PNG into its own memory. The studio copies the bytes out and puts them in a `Blob`. Then it starts a download:

```ts
const length = e.paint_export_png();
const bytes = new Uint8Array(e.memory.buffer, e.paint_png(), length).slice();
const url = URL.createObjectURL(new Blob([bytes], { type: "image/png" }));
```

The `.slice()` copies the bytes. Without it, the `Blob` points into the memory of the engine. The next export frees that memory and uses it again.

## Checks

This test uses a picture with flat rows, smooth rows and noise. After the round trip, the pixels must be exactly the same. The writer must also select more than one filter for the picture:

```zig
test "pixels survive the round trip, whatever filters were chosen" {
    const gpa = testing.allocator;
    const w = 37;
    const h = 23;
    var pixels: [w * h]Rgba = undefined;
    // Smooth areas, flat areas and noise, so that more than one filter wins.
    var r = std.Random.DefaultPrng.init(3);
    for (0..h) |y| for (0..w) |x| {
        const noise = r.random().int(u8);
        pixels[y * w + x] = .{
            .r = @intCast((x * 7) % 256),
            .g = if (y < 10) 40 else noise,
            .b = @intCast((x * y) % 256),
            .a = 255,
        };
    };

    var png: std.Io.Writer.Allocating = .init(gpa);
    defer png.deinit();
    try write(gpa, &png.writer, &pixels, w, h);

    const decoded = try decodeForTest(gpa, png.written(), w, h);
    defer gpa.free(decoded.rgb);
    for (pixels, 0..) |p, i| {
        try testing.expectEqualSlices(u8, &.{ p.r, p.g, p.b }, decoded.rgb[i * 3 ..][0..3]);
    }

    // The picture mixes flat rows, smooth rows and noise. Thus the choice
    // for each row must not use one filter for all rows.
    var kinds: usize = 0;
    for (decoded.used) |u| kinds += @intFromBool(u);
    try testing.expect(kinds >= 2);
}
```

*Quoted from the source: `pixels survive the round trip, whatever filters were chosen` from `examples/paint/src/engine/png.zig`.*

This test examines the rule for ties in Paeth, which the specification fixes. A decoder with a different rule for ties decodes a different picture:

```zig
test "paeth breaks ties in the order the specification gives" {
    try testing.expectEqual(@as(u8, 10), paeth(10, 10, 10));
    try testing.expectEqual(@as(u8, 20), paeth(10, 20, 10)); // p = 20, closest is up
    try testing.expectEqual(@as(u8, 10), paeth(10, 20, 30)); // p = 0, closest is left
}
```

*Quoted from the source: `paeth breaks ties in the order the specification gives` from `examples/paint/src/engine/png.zig`.*

If the reader of the engine agrees with the writer of the engine, that does not prove much. The two can have the same mistake. Thus the browser test of the site pushes Save PNG and decodes the file with a separate decoder. That decoder uses zlib from Node, and the site tests use their own code from the PNG specification. Its pixels must be the same as the pixels of the canvas.

## Explain before you read the answer

A row is 640 pixels of one flat colour. The row immediately above it has a different flat colour.

Which filter gives the smallest total?

Sub or Paeth. After the first pixel, both filters store zeros. Sub predicts the byte to the left. Paeth also selects the left byte, because the row above is flat.

The two filters are different only on the first pixel. The first pixel has nothing to its left. Thus Sub stores its colour without a change, and Paeth predicts the pixel above and stores the difference. The filter whose three bytes are nearer to zero gives the smaller total.

Up gives a larger total. It stores the difference between the two colours in each of the 1,920 bytes.
