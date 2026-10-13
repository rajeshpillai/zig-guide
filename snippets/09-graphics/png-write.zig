//! title: Writing a PNG
//! A PNG is a signature and a list of chunks. The pixels go in one chunk,
//! compressed with zlib, and every chunk ends with a CRC of its bytes.

const std = @import("std");
const canvas = @import("_canvas.zig");
const flate = std.compress.flate;

var scene: [canvas.width * canvas.height]u32 = undefined;
var gradient: [canvas.width * canvas.height]u32 = undefined;

/// Every PNG starts with these eight bytes. The `\r\n`, `\x1a` and `\n` are
/// there to catch a file that was copied as text: a line-ending conversion or
/// a truncation changes them, and a reader then refuses the file.
const signature = "\x89PNG\r\n\x1a\n";

/// One scanline: a filter byte, then R, G, B for every pixel in the row.
const row_len = 1 + canvas.width * 3;
var rows: [canvas.height * row_len]u8 = undefined;

const Filter = enum(u8) {
    /// The bytes as they are.
    none = 0,
    /// Each byte minus the same channel of the pixel to its left.
    sub = 1,
};

fn filterRows(pixels: []const u32, filter: Filter) void {
    for (0..canvas.height) |y| {
        const row = rows[y * row_len ..][0..row_len];
        row[0] = @intFromEnum(filter);
        const data = row[1..];
        for (0..canvas.width) |x| {
            const c = canvas.channels(pixels[y * canvas.width + x]);
            data[x * 3 ..][0..3].* = .{ c.r, c.g, c.b };
        }
        if (filter == .sub) {
            // Walk backwards, so the byte to the left still holds its raw
            // value when we subtract it. The first pixel has no left
            // neighbour and stays as it is. `-%=` wraps, as the format says.
            var i = data.len;
            while (i > 3) {
                i -= 1;
                data[i] -%= data[i - 3];
            }
        }
    }
}

/// The compressor keeps about 224 KB of state and needs a 64 KB window, so
/// both live here rather than on the stack. The check below reuses the window
/// for decompressing, which needs one of the same size.
var compressor: flate.Compress = undefined;
var window: [flate.max_window_len]u8 = undefined;
var compressed: [16 * 1024]u8 = undefined;

/// zlib-compress `data`: a 2-byte header, deflate, and an Adler-32 checksum.
fn deflate(data: []const u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(&compressed);
    compressor = try .init(&out, &window, .zlib, .default);
    try compressor.writer.writeAll(data);
    try compressor.finish();
    return out.buffered();
}

/// Length, type, data, and a CRC-32 of the type and the data.
fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

fn writePng(w: *std.Io.Writer, idat: []const u8) !void {
    try w.writeAll(signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], canvas.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], canvas.height, .big);
    ihdr[8] = 8; // bits per channel
    ihdr[9] = 2; // colour type 2: RGB, no alpha
    ihdr[10] = 0; // compression method: zlib, the only one there is
    ihdr[11] = 0; // filter method: the five filters, the only set there is
    ihdr[12] = 0; // no interlacing
    try writeChunk(w, "IHDR", &ihdr);
    try writeChunk(w, "IDAT", idat);
    try writeChunk(w, "IEND", "");
}

/// Read the file back the way a viewer would: walk the chunks, check every
/// CRC, inflate the pixels, undo the filter, and compare with what we drew.
fn check(out: *std.Io.Writer, png: []const u8, pixels: []const u32) !void {
    if (!std.mem.startsWith(u8, png, signature)) return error.BadSignature;
    var at: usize = signature.len;
    var idat: []const u8 = &.{};
    while (at < png.len) {
        const len = std.mem.readInt(u32, png[at..][0..4], .big);
        const kind = png[at + 4 ..][0..4];
        const data = png[at + 8 ..][0..len];
        const stored = std.mem.readInt(u32, png[at + 8 + len ..][0..4], .big);
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        const ok = crc.final() == stored;
        try out.print("    {s} {d: >5} bytes  crc {s}\n", .{ kind, len, if (ok) "ok" else "BAD" });
        if (std.mem.eql(u8, kind, "IDAT")) idat = data;
        at += 12 + len;
    }

    var in: std.Io.Reader = .fixed(idat);
    var inflate: flate.Decompress = .init(&in, .zlib, &window);
    var raw: [canvas.height * row_len]u8 = undefined;
    try inflate.reader.readSliceAll(&raw);

    var same = true;
    for (0..canvas.height) |y| {
        const row = raw[y * row_len ..][0..row_len];
        const data = row[1..];
        if (row[0] == @intFromEnum(Filter.sub)) {
            // Forwards this time: each byte adds back the already decoded
            // byte to its left.
            for (3..data.len) |i| data[i] +%= data[i - 3];
        }
        for (0..canvas.width) |x| {
            const got = canvas.rgb(data[x * 3], data[x * 3 + 1], data[x * 3 + 2]);
            if (got != pixels[y * canvas.width + x]) same = false;
        }
    }
    try out.print("  decoded pixels match the drawing: {}\n", .{same});
}

/// Try both filters, keep the smaller result, write the file, then read it
/// back from disk and check it.
fn save(io: std.Io, out: *std.Io.Writer, name: []const u8, pixels: []const u32) !void {
    try out.print("{s}\n", .{name});

    filterRows(pixels, .none);
    const none_len = (try deflate(&rows)).len;
    filterRows(pixels, .sub);
    const sub_len = (try deflate(&rows)).len;
    try out.print("  compressed, filter none: {d} bytes\n", .{none_len});
    try out.print("  compressed, filter sub:  {d} bytes\n", .{sub_len});

    const best: Filter = if (sub_len < none_len) .sub else .none;
    filterRows(pixels, best);
    const idat = try deflate(&rows);

    const dir = std.Io.Dir.cwd();
    {
        const file = try dir.createFile(io, name, .{});
        defer file.close(io);
        var file_buf: [4096]u8 = undefined;
        var writer = file.writer(io, &file_buf);
        try writePng(&writer.interface, idat);
        try writer.interface.flush();
    }

    var read_buf: [16 * 1024]u8 = undefined;
    const png = try dir.readFile(io, name, &read_buf);
    try out.print("  wrote it with filter {s}: {d} bytes on disk\n", .{ @tagName(best), png.len });
    try check(out, png, pixels);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // Flat areas and hard edges.
    canvas.scene(&scene);
    // Every pixel different from its neighbours, but by the same amount.
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            gradient[y * canvas.width + x] = canvas.rgb(@intCast(x * 4), @intCast(y * 8), 128);
        }
    }

    try out.print("scanlines: {d} rows of {d} bytes = {d} bytes\n", .{ canvas.height, row_len, rows.len });
    try save(io, out, "scene.png", &scene);
    try save(io, out, "gradient.png", &gradient);

    try canvas.announce(out, "gradient.png", &gradient);
    try canvas.announce(out, "scene.png", &scene);
    try out.flush();
}
