# Writing an Image File

> PPM, the image format you can write without a library, and the one rule that will bite you.

A buffer nobody can look at is not much of a picture. PPM is the shortest
route out: a short text header, then the pixel bytes. That is the whole format
worth knowing, and it needs no library at all.

It belongs to the Netpbm family, which is six formats along two axes: what a
pixel is, and whether the data is text or binary.

| | ASCII | Binary | A pixel is |
| --- | --- | --- | --- |
| **PBM** (bitmap) | `P1` | `P4` | one bit, black or white |
| **PGM** (graymap) | `P2` | `P5` | one gray sample |
| **PPM** (pixmap) | `P3` | `P6` | three samples: R, G, B |

`P6` is the one to write. `P3` holds the same pixels as decimal numbers in
text, which is larger and slower but worth generating once if you want to read
your own image in an editor.

## The header

```
P6\n64 32\n255\n<6144 raw bytes>
```

Four fields, then data: the magic, the width, the height, and the maxval (the
largest value a sample may take). They are separated by any mix of spaces,
tabs, and newlines, so `P6 64 32 255 ` is as valid as the form above.

Then the rule that actually matters:

> **Exactly one whitespace byte follows the maxval.** Everything after that
> single byte is pixel data.

Write `"255\n\n"` and every pixel shifts by one byte. The image comes out as
diagonal noise, and no parser can detect the mistake, because `0x0A` is a
perfectly legal pixel value. The snippet below ends by decoding a file with
that exact defect so you can see what the reader gets.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

// The header is at most a few dozen bytes; the body is three bytes per pixel.
var file_bytes: [64 + canvas.width * canvas.height * 3]u8 = undefined;

fn drawScene() void {
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            const r: u8 = @intCast((x * 255) / (canvas.width - 1));
            const g: u8 = @intCast((y * 255) / (canvas.height - 1));
            canvas.putPixel(&pixels, @intCast(x), @intCast(y), canvas.rgb(r, g, 80));
        }
    }
}

/// Write header then body, and return the slice actually used.
///
/// The header is formatted from the same constants that size the buffer.
/// Hardcoding "P6\n64 32\n255\n" works right up until someone changes one of
/// them, at which point the header and the data disagree and the image tears
/// diagonally, with no error reported anywhere.
fn encodeP6(out: []u8) ![]const u8 {
    const header = try std.mem.print(out, "P6\n{d} {d}\n255\n", .{
        canvas.width, canvas.height,
    });

    var n = header.len;
    for (pixels) |p| {
        const c = canvas.channels(p);
        out[n + 0] = c.r;
        out[n + 1] = c.g;
        out[n + 2] = c.b;
        n += 3;
    }
    return out[0..n];
}

const Image = struct { w: usize, h: usize, data: []const u8 };

