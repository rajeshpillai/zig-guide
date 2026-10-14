//! Brush presets: a name and a set of brush settings, saved as JSON.
//!
//! JSON because a preset is small and a person may want to read it or edit
//! it by hand. A preset describes how a brush behaves. It holds no pixels.
//!
//! A preset file is input, so it is checked before it is used, and a bad
//! one is refused with an error. It is never repaired. A slider that quietly
//! moved a radius of -3 to 0.5 would hide the mistake in the file, and the
//! person would get a brush they did not ask for.

const std = @import("std");
const Brush = @import("brush.zig").Brush;

pub const version: u32 = 1;
pub const max_name = 40;

/// The file, as JSON sees it. Fields missing from the file take the default
/// brush's value, and fields this program does not know are skipped, so a
/// preset written by a later version still opens if its known fields fit.
const File = struct {
    version: u32,
    name: []const u8,
    brush: Settings,
};

/// `Brush`, with the colour as "#rrggbb" text instead of three bytes, and
/// the numbers as `f64`. `std.json` writes an `f32` by widening it to `f64`
/// first, so 0.2 would come out as 0.20000000298023224. `write` stores the
/// shortest decimal that reads back as the same `f32`, which JSON then
/// prints the way a person would type it.
const Settings = struct {
    radius: f64 = d.radius,
    hardness: f64 = d.hardness,
    flow: f64 = d.flow,
    opacity: f64 = d.opacity,
    spacing: f64 = d.spacing,
    follow: f64 = d.follow,
    pressure: f64 = d.pressure,
    jitter: f64 = d.jitter,
    scatter: f64 = d.scatter,
    aspect: f64 = d.aspect,
    angle: f64 = d.angle,
    follow_direction: bool = d.follow_direction,
    contact: f64 = d.contact,
    bristles: u32 = d.bristles,
    pickup: f64 = d.pickup,
    drain: f64 = d.drain,
    color: []const u8 = "#26334d",

    const d: Brush = .{};
};

pub const Preset = struct {
    /// Up to `max_name` bytes. Points into the buffer given to `parse`.
    name: []const u8,
    brush: Brush,
};

pub const ParseError = error{
    /// Not JSON, or JSON of the wrong shape.
    NotAPreset,
    /// Written by a later version of this program.
    NewerVersion,
    /// Empty, too long, or containing control characters.
    BadName,
    /// Not "#" and six hex digits.
    BadColor,
    /// A setting outside the range the brush allows, or not a number.
    OutOfRange,
    OutOfMemory,
};

/// Read a preset. The name in the result points into `name_buf`.
pub fn parse(gpa: std.mem.Allocator, json: []const u8, name_buf: *[max_name]u8) ParseError!Preset {
    const parsed = std.json.parseFromSlice(File, gpa, json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotAPreset,
    };
    defer parsed.deinit();
    const file = parsed.value;

    if (file.version > version) return error.NewerVersion;
    if (file.version != version) return error.NotAPreset;

    if (file.name.len == 0 or file.name.len > max_name) return error.BadName;
    for (file.name) |c| if (c < 0x20 or c == 0x7f) return error.BadName;

    const s = file.brush;
    const brush: Brush = .{
        .radius = @floatCast(s.radius),
        .hardness = @floatCast(s.hardness),
        .flow = @floatCast(s.flow),
        .opacity = @floatCast(s.opacity),
        .spacing = @floatCast(s.spacing),
        .follow = @floatCast(s.follow),
        .pressure = @floatCast(s.pressure),
        .jitter = @floatCast(s.jitter),
        .scatter = @floatCast(s.scatter),
        .aspect = @floatCast(s.aspect),
        .angle = @floatCast(s.angle),
        .follow_direction = s.follow_direction,
        .contact = @floatCast(s.contact),
        .bristles = s.bristles,
        .pickup = @floatCast(s.pickup),
        .drain = @floatCast(s.drain),
        .color = try parseColor(s.color),
    };
    // Valid means the brush is already one the engine would draw with
    // unchanged. Anything `sanitized` would have to move is out of range,
    // and NaN never equals itself, so it fails here too.
    if (!std.meta.eql(brush.sanitized(), brush)) return error.OutOfRange;

    @memcpy(name_buf[0..file.name.len], file.name);
    return .{ .name = name_buf[0..file.name.len], .brush = brush };
}

