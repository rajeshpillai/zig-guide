# Linear Light

> A stored byte is not an amount of light. Decode, mix, encode, with both tables built by the compiler.

Halfway between black and white, most code writes 128.

That is half of 255.

But a screen showing 128 gives out about 22% of the light it gives for 255.

The bytes in an image are not amounts of light. They are encoded.

So we decode the bytes to light, mix the light, and encode the result again.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// sRGB byte to linear light, 0.0 to 1.0. The constants 0.04045, 12.92,
/// 0.055 and 2.4 come from the sRGB standard. They are not tuning values.
fn decode(byte: u8) f64 {
    const c = @as(f64, @floatFromInt(byte)) / 255.0;
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

/// Linear light, 0.0 to 1.0, to sRGB, 0.0 to 1.0. The inverse of `decode`.
fn encode(light: f64) f64 {
    return if (light <= 0.0031308) light * 12.92 else 1.055 * std.math.pow(f64, light, 1.0 / 2.4) - 0.055;
}

/// Linear light is kept in 16 bits: 0 is black and 65535 is full white.
/// Eight bits is not enough. The dark bytes 0 to 6 would all become 0.
const Light = u16;

/// One entry per byte. A `const` initialised by a block runs at compile time,
/// so the program carries 512 bytes of table and does no `pow` at run time.
const to_light: [256]Light = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [256]Light = undefined;
    for (&table, 0..) |*entry, byte| {
        entry.* = @intFromFloat(@round(decode(@intCast(byte)) * 65535.0));
    }
    break :blk table;
};

/// The way back. 65536 entries would be 64 KB, so the table is indexed by the
/// top 12 bits of the light value instead. Each entry holds the byte for the
/// middle of its range of 16 light values.
const to_byte: [4096]u8 = blk: {
    @setEvalBranchQuota(10_000_000);
    var table: [4096]u8 = undefined;
    for (&table, 0..) |*entry, i| {
        const middle = @as(f64, @floatFromInt(i * 16 + 8)) / 65535.0;
        entry.* = @intFromFloat(@round(encode(middle) * 255.0));
    }
    break :blk table;
};

fn toLight(byte: u8) Light {
    return to_light[byte];
}

fn toByte(light: Light) u8 {
    return to_byte[light >> 4];
}

/// Mix two stored bytes directly: `a` weighted (n - k) and `b` weighted k,
/// rounded to the nearest byte. This is what most 8-bit code does.
fn mixBytes(a: u8, b: u8, k: u32, n: u32) u8 {
    return @intCast((@as(u32, a) * (n - k) + @as(u32, b) * k + n / 2) / n);
}

/// The same mix, done on light: decode, mix, encode.
fn mixLight(a: u8, b: u8, k: u32, n: u32) u8 {
    const la: u32 = toLight(a);
    const lb: u32 = toLight(b);
    return toByte(@intCast((la * (n - k) + lb * k + n / 2) / n));
}

fn mixColor(comptime mix: fn (u8, u8, u32, u32) u8, a: u32, b: u32, k: u32, n: u32) u32 {
    const ca = canvas.channels(a);
    const cb = canvas.channels(b);
    return canvas.rgb(mix(ca.r, cb.r, k, n), mix(ca.g, cb.g, k, n), mix(ca.b, cb.b, k, n));
}

