//! Saving the picture as a PNG.
//!
//! This is the writer from the Writing a PNG chapter, grown in two ways for a
//! real document. It takes an allocator, because a document can be any size.
//! And it chooses a filter for every row instead of one for the whole image,
//! as real encoders do.

const std = @import("std");
const flate = std.compress.flate;
const Rgba = @import("pixel.zig").Rgba;

const signature = "\x89PNG\r\n\x1a\n";

const Filter = enum(u8) { none = 0, sub = 1, up = 2, average = 3, paeth = 4 };
const all_filters = [_]Filter{ .none, .sub, .up, .average, .paeth };

/// Write `pixels` as an 8-bit RGB PNG. Alpha is dropped: pass pixels that are
/// already flattened onto the paper.
pub fn write(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    pixels: []const Rgba,
    width: u32,
    height: u32,
) !void {
    const stride = @as(usize, width) * 3;

    // The compressor is about 224 KB, which is more than a small stack can
    // hold, so it goes on the heap with its 64 KB window.
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

        // Try all five filters and keep the one whose bytes are smallest when
        // read as signed numbers. Small numbers mean values close to their
        // prediction, which is what compresses well. The rule is a guess, but
        // it is the guess libpng makes, and it is cheap.
        var best: []const u8 = undefined;
        var best_score: u64 = std.math.maxInt(u64);
        inline for (all_filters, 0..) |filter, k| {
            const candidate = rows[stride * 2 + k * (stride + 1) ..][0 .. stride + 1];
            candidate[0] = @intFromEnum(filter);
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

/// Whichever of left, above and above-left is closest to `left + up - up_left`.
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

fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

const testing = std.testing;

const Decoded = struct {
    rgb: []u8,
    /// Which of the five filters appeared on at least one row.
    used: [5]bool,
};

/// Decode what `write` produced. Only what this file writes is understood:
/// 8-bit RGB, one IDAT chunk.
fn decodeForTest(gpa: std.mem.Allocator, png: []const u8, width: u32, height: u32) !Decoded {
    try testing.expect(std.mem.startsWith(u8, png, signature));
    var at: usize = signature.len;
    var idat: []const u8 = &.{};
    while (at < png.len) {
        const len = std.mem.readInt(u32, png[at..][0..4], .big);
        const kind = png[at + 4 ..][0..4];
        const data = png[at + 8 ..][0..len];
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        try testing.expectEqual(crc.final(), std.mem.readInt(u32, png[at + 8 + len ..][0..4], .big));
        if (std.mem.eql(u8, kind, "IDAT")) idat = data;
        at += 12 + len;
    }

    const stride = @as(usize, width) * 3;
    const raw = try gpa.alloc(u8, (stride + 1) * height);
    defer gpa.free(raw);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var in: std.Io.Reader = .fixed(idat);
    var inflate: flate.Decompress = .init(&in, .zlib, window);
    try inflate.reader.readSliceAll(raw);

    const out = try gpa.alloc(u8, stride * height);
    var used: [5]bool = @splat(false);
    for (0..height) |y| {
        const filter: Filter = @enumFromInt(raw[y * (stride + 1)]);
        used[@intFromEnum(filter)] = true;
        for (0..stride) |i| {
            const left: u8 = if (i >= 3) out[y * stride + i - 3] else 0;
            const up: u8 = if (y > 0) out[(y - 1) * stride + i] else 0;
            const up_left: u8 = if (y > 0 and i >= 3) out[(y - 1) * stride + i - 3] else 0;
            const predict: u8 = switch (filter) {
                .none => 0,
                .sub => left,
                .up => up,
                .average => @intCast((@as(u16, left) + up) / 2),
                .paeth => paeth(left, up, up_left),
            };
            out[y * stride + i] = raw[y * (stride + 1) + 1 + i] +% predict;
        }
    }
    return .{ .rgb = out, .used = used };
}

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

    // The picture mixes flat rows, smooth rows and noise, so the per-row
    // choice should not have settled on one filter for everything.
    var kinds: usize = 0;
    for (decoded.used) |u| kinds += @intFromBool(u);
    try testing.expect(kinds >= 2);
}

test "paeth breaks ties in the order the specification gives" {
    try testing.expectEqual(@as(u8, 10), paeth(10, 10, 10));
    try testing.expectEqual(@as(u8, 20), paeth(10, 20, 10)); // p = 20, closest is up
    try testing.expectEqual(@as(u8, 10), paeth(10, 20, 30)); // p = 0, closest is left
}
