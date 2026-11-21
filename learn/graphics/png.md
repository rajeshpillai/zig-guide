# Write a PNG

> A signature, three chunks and a CRC on each chunk. The writer filters the pixels, then compresses them with the zlib in the standard library.

A PPM file is easy to write, but it is large. The 64 by 32 test picture of this section is 6157 bytes as a PPM. As a PNG, the picture is 680 bytes, and all image viewers and browsers open it.

A PNG needs two things in addition to the pixels: zlib compression and a CRC-32 checksum. The Zig standard library has both. Thus a PNG writer is about a hundred lines.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");
const flate = std.compress.flate;

var scene: [canvas.width * canvas.height]u32 = undefined;
var gradient: [canvas.width * canvas.height]u32 = undefined;

/// All PNG files start with these eight bytes. The `\r\n`, `\x1a` and `\n`
/// find a file that a text copy damaged. A line-ending conversion or a
/// truncation changes these bytes, and then a reader refuses the file.
const signature = "\x89PNG\r\n\x1a\n";

/// One scanline: a filter byte, then R, G, B for each pixel in the row.
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
            // Go backward, thus the byte to the left still holds its raw
            // value at the time of the subtraction. The first pixel has no
            // left neighbour and does not change. `-%=` wraps, because the
            // format says so.
            var i = data.len;
            while (i > 3) {
                i -= 1;
                data[i] -%= data[i - 3];
            }
        }
    }
}

/// The compressor keeps about 224 KB of state and needs a 64 KB window. Thus
/// both are here, not on the stack. Decompression needs a window of the same
/// size, thus the check below uses this window again.
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
    ihdr[10] = 0; // compression method: zlib, the only method
    ihdr[11] = 0; // filter method: the five filters, the only set
    ihdr[12] = 0; // no interlacing
    try writeChunk(w, "IHDR", &ihdr);
    try writeChunk(w, "IDAT", idat);
    try writeChunk(w, "IEND", "");
}

/// Read the file again as a viewer does: read the chunks, check each CRC,
/// inflate the pixels, remove the filter, and compare with the drawing.
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
            // Forward this time: each byte adds back the byte to its left,
            // which the loop already decoded.
            for (3..data.len) |i| data[i] +%= data[i - 3];
        }
        for (0..canvas.width) |x| {
            const got = canvas.rgb(data[x * 3], data[x * 3 + 1], data[x * 3 + 2]);
            if (got != pixels[y * canvas.width + x]) same = false;
        }
    }
    try out.print("  decoded pixels match the drawing: {}\n", .{same});
}

