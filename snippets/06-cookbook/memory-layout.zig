//! title: Struct Memory Layout
//! Padding, explicit alignment, packed bit-fields, and the C-ABI layout.

const std = @import("std");

// Default (auto) layout. The compiler picks offsets for this target; it is
// free to add padding so each field sits on its natural alignment.
const Padded = struct {
    a: u8,
    b: u64,
    c: u32,
};

// One field forced to a 16-byte boundary. A field's alignment raises the
// whole struct's alignment to the largest of its fields.
const Aligned = struct {
    a: u8 align(16),
    b: u8,
};

// Packed: no padding, fields in declaration order, sub-byte integers allowed.
// Bit-cast to an unsigned integer of the same width for hardware registers.
const Register = packed struct {
    enable: bool, // bit 0
    mode: u3, // bits 1..3
    reserved: u4, // bits 4..7
    value: u8, // bits 8..15
};

// Extern: follows the platform C ABI, so it can cross an FFI boundary.
const CStruct = extern struct {
    a: u8,
    b: u32,
};

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try out.print("Padded:   size={d} align={d} offsets a={d} b={d} c={d}\n", .{
        @sizeOf(Padded),   @alignOf(Padded),
        @offsetOf(Padded, "a"), @offsetOf(Padded, "b"), @offsetOf(Padded, "c"),
    });

    try out.print("Aligned:  size={d} align={d} offset b={d}\n", .{
        @sizeOf(Aligned), @alignOf(Aligned), @offsetOf(Aligned, "b"),
    });

    const reg = Register{ .enable = true, .mode = 0b101, .reserved = 0, .value = 42 };
    const raw: u16 = @bitCast(reg);
    try out.print("Register: size={d} raw=0x{X:0>4}\n", .{ @sizeOf(Register), raw });

    try out.print("CStruct:  size={d} offset b={d}\n", .{
        @sizeOf(CStruct), @offsetOf(CStruct, "b"),
    });

    try out.flush();
}
