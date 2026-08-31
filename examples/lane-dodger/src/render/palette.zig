//! Colours, as plain data.
//!
//! No raylib in here, so the particle system that uses these stays testable
//! without a window. `draw.zig` converts to raylib's colour type at the edge.

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn alpha(self: Color, value: f32) Color {
        const clamped = if (value < 0) 0 else if (value > 1) 1 else value;
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = @intFromFloat(clamped * 255) };
    }

    pub fn mix(a: Color, b: Color, t: f32) Color {
        const clamped = if (t < 0) 0 else if (t > 1) 1 else t;
        return .{
            .r = lerp(a.r, b.r, clamped),
            .g = lerp(a.g, b.g, clamped),
            .b = lerp(a.b, b.b, clamped),
            .a = lerp(a.a, b.a, clamped),
        };
    }

    fn lerp(a: u8, b: u8, t: f32) u8 {
        const af: f32 = @floatFromInt(a);
        const bf: f32 = @floatFromInt(b);
        return @intFromFloat(af + (bf - af) * t);
    }
};

pub const background: Color = .{ .r = 0x12, .g = 0x14, .b = 0x28 };
pub const road: Color = .{ .r = 0x1C, .g = 0x1F, .b = 0x3C };
pub const lane_line: Color = .{ .r = 0x2C, .g = 0x31, .b = 0x55 };
pub const stripe: Color = .{ .r = 0x33, .g = 0x39, .b = 0x63 };

pub const player: Color = .{ .r = 0x22, .g = 0xD3, .b = 0xEE };
pub const player_dark: Color = .{ .r = 0x0E, .g = 0x84, .b = 0x9B };

pub const block: Color = .{ .r = 0xF4, .g = 0x3F, .b = 0x5E };
pub const block_dark: Color = .{ .r = 0x9F, .g = 0x12, .b = 0x39 };
pub const block_top: Color = .{ .r = 0xFB, .g = 0x71, .b = 0x85 };

pub const coin: Color = .{ .r = 0xFB, .g = 0xBF, .b = 0x24 };
pub const coin_dark: Color = .{ .r = 0xB4, .g = 0x83, .b = 0x09 };

pub const text: Color = .{ .r = 0xE7, .g = 0xE9, .b = 0xF5 };
pub const text_dim: Color = .{ .r = 0x8A, .g = 0x90, .b = 0xB8 };
pub const good: Color = .{ .r = 0x4A, .g = 0xDE, .b = 0x80 };
