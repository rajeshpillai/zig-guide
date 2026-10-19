//! title: Mixing in Linear Light
//! A stored byte is not an amount of light. Decode to linear light, mix, and
//! encode again. The compiler builds both conversion tables.

const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// Change an sRGB byte to linear light, 0.0 to 1.0. The constants 0.04045,
/// 12.92, 0.055 and 2.4 come from the sRGB standard. Do not adjust them.
fn decode(byte: u8) f64 {
    const c = @as(f64, @floatFromInt(byte)) / 255.0;
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

/// Change linear light, 0.0 to 1.0, to sRGB, 0.0 to 1.0. This function is the
/// inverse of `decode`.
fn encode(light: f64) f64 {
    return if (light <= 0.0031308) light * 12.92 else 1.055 * std.math.pow(f64, light, 1.0 / 2.4) - 0.055;
}

/// The program keeps linear light in 16 bits: 0 is black and 65535 is full
/// white. Eight bits are not sufficient. The dark bytes 0 to 6 would all
/// become 0.
const Light = u16;

/// One entry for each byte. A block that initialises a `const` runs at compile
/// time. Thus the program contains a table of 512 bytes, and it does not call
/// `pow` at run time.
const to_light: [256]Light = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [256]Light = undefined;
    for (&table, 0..) |*entry, byte| {
        entry.* = @intFromFloat(@round(decode(@intCast(byte)) * 65535.0));
    }
    break :blk table;
};

/// The conversion from light to a byte. 65536 entries would be 64 KB. Thus the
/// index of the table is the top 12 bits of the light value. Each entry holds
/// the byte for the middle of its range of 16 light values.
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

/// Mix two stored bytes directly. The weight of `a` is (n - k), and the weight
/// of `b` is k. The result rounds to the nearest byte. Most 8-bit code mixes
/// colours in this way.
fn mixBytes(a: u8, b: u8, k: u32, n: u32) u8 {
    return @intCast((@as(u32, a) * (n - k) + @as(u32, b) * k + n / 2) / n);
}

/// The same mix on light: decode, mix, encode.
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

    // Each byte must return as the same byte. If the steps of the encode
    // table were too large, the dark bytes would fail this check first.
    var exact: u32 = 0;
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        if (toByte(toLight(byte)) == byte) exact += 1;
    }
    try out.print("bytes that survive byte -> light -> byte: {d} of 256\n", .{exact});

    // The same conversion, but with 8-bit light instead of 16-bit light.
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
