//! Saving and opening a project: the picture with its layers kept apart.
//!
//! A PNG is flat. Once the layers are merged, nothing can say which paint
//! was on which layer, so a PNG cannot be opened again for editing. A project
//! file keeps each layer.
//!
//! The format, all integers little-endian:
//!
//!   header, 16 bytes
//!     0  magic      4 bytes  "ZPNT"
//!     4  version    u16      1
//!     6  width      u32
//!    10  height     u32
//!    14  layers     u8       1 to 8
//!    15  active     u8       less than layers
//!
//!   each layer
//!     0  visible    u8       0 or 1
//!     1  size       u32      bytes of compressed pixels that follow
//!     5  pixels     size bytes, zlib: width * height premultiplied RGBA
//!
//! Opening a file is reading input someone else wrote, so nothing in it is
//! trusted. Every field is checked, and the new document is built completely
//! before it replaces the one on screen. A file that fails any check is
//! rejected and the open picture is untouched.

const std = @import("std");
const flate = std.compress.flate;
const Document = @import("document.zig").Document;
const Rgba = @import("pixel.zig").Rgba;

pub const magic = "ZPNT";
pub const version: u16 = 1;
pub const max_side = 4096;
pub const max_layers = 8;

pub fn save(gpa: std.mem.Allocator, doc: *const Document, out: *std.Io.Writer) !void {
    try out.writeAll(magic);
    try out.writeInt(u16, version, .little);
    try out.writeInt(u32, doc.width, .little);
    try out.writeInt(u32, doc.height, .little);
    try out.writeInt(u8, @intCast(doc.layers.len), .little);
    try out.writeInt(u8, @intCast(doc.active_layer), .little);

    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const compressor = try gpa.create(flate.Compress);
    defer gpa.destroy(compressor);

    for (doc.layers, doc.visible) |layer, visible| {
        var packed_layer: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
        defer packed_layer.deinit();
        compressor.* = try .init(&packed_layer.writer, window, .zlib, .default);
        try compressor.writer.writeAll(std.mem.sliceAsBytes(layer));
        try compressor.finish();

        try out.writeInt(u8, @intFromBool(visible), .little);
        try out.writeInt(u32, @intCast(packed_layer.written().len), .little);
        try out.writeAll(packed_layer.written());
    }
}

pub const OpenError = error{
    /// The first four bytes are not "ZPNT".
    NotAProject,
    /// A later version of this program wrote the file.
    NewerVersion,
    /// Width or height is 0 or larger than `max_side`.
    BadSize,
    /// No layers, too many, or an active layer that does not exist.
    BadLayers,
    /// The file ends before all of the data that it promised.
    Truncated,
    /// The compressed pixels do not decompress to exactly one layer.
    BadPixels,
    /// The colour of a pixel is larger than its alpha. A premultiplied pixel
    /// can never have such a value.
    NotPremultiplied,
    /// Bytes after the last layer.
    TrailingBytes,
    OutOfMemory,
};

/// Build a new document from a project file. If an error occurs, the
/// function returns no document and changes nothing.
pub fn open(gpa: std.mem.Allocator, bytes: []const u8, history_budget: usize) OpenError!Document {
    var in: Cursor = .{ .bytes = bytes };

    if (!std.mem.eql(u8, try in.take(4), magic)) return error.NotAProject;
    const file_version = try in.int(u16);
    if (file_version > version) return error.NewerVersion;
    if (file_version != version) return error.NotAProject;

    const width = try in.int(u32);
    const height = try in.int(u32);
    if (width == 0 or height == 0 or width > max_side or height > max_side) return error.BadSize;
    const layer_count = try in.int(u8);
    const active = try in.int(u8);
    if (layer_count == 0 or layer_count > max_layers or active >= layer_count) return error.BadLayers;

    // Read the layer table one time before any allocation. Eight layers of
    // 4096 by 4096 is 512 MB, and a 16-byte header can ask for that size. If
    // some layers are not in the file, or bytes follow the layers, the file
    // fails here at a low cost, before the large allocation.
    {
        var scan = in;
        for (0..layer_count) |_| {
            _ = try scan.int(u8);
            _ = try scan.take(try scan.int(u32));
        }
        if (scan.at != bytes.len) return error.TrailingBytes;
    }

    var doc: Document = try .init(gpa, width, height, layer_count, history_budget);
    errdefer doc.deinit();
    doc.active_layer = active;

    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    for (doc.layers, doc.visible) |layer, *visible| {
        const flag = try in.int(u8);
        if (flag > 1) return error.BadLayers;
        visible.* = flag == 1;

        const size = try in.int(u32);
        const compressed = try in.take(size);

        // Decompress into the layer, then ask for one more byte. If a layer is
        // too short, the first read fails. If a layer is too long, a byte
        // remains for the second read.
        var reader: std.Io.Reader = .fixed(compressed);
        var inflate: flate.Decompress = .init(&reader, .zlib, window);
        inflate.reader.readSliceAll(std.mem.sliceAsBytes(layer)) catch return error.BadPixels;
        var extra: [1]u8 = undefined;
        if (inflate.reader.readSliceShort(&extra)) |n| {
            if (n != 0) return error.BadPixels;
        } else |_| return error.BadPixels;

        for (layer) |p| {
            if (p.r > p.a or p.g > p.a or p.b > p.a) return error.NotPremultiplied;
        }
    }

    doc.stale = .{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height };
    return doc;
}

