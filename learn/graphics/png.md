# Writing a PNG

> A signature, three chunks and a CRC on each. The pixels are filtered, then compressed with the zlib in the standard library.

A PPM file is easy to write, but it is big.

Our 64 by 32 test picture is 6157 bytes as a PPM.

As a PNG it is 680 bytes, and every image viewer and browser opens it.

A PNG needs two things beyond the pixels: zlib compression and a CRC-32 checksum.

Zig's standard library has both, so a PNG writer is about a hundred lines.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.png-write`)*

The two pictures under the output are the two PNG files the program wrote.

Your browser decoded them with its own PNG decoder. No code from this site decoded those files.

## The shape of the file

A PNG is an 8-byte signature followed by a list of chunks.

```
signature   89 50 4E 47 0D 0A 1A 0A
IHDR        width, height, and what kind of pixels
IDAT        the pixels, compressed
IEND        nothing, it marks the end
```

The signature is the same in every PNG.

<SnippetSource name="09-graphics.png-write" decl="signature" />

`50 4E 47` is the text `PNG`.

The other bytes catch a file that was damaged by being copied as text.

A tool that converts line endings changes `0D 0A`. A tool that strips the top bit changes `89`. A reader then refuses the file at the first eight bytes.

## A chunk

Every chunk has the same four parts:

```
length   4 bytes, big-endian, the size of the data only
type     4 letters, like IHDR
data     length bytes
crc      4 bytes, CRC-32 of the type and the data
```

<SnippetSource name="09-graphics.png-write" decl="writeChunk" />

The CRC covers the type and the data. It does not cover the length.

All numbers in a PNG are big-endian, so `writeInt` is told `.big` every time.

`std.hash.Crc32` is the same CRC-32 that zip and Ethernet use. `init`, `update` as many times as you need, then `final`.

## The header chunk

<SnippetSource name="09-graphics.png-write" decl="writePng" />

`IHDR` is always 13 bytes, and it must come first.

Colour type 2 means three bytes per pixel, R then G then B, with no alpha.

The two fields that are always 0 name the compression and filter methods. The format defines only one of each, so 0 is the only legal value.

## Scanlines and the filter byte

The pixels are not compressed as they are.

They are cut into rows, and each row starts with one extra byte, the **filter byte**.

So one row here is 1 + 64 × 3 = 193 bytes, and the 32 rows are 6176 bytes before compression.

The filter byte says how the row's bytes were changed before compression.

Filter 0, None, leaves them as they are.

Filter 1, Sub, stores each byte minus the same channel of the pixel to its left.

<SnippetSource name="09-graphics.png-write" decl="filterRows" />

## The worked example

The red channel of the gradient picture rises by 4 every pixel.

```
red bytes, filter none:  0  4  8 12 16 20 ...
red bytes, filter sub:   0  4  4  4  4  4 ...
```

After Sub, the row is the same few bytes over and over.

Repeated bytes are what zlib compresses well.

The output shows the result. The gradient is 3801 bytes compressed with no filter and 133 bytes with Sub.

## A filter can also hurt

The scene picture goes the other way: 623 bytes with no filter and 709 with Sub.

The scene has large flat areas and hard edges. Its rows already repeat, and Sub breaks some of those repeats.

So `save` tries both filters and keeps the smaller result.

Real encoders choose a filter for every row, from five: None, Sub, Up, Average and Paeth. Up subtracts the byte above. Average subtracts the average of the left and above bytes. Paeth subtracts whichever of the left, above and above-left bytes is the best guess.

## Wrapping subtraction

Sub can give a negative number.

A pixel with red 10 to the right of a pixel with red 200 stores 10 − 200.

The format says this wraps around 256: 10 − 200 + 256 = 66.

The decoder adds back with the same wrap: 66 + 200 − 256 = 10.

Zig makes us say this on purpose.

A plain `-` on two `u8` values that goes below zero is integer overflow, which Zig checks in safe builds. The wrapping operators `-%` and `+%` say that wrapping is what we want.

## Compressing

`std.compress.flate.Compress` writes deflate, and the `.zlib` container adds the 2-byte header and the Adler-32 checksum a PNG expects.

<SnippetSource name="09-graphics.png-write" decl="deflate" />

The compressor keeps about 224 KB of state and needs a 64 KB window buffer.

That is a lot to put on the stack, so both are global variables.

`finish` writes the end of the stream. Without it the data stops partway and a reader reports a truncated file.

## Reading it back

The program reads its own file back from disk and checks it the way a viewer would.

<SnippetSource name="09-graphics.png-write" decl="check" />

It walks the chunks, checks each CRC, inflates the pixels, undoes the filter and compares with what it drew.

Undoing Sub runs forwards. Each byte adds back the byte to its left, which is already decoded.

This check proves only that our writer and our reader agree.

They could share the same mistake.

So the page checks the files twice more, with decoders that share no code with this one.

CI decodes each file with zlib from Node and the five filters written from the specification. Your browser decodes it with its own PNG decoder.

Both must give pixels whose hash matches the `wrote` line the program printed.

## What this writer leaves out

This writer handles one kind of PNG: 8 bits per channel, RGB, no interlacing.

It leaves out alpha (colour type 6), 16-bit channels, palettes, and the chunks for colour space and text.

A PNG with no colour space chunk is shown as sRGB.

So the bytes you write are the encoded bytes from [Linear Light](https://www.ziglang.in/learn/graphics/linear-light/), not linear values.

## Explain before reading the answer

A row of 64 pixels, all the same colour `(30, 60, 90)`, is filtered with Sub.

What bytes come out after the filter byte?

`30 60 90` for the first pixel, then 189 zeros.

The first pixel has no left neighbour, so it stays as it is. Every other byte is equal to the byte three places to its left, so the difference is zero.