/// The shortest decimal that reads back as `x`, as an `f64`: 0.2 for the
/// `f32` nearest to 0.2, where widening would give 0.20000000298023224.
fn decimal(x: f32) f64 {
    var buf: [64]u8 = undefined;
    const text = std.mem.print(&buf, "{d}", .{x}) catch unreachable;
    return std.fmt.parseFloat(f64, text) catch unreachable;
}

fn parseColor(text: []const u8) error{BadColor}![3]u8 {
    if (text.len != 7 or text[0] != '#') return error.BadColor;
    var out: [3]u8 = undefined;
    for (&out, 0..) |*c, i| {
        c.* = std.fmt.parseInt(u8, text[1 + i * 2 ..][0..2], 16) catch return error.BadColor;
    }
    return out;
}

/// Write a preset as JSON. The seed is not saved: it belongs to a stroke,
/// not to the brush's character.
pub fn write(out: *std.Io.Writer, name: []const u8, b: Brush) !void {
    var color: [7]u8 = undefined;
    _ = std.mem.print(&color, "#{x:0>2}{x:0>2}{x:0>2}", .{ b.color[0], b.color[1], b.color[2] }) catch unreachable;
    const file: File = .{
        .version = version,
        .name = name,
        .brush = .{
            .radius = decimal(b.radius),
            .hardness = decimal(b.hardness),
            .flow = decimal(b.flow),
            .opacity = decimal(b.opacity),
            .spacing = decimal(b.spacing),
            .follow = decimal(b.follow),
            .pressure = decimal(b.pressure),
            .jitter = decimal(b.jitter),
            .scatter = decimal(b.scatter),
            .aspect = decimal(b.aspect),
            .angle = decimal(b.angle),
            .follow_direction = b.follow_direction,
            .contact = decimal(b.contact),
            .bristles = b.bristles,
            .pickup = decimal(b.pickup),
            .drain = decimal(b.drain),
            .color = &color,
        },
    };
    try std.json.Stringify.value(file, .{ .whitespace = .indent_2 }, out);
    try out.writeByte('\n');
}

const testing = std.testing;

test "a saved preset reads back as the same brush" {
    const brush: Brush = .{ .radius = 4, .flow = 0.7, .color = .{ 0x26, 0x33, 0x4d }, .bristles = 5, .pickup = 0.1 };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, "Fine sketch", brush);

    var name: [max_name]u8 = undefined;
    const back = try parse(testing.allocator, out.written(), &name);
    try testing.expectEqualStrings("Fine sketch", back.name);
    try testing.expect(std.meta.eql(brush, back.brush));
}

test "settings are written as typed: 0.2, not 0.20000000298023224" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, "Nib", .{ .aspect = 0.2, .hardness = 0.95 });
    try testing.expect(std.mem.find(u8, out.written(), "\"aspect\": 0.2,") != null);
    try testing.expect(std.mem.find(u8, out.written(), "\"hardness\": 0.95,") != null);
}

test "missing fields take the defaults, unknown fields are skipped" {
    var name: [max_name]u8 = undefined;
    const p = try parse(testing.allocator,
        \\{ "version": 1, "name": "Tiny", "brush": { "radius": 2, "sparkle": true } }
    , &name);
    try testing.expectEqual(@as(f32, 2), p.brush.radius);
    try testing.expectEqual((Brush{}).flow, p.brush.flow);
}

test "a bad preset is refused with a reason, never repaired" {
    const Case = struct { json: []const u8, want: ParseError };
    const cases = [_]Case{
        .{ .json = "not json", .want = error.NotAPreset },
        .{ .json = "{\"version\":2,\"name\":\"x\",\"brush\":{}}", .want = error.NewerVersion },
        .{ .json = "{\"version\":1,\"name\":\"\",\"brush\":{}}", .want = error.BadName },
        .{ .json = "{\"version\":1,\"name\":\"x\",\"brush\":{\"color\":\"red\"}}", .want = error.BadColor },
        .{ .json = "{\"version\":1,\"name\":\"x\",\"brush\":{\"radius\":-3}}", .want = error.OutOfRange },
        .{ .json = "{\"version\":1,\"name\":\"x\",\"brush\":{\"flow\":7}}", .want = error.OutOfRange },
        .{ .json = "{\"version\":1,\"name\":\"x\",\"brush\":{\"bristles\":99}}", .want = error.OutOfRange },
    };
    var name: [max_name]u8 = undefined;
    for (cases) |c| try testing.expectError(c.want, parse(testing.allocator, c.json, &name));
}