/// Reading forwards through a byte slice, where running off the end is an
/// error rather than a crash.
const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(c: *Cursor, n: usize) error{Truncated}![]const u8 {
        if (n > c.bytes.len - c.at) return error.Truncated;
        defer c.at += n;
        return c.bytes[c.at..][0..n];
    }

    fn int(c: *Cursor, comptime T: type) error{Truncated}!T {
        return std.mem.readInt(T, (try c.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};

const testing = std.testing;

/// A small document with something on both layers, saved.
fn sample(gpa: std.mem.Allocator) ![]u8 {
    var doc: Document = try .init(gpa, 48, 32, 2, 1 << 20);
    defer doc.deinit();
    doc.beginStroke(.{ .radius = 6, .color = .{ 200, 40, 40 } }, .brush, .{ .x = 4, .y = 4 });
    doc.moveStroke(.{ .x = 44, .y = 28 });
    doc.endStroke();
    _ = doc.setActiveLayer(1);
    _ = try doc.fillAt(40, 2, .{ 30, 90, 200 });
    doc.setVisible(0, false);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try save(gpa, &doc, &out.writer);
    return out.toOwnedSlice();
}

test "a saved project opens with the same layers, visibility and active layer" {
    const gpa = testing.allocator;
    var doc: Document = try .init(gpa, 48, 32, 2, 1 << 20);
    defer doc.deinit();
    doc.beginStroke(.{ .radius = 6, .color = .{ 200, 40, 40 } }, .brush, .{ .x = 4, .y = 4 });
    doc.moveStroke(.{ .x = 44, .y = 28 });
    doc.endStroke();
    _ = doc.setActiveLayer(1);
    _ = try doc.fillAt(40, 2, .{ 30, 90, 200 });
    doc.setVisible(0, false);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try save(gpa, &doc, &out.writer);

    var back = try open(gpa, out.written(), 1 << 20);
    defer back.deinit();
    try testing.expectEqual(doc.width, back.width);
    try testing.expectEqual(@as(u32, 1), back.active_layer);
    try testing.expectEqualSlices(bool, doc.visible, back.visible);
    for (doc.layers, back.layers) |a, b| try testing.expectEqualSlices(Rgba, a, b);
}

test "each kind of damage is rejected with its own error" {
    const gpa = testing.allocator;
    const good = try sample(gpa);
    defer gpa.free(good);
    const bad = try gpa.dupe(u8, good);
    defer gpa.free(bad);

    const Case = struct { offset: usize, value: u8, want: OpenError };
    const cases = [_]Case{
        .{ .offset = 0, .value = 'X', .want = error.NotAProject },
        .{ .offset = 4, .value = 2, .want = error.NewerVersion },
        .{ .offset = 6, .value = 0, .want = error.BadSize }, // width 48 -> 0
        .{ .offset = 14, .value = 9, .want = error.BadLayers }, // 9 layers
        .{ .offset = 15, .value = 2, .want = error.BadLayers }, // active 2 of 2
        .{ .offset = 16, .value = 7, .want = error.BadLayers }, // visible = 7
    };
    for (cases) |c| {
        @memcpy(bad, good);
        bad[c.offset] = c.value;
        try testing.expectError(c.want, open(gpa, bad, 1 << 20));
    }
    try testing.expectError(error.Truncated, open(gpa, good[0 .. good.len - 1], 1 << 20));

    const longer = try std.mem.concat(gpa, u8, &.{ good, "!" });
    defer gpa.free(longer);
    try testing.expectError(error.TrailingBytes, open(gpa, longer, 1 << 20));
}

test "a pixel brighter than its alpha is refused" {
    const gpa = testing.allocator;
    var doc: Document = try .init(gpa, 4, 4, 1, 0);
    defer doc.deinit();
    doc.layers[0][5] = .{ .r = 90, .g = 0, .b = 0, .a = 10 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try save(gpa, &doc, &out.writer);
    try testing.expectError(error.NotPremultiplied, open(gpa, out.written(), 0));
}

test "every truncation and every flipped byte is rejected or opens cleanly, and nothing leaks" {
    const gpa = testing.allocator;
    const good = try sample(gpa);
    defer gpa.free(good);

    // Cut the file at each length.
    for (0..good.len) |n| {
        if (open(gpa, good[0..n], 1 << 20)) |doc| {
            var d = doc;
            d.deinit();
            return error.TestUnexpectedResult; // a cut file must never open
        } else |_| {}
    }

    // Flip each byte, one after the other. Some flips change compressed data
    // that still decodes to valid premultiplied pixels. Thus a file with a
    // flip can open. It must never crash, and the testing allocator makes
    // sure that it never leaks.
    const bad = try gpa.dupe(u8, good);
    defer gpa.free(bad);
    for (0..good.len) |i| {
        @memcpy(bad, good);
        bad[i] ^= 0xff;
        if (open(gpa, bad, 1 << 20)) |doc| {
            var d = doc;
            d.deinit();
        } else |_| {}
    }
}

test "a header asking for 512 MB with no data behind it allocates nothing" {
    var header: [16]u8 = undefined;
    @memcpy(header[0..4], magic);
    std.mem.writeInt(u16, header[4..6], version, .little);
    std.mem.writeInt(u32, header[6..10], max_side, .little);
    std.mem.writeInt(u32, header[10..14], max_side, .little);
    header[14] = max_layers;
    header[15] = 0;
    // An allocator that refuses each request. If `open` tried an allocation
    // before its checks, this test would get OutOfMemory instead.
    var none: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.Truncated, open(none.allocator(), &header, 0));
}

test "fuzz: no input crashes open" {
    // `zig build test --fuzz` explores inputs from here. An ordinary test
    // run feeds it only the corpus, which starts from a valid file.
    const gpa = testing.allocator;
    const good = try sample(gpa);
    defer gpa.free(good);
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [8192]u8 = undefined;
            const n = smith.slice(&buf);
            if (open(testing.allocator, buf[0..n], 1 << 20)) |doc| {
                var d = doc;
                d.deinit();
            } else |_| {}
        }
    }.one, .{ .corpus = &.{good} });
}