/// Try the two filters and keep the smaller result. Write the file, then read
/// the file again from disk and check it.
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
    // Each pixel is different from its neighbours, by the same quantity.
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.png-write`)*

The two pictures under the output are the two PNG files that the program wrote. Your browser decoded the files with its own PNG decoder. No code from this site decoded those files.

## The shape of the file

A PNG is an 8-byte signature and then a list of chunks.

```
signature   89 50 4E 47 0D 0A 1A 0A
IHDR        width, height, and what kind of pixels
IDAT        the pixels, compressed
IEND        nothing, it marks the end
```

The signature is the same in all PNG files.

```zig
/// All PNG files start with these eight bytes. The `\r\n`, `\x1a` and `\n`
/// find a file that a text copy damaged. A line-ending conversion or a
/// truncation changes these bytes, and then a reader refuses the file.
const signature = "\x89PNG\r\n\x1a\n";
```

*Quoted from the source: `signature` from `snippets/09-graphics/png-write.zig`.*

`50 4E 47` is the text `PNG`. The other bytes find a file that a text copy damaged:

- A tool that converts line endings changes `0D 0A`.
- A tool that removes the top bit changes `89`.

In both cases, a reader refuses the file at the first eight bytes.

## A chunk

All chunks have the same four parts:

```
length   4 bytes, big-endian, the size of the data only
type     4 letters, like IHDR
data     length bytes
crc      4 bytes, CRC-32 of the type and the data
```

```zig
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
```

*Quoted from the source: `writeChunk` from `snippets/09-graphics/png-write.zig`.*

The CRC covers the type and the data. It does not cover the length.

All numbers in a PNG are big-endian. Thus each call to `writeInt` gets `.big`.

`std.hash.Crc32` is the same CRC-32 that zip and Ethernet use. Call `init`, then call `update` as many times as necessary, then call `final`.

## The header chunk

```zig
fn writePng(w: *std.Io.Writer, idat: []const u8) !void {
    try w.writeAll(signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], canvas.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], canvas.height, .big);
    ihdr[8] = 8; // bits per channel
    ihdr[9] = 2; // colour type 2: RGB, no alpha
    ihdr[10] = 0; // compression method: zlib, the only method
    ihdr[11] = 0; // filter method: the five filters, the only set
    ihdr[12] = 0; // no interlacing
    try writeChunk(w, "IHDR", &ihdr);
    try writeChunk(w, "IDAT", idat);
    try writeChunk(w, "IEND", "");
}
```

*Quoted from the source: `writePng` from `snippets/09-graphics/png-write.zig`.*

`IHDR` is always 13 bytes, and it must be the first chunk.

Colour type 2 means three bytes for each pixel, in the order R, G, B, with no alpha.

The two fields that are always 0 identify the compression method and the filter method. The format defines only one of each. Thus 0 is the only legal value.

## Scanlines and the filter byte

The writer does not compress the pixels in their original form. It cuts them into rows, and each row starts with one extra byte, the **filter byte**. Thus one row here is 1 + 64 × 3 = 193 bytes. Before compression, the 32 rows are 6176 bytes.

The filter byte tells how the writer changed the bytes of the row before compression:

- Filter 0, None, keeps the bytes as they are.
- Filter 1, Sub, stores each byte minus the same channel of the pixel to its left.

```zig
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
            // Go backward, thus the byte to the left still holds its raw
            // value at the time of the subtraction. The first pixel has no
            // left neighbour and does not change. `-%=` wraps, because the
            // format says so.
            var i = data.len;
            while (i > 3) {
                i -= 1;
                data[i] -%= data[i - 3];
            }
        }
    }
}
```

*Quoted from the source: `filterRows` from `snippets/09-graphics/png-write.zig`.*

## The worked example

In the gradient picture, the red channel increases by 4 at each pixel.

```
red bytes, filter none:  0  4  8 12 16 20 ...
red bytes, filter sub:   0  4  4  4  4  4 ...
```

After Sub, the row is the same few bytes again and again. zlib compresses repeated bytes well.

The output shows the result. Without a filter, the compressed gradient is 3801 bytes. With Sub, it is 133 bytes.

## A filter can also make the file larger

The scene picture shows the opposite result: 623 bytes with no filter, and 709 bytes with Sub. The scene has large flat areas and hard edges. Its rows already repeat, and Sub breaks some of those repeats. Thus `save` tries the two filters and keeps the smaller result.

Real encoders select a filter for each row. There are five filters:

- None.
- Sub.
- Up subtracts the byte above.
- Average subtracts the average of the left byte and the byte above.
- Paeth subtracts one of the left, above and above-left bytes: the one that is the best guess.

## Wrapping subtraction

Sub can give a negative number. If a pixel with red 10 is to the right of a pixel with red 200, Sub stores 10 − 200.

The format says that this value wraps around 256: 10 − 200 + 256 = 66. The decoder adds the value back with the same wrap: 66 + 200 − 256 = 10.

In Zig, you must write this wrap on purpose. A plain `-` on two `u8` values that goes below zero is integer overflow. Zig checks integer overflow in safe builds. The wrapping operators `-%` and `+%` tell Zig that the wrap is intentional.

## Compression

`std.compress.flate.Compress` writes deflate. The `.zlib` container adds the 2-byte header and the Adler-32 checksum that a PNG expects.

```zig
/// zlib-compress `data`: a 2-byte header, deflate, and an Adler-32 checksum.
fn deflate(data: []const u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(&compressed);
    compressor = try .init(&out, &window, .zlib, .default);
    try compressor.writer.writeAll(data);
    try compressor.finish();
    return out.buffered();
}
```

*Quoted from the source: `deflate` from `snippets/09-graphics/png-write.zig`.*

The compressor keeps about 224 KB of state and needs a 64 KB window buffer. That is too much for the stack. Thus both are global variables.

`finish` writes the end of the stream. Without `finish`, the data stops before the end, and a reader reports a truncated file.

## Read the file again

The program reads its own file from disk and checks the file as a viewer does.

```zig
/// Read the file again as a viewer does: read the chunks, check each CRC,
/// inflate the pixels, remove the filter, and compare with the drawing.
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
            // Forward this time: each byte adds back the byte to its left,
            // which the loop already decoded.
            for (3..data.len) |i| data[i] +%= data[i - 3];
        }
        for (0..canvas.width) |x| {
            const got = canvas.rgb(data[x * 3], data[x * 3 + 1], data[x * 3 + 2]);
            if (got != pixels[y * canvas.width + x]) same = false;
        }
    }
    try out.print("  decoded pixels match the drawing: {}\n", .{same});
}
```

*Quoted from the source: `check` from `snippets/09-graphics/png-write.zig`.*

The `check` function does these steps:

1. It reads each chunk and checks its CRC.
2. It inflates the pixels.
3. It removes the filter.
4. It compares the result with the drawing.

To remove Sub, the function goes forward through the row. Each byte adds back the byte to its left, which the function already decoded.

This check proves only that the writer and the reader of this program agree. The writer and the reader can have the same mistake. Thus the page checks the files two more times, with decoders that share no code with this one:

- CI decodes each file with zlib from Node and the five filters, written from the specification.
- Your browser decodes each file with its own PNG decoder.

Both must give pixels with a hash equal to the hash in the `wrote` line that the program printed.

## What this writer does not do

This writer writes one kind of PNG: 8 bits for each channel, RGB, no interlacing.

It does not write alpha (colour type 6), 16-bit channels, palettes, or the chunks for colour space and text.

A viewer shows a PNG with no colour space chunk as sRGB. Thus the bytes that you write are the encoded bytes from [Linear Light](https://www.ziglang.in/learn/graphics/linear-light/), not linear values.

## Explain before you read the answer

A row has 64 pixels, all with the same colour `(30, 60, 90)`. The row goes through the Sub filter. What bytes come after the filter byte?

The answer is `30 60 90` for the first pixel, then 189 zeros.

The first pixel has no left neighbour, thus it does not change. Each other byte is equal to the byte three places to its left. Thus the difference is zero.