/// Enough of a reader for files this code writes. It does not handle `#`
/// comments, which a general parser must.
fn decodeP6(bytes: []const u8) !Image {
    if (!std.mem.startsWith(u8, bytes, "P6")) return error.NotP6;

    var it = std.mem.tokenizeAny(u8, bytes[2..], " \t\r\n");
    const w = try std.fmt.parseInt(usize, it.next() orelse return error.Truncated, 10);
    const h = try std.fmt.parseInt(usize, it.next() orelse return error.Truncated, 10);
    const maxval = try std.fmt.parseInt(usize, it.next() orelse return error.Truncated, 10);
    if (maxval != 255) return error.UnsupportedMaxval;

    // Exactly one whitespace byte follows maxval, and everything after it is
    // pixel data. The tokenizer stops before that byte, hence the `+ 1`.
    const data_start = 2 + it.index + 1;
    if (data_start + w * h * 3 > bytes.len) return error.Truncated;
    return .{ .w = w, .h = h, .data = bytes[data_start..] };
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    drawScene();
    const file = try encodeP6(&file_bytes);

    try out.print("total bytes: {d}\n", .{file.len});
    try out.print("header:      {d} bytes, body {d}x{d}x3 = {d}\n", .{
        file.len - canvas.width * canvas.height * 3,
        canvas.width,
        canvas.height,
        canvas.width * canvas.height * 3,
    });

    try out.writeAll("first 16:   ");
    for (file[0..16]) |b| try out.print(" {X:0>2}", .{b});
    try out.writeAll("\n");
    try out.writeAll("as text:     ");
    for (file[0..16]) |b| {
        try out.writeByte(if (b >= 0x20 and b < 0x7F) b else '.');
    }
    try out.writeAll("\n\n");

    const decoded = try decodeP6(file);
    try out.print("decoded:     {d}x{d}, {d} bytes of pixel data\n", .{
        decoded.w, decoded.h, decoded.w * decoded.h * 3,
    });
    try out.print("pixel (0,0): {d} {d} {d}\n", .{
        decoded.data[0], decoded.data[1], decoded.data[2],
    });
    const last = (canvas.width * canvas.height - 1) * 3;
    try out.print("last pixel:  {d} {d} {d}\n", .{
        decoded.data[last], decoded.data[last + 1], decoded.data[last + 2],
    });

    // One extra newline after maxval would shift every pixel by a byte, and no
    // parser can detect it: 0x0A is a legal pixel value.
    const shifted = decodeP6("P6\n2 1\n255\n\n\x01\x02\x03\x04\x05\x06") catch unreachable;
    try out.print("shifted by one: first pixel reads {d} {d} {d}\n", .{
        shifted.data[0], shifted.data[1], shifted.data[2],
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.ppm-write`)*

## The pixel data

Pixels run left to right, top to bottom. No padding, no alignment, no row
headers. Each pixel is three samples in R, G, B order.

Sample size follows from the maxval:

- **maxval below 256** gives one byte per sample. `640 * 480 * 3` is 921,600
  bytes.
- **maxval from 256 to 65535** gives *two* bytes per sample, **big-endian**.
  This is the only place PPM has a byte order, and it trips people up on
  little-endian machines.

Anything other than 255 means your samples are scaled: with a maxval of 100, a
sample of 50 is mid-gray. Use 255 unless you have a reason not to.

A `#` starts a comment that runs to the end of the line and may appear
anywhere whitespace may. Writing one is easy; reading them is not, because a
strict parser has to strip comments while it scans the header fields. Plenty
of naive parsers get that wrong, so leave them out if the file has to travel.

## Format the header from the constants

```zig
const header = try std.mem.print(out, "P6\n{d} {d}\n255\n", .{ width, height });
```

The header comes from the same `width` and `height` that size the buffer.
Hardcoding `"P6\n640 480\n255\n"` works right up until someone changes a
constant, at which point the header and the data disagree, the image tears
diagonally, and nothing anywhere reports an error.

## On disk

The file version is two writes: the header, then the pixels.

```zig
const std = @import("std");

const width: usize = 640;
const height: usize = 480;

// Three bytes per pixel, 921,600 of them. Global, not on the stack.
var pixels: [width * height * 3]u8 = undefined;

fn putPixel(x: usize, y: usize, r: u8, g: u8, b: u8) void {
    if (x >= width or y >= height) return;
    const i = (y * width + x) * 3;
    pixels[i + 0] = r;
    pixels[i + 1] = g;
    pixels[i + 2] = b;
}

fn drawScene() void {
    for (0..height) |y| {
        for (0..width) |x| {
            const r: u8 = @intCast((x * 255) / (width - 1));
            const g: u8 = @intCast((y * 255) / (height - 1));
            putPixel(x, y, r, g, 80);
        }
    }

    // Painted second, so it lands on top. There is no depth buffer and no
    // transparency here: a later write simply overwrites an earlier one.
    const cx: i32 = @intCast(width / 2);
    const cy: i32 = @intCast(height / 2);
    const radius: i32 = 100;
    var y: i32 = cy - radius;
    while (y <= cy + radius) : (y += 1) {
        var x: i32 = cx - radius;
        while (x <= cx + radius) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= radius * radius) {
                putPixel(@intCast(x), @intCast(y), 255, 220, 40);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf_out: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf_out);
    const out = &stdout.interface;

    drawScene();

    var dir = std.Io.Dir.cwd();

    // Written for real, then read back and removed, so the example leaves
    // nothing behind on the machine that ran it.
    defer dir.deleteFile(io, "output.ppm") catch {};

    // `.read = true` only so the check at the end can reopen nothing: a
    // createFile handle is write-only by default.
    const file = try dir.createFile(io, "output.ppm", .{ .read = true });
    defer file.close(io);

    var header_buf: [32]u8 = undefined;
    const header = try std.mem.print(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height });

    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, &pixels);

    // Reading the header back is the only way to know the two writes above
    // landed in the right order. A viewer would tell you eventually; this
    // tells the build.
    var check: [15]u8 = undefined;
    _ = try file.readPositionalAll(io, &check, 0);

    try out.writeAll("header read back:\n");
    try out.writeAll(check[0..header.len]);
    try out.print("bytes on disk: {d}\n", .{header.len + pixels.len});
    try out.flush();
}

// Marked `//! native`: CI builds this for the host and runs it against a real
// filesystem, so the file really is written and read back. The browser cannot
// run it, because the WASI sandbox has no preopened directories.
```

*Built and run natively by CI: the file really is written, read back and removed. Browser wasm has no filesystem to write to. (`09-graphics.ppm-file`)*

Note the drawing order. Background first, then the circle on top, and the
circle simply overwrites what was there. That is the painter's algorithm, and
until [Alpha Blending](../blending/) it is the entire compositing model here.

The `defer` that deletes `output.ppm` is there so the build that verifies this
page leaves nothing behind. Drop that one line when you run it yourself, or
the file you came here to look at will be gone before you can.

To look at the result, most Linux viewers open PPM directly (`feh
output.ppm`), and both ImageMagick and the netpbm tools convert it:

```bash
magick output.ppm output.png
pnmtopng output.ppm > output.png
```

To check the header without opening the whole file:

```bash
head -c 20 output.ppm | xxd
# 00000000: 5036 0a36 3430 2034 3830 0a32 3535 0a00  P6.640 480.255..
```

`5036` is `P6`, and the `0a` immediately before the pixel data is that one
mandatory whitespace byte.

## When to use something else

PPM is uncompressed. A 4K frame is 24 MB and a sequence of them fills a disk
quickly. It is the right tool for getting pixels out of a program you are
writing, and the wrong tool for storing or sharing them. Once the image is
correct, convert it.

The exception is video. `ffmpeg` reads a stream of concatenated PPMs, which
makes it a good pipe format for a software renderer producing frames:

```bash
./renderer | ffmpeg -f image2pipe -i - out.mp4
```