/// Four bands of eight rows. Each band is a ramp from left to right.
fn drawBands() void {
    const black = canvas.rgb(0, 0, 0);
    const white = canvas.rgb(255, 255, 255);
    const red = canvas.rgb(255, 0, 0);
    const green = canvas.rgb(0, 255, 0);
    const n = canvas.width - 1;

    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            const k: u32 = @intCast(x);
            const color = switch (y / 8) {
                0 => mixColor(mixBytes, black, white, k, n),
                1 => mixColor(mixLight, black, white, k, n),
                2 => mixColor(mixBytes, red, green, k, n),
                else => mixColor(mixLight, red, green, k, n),
            };
            pixels[y * canvas.width + x] = color;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try out.writeAll("halfway from black to white\n");
    try out.print("  mixing bytes: {d}\n", .{mixBytes(0, 255, 1, 2)});
    try out.print("  mixing light: {d}\n", .{mixLight(0, 255, 1, 2)});

    const red = canvas.rgb(255, 0, 0);
    const green = canvas.rgb(0, 255, 0);
    const by_bytes = canvas.channels(mixColor(mixBytes, red, green, 1, 2));
    const by_light = canvas.channels(mixColor(mixLight, red, green, 1, 2));
    try out.writeAll("halfway from red to green\n");
    try out.print("  mixing bytes: {d} {d} {d}\n", .{ by_bytes.r, by_bytes.g, by_bytes.b });
    try out.print("  mixing light: {d} {d} {d}\n", .{ by_light.r, by_light.g, by_light.b });

    // Byte 128 holds about 22% of the light of byte 255, not 50%.
    try out.print("light in byte 128: {d}%\n", .{(@as(u32, toLight(128)) * 100 + 32767) / 65535});

    // Every byte must come back as itself. If the encode table were too
    // coarse, the dark bytes would be the first to fail this.
    var exact: u32 = 0;
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        if (toByte(toLight(byte)) == byte) exact += 1;
    }
    try out.print("bytes that survive byte -> light -> byte: {d} of 256\n", .{exact});

    // The same trip through 8-bit light instead of 16-bit light.
    var seen: [256]bool = @splat(false);
    var kept: u32 = 0;
    for (0..256) |i| {
        const light8 = (@as(u32, toLight(@intCast(i))) * 255 + 32767) / 65535;
        if (!seen[light8]) kept += 1;
        seen[light8] = true;
    }
    try out.print("distinct bytes left after 8-bit light: {d} of 256\n", .{kept});

    try out.print("tables: {d} bytes, built by the compiler\n", .{@sizeOf(@TypeOf(to_light)) + @sizeOf(@TypeOf(to_byte))});

    drawBands();
    try canvas.writePicture(init.io, out, "linear-light.ppm", &pixels);
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.linear-light`)*

## The worked example

Halfway from black to white, done two ways:

- Mixing the bytes: (0 + 255) / 2 is 128, rounded.
- Mixing the light: 0% light and 100% light average to 50%. Encoded again, 50% light is byte 188.

The output prints both, and 128 and 188 are far apart.

Red to green shows the same thing in colour.

Mixing the bytes gives `128 128 0`, a dark olive.

Mixing the light gives `188 188 0`, a yellow.

The third and fourth bands of the picture are those two ramps.

## Why images store encoded bytes

Our eyes do not see light linearly.

We notice a small change in a dark area much more than the same change in a bright area.

The sRGB encoding gives more of its 256 values to dark tones for that reason. The steps between bytes look roughly even to a person.

That is why the first band in the picture looks even, and the second band looks mostly pale.

The second band has even steps of light, and most of those steps look bright to us.

So there are two different jobs:

- Storing and showing a colour: use the encoded bytes.
- Adding or averaging light: use linear values.

Blending, blurring, scaling an image and antialiasing all add or average light. They belong in linear.

## The conversion

The sRGB standard defines the curve in two pieces: a short straight line near black, and a power curve for the rest.

<SnippetSource name="09-graphics.linear-light" decl="decode" />

The numbers 0.04045, 12.92, 0.055 and 2.4 come from the standard.

Copy them as they are.

A plain `x^2.2` curve is close, but it is not the same near black.

`encode` is the same curve run backwards.

## Tables built by the compiler

`pow` is slow, and a byte has only 256 possible values.

So we compute all 256 answers once and keep them in a table.

<SnippetSource name="09-graphics.linear-light" decl="to_light" />

This is an ordinary loop inside a block.

But the block initialises a top-level `const`, so Zig runs it at compile time.

The finished program contains the 256 numbers and never calls `pow` for them.

`@setEvalBranchQuota` raises the compiler's limit on how much work a compile-time block may do.

`pow` loops inside, so the default limit is too low. Without the call, the build fails with an error that names `@setEvalBranchQuota`.

## Why light needs 16 bits

The table stores light as a `u16`, not a `u8`.

The output shows what happens with 8 bits.

Only 183 of the 256 bytes come back as different values. The bytes 0 to 6 all become 0, so seven dark greys turn into black.

The dark tones need fine steps in linear, because the encoding gave so many bytes to them.

With 16 bits, every byte survives the trip and comes back as itself.

The output checks all 256.

## The way back

Encoding needs a second table.

A table indexed by the full 16-bit value would need 65536 entries.

So this table is indexed by the top 12 bits. Each entry covers 16 light values and holds the byte for the middle of them.

<SnippetSource name="09-graphics.linear-light" decl="to_byte" />

Sixteen light values per entry is fine enough, even near black.

Near black, one byte is about 20 light values wide.

The middle of an entry is never more than 8 light values from any value it covers.

That is less than half a byte, so rounding still lands on the right byte.

The round-trip line in the output is the proof. If the table were too coarse, the dark bytes would fail first.

## Mixing

With the two tables, mixing in light is two lookups, the same arithmetic, and one more lookup.

<SnippetSource name="09-graphics.linear-light" decl="mixLight" />

Compare it with `mixBytes` in the snippet above.

The arithmetic is identical. Only the kind of number it works on changes.

The [Alpha Blending](https://www.ziglang.in/learn/graphics/blending/) chapter blends bytes directly, and says so.

To blend in linear, decode both colours with `toLight`, run the same blend in 16 bits, and encode the result with `toByte`.

## What linear light does not fix

Linear light describes light adding up, like two torches pointed at one wall.

Paint does not work this way. Pigments absorb light.

Yellow paint mixed with blue paint makes green.

Yellow light mixed with blue light makes grey, in linear or in bytes.

So linear mixing is correct for a screen and for a camera. It is not a model of paint.

## Explain before reading the answer

Draw a checkerboard of single black and white pixels.

Look at it from across the room, so the squares blur together.

Which grey matches it: byte 128 or byte 188?

The answer is 188.

Half the pixels give full light and half give none. Your eye averages the light, so it sees 50% light.

50% light is byte 188, not 128.
