# Recipe: Struct Memory Layout

> Read the size, alignment and field offsets that a struct really gets, and control them.

In Zig, `@sizeOf`, `@alignOf` and `@offsetOf` report the real size, alignment and field offsets of a struct. A plain struct can change the order of its fields. Use `extern struct` to match C, and use `packed struct` for exact bits.

## The problem

You must know how a struct is in memory:

- the size of the struct
- the position of each field
- if you can give the struct to C or to hardware

Do not guess from the field types. The default layout can change the order of the fields and add padding.

## The plan

1. Examine a type with `@sizeOf`, `@alignOf` and `@offsetOf`.
2. Put a field on a specified boundary with `align(N)`.
3. Use `packed struct` for fields at the bit level with no padding. Then use `@bitCast` to change the struct to an integer.
4. Use `extern struct` when the layout must match the C ABI.

```zig
const std = @import("std");

// Default (auto) layout. The compiler selects the offsets for this target.
// It can add padding, so that each field is on its natural alignment.
const Padded = struct {
    a: u8,
    b: u64,
    c: u32,
};

// One field must be on a 16-byte boundary. The alignment of the struct is
// the largest alignment of its fields.
const Aligned = struct {
    a: u8 align(16),
    b: u8,
};

// Packed: no padding, fields in declaration order, and integers smaller than
// a byte. For hardware registers, use @bitCast to change the struct to an
// unsigned integer of the same width.
const Register = packed struct {
    enable: bool, // bit 0
    mode: u3, // bits 1..3
    reserved: u4, // bits 4..7
    value: u8, // bits 8..15
};

// Extern: follows the C ABI of the platform. Thus it can cross an FFI boundary.
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.memory-layout`)*

## The default layout changes the order of fields

The declaration of `Padded` is `a: u8, b: u64, c: u32`. A C programmer expects this layout: `a` at offset 0, seven bytes of padding, `b` at 8 and `c` at 16. The total is 24 bytes.

The default layout of Zig is not specified, and the current compiler uses that freedom. The compiler puts `b` at 0, `c` at 8 and `a` at 12. The total is 16 bytes. With the largest field first, the padding decreases from eleven bytes to three bytes.

These numbers are specific to this compiler and this target. Do not depend on the field order of an `auto` struct. If a byte offset is important, read it with `@offsetOf`, or use a layout that guarantees the order.

## `align(N)` increases the alignment of the full struct

`Aligned` puts `a` on a 16-byte boundary. The alignment of a field cannot decrease the alignment of the struct. It can only increase it. Thus the full struct gets an alignment of 16 and a size of 16 bytes.

Use this when a buffer must align with a cache line, or when a device expects a specific boundary.

## Packed structs give you bits

A `packed struct` has no padding and keeps the fields in the order of the declaration. It also allows integers smaller than a byte. `Register` puts a `bool`, a `u3`, a `u4` and a `u8` into exactly two bytes. `@bitCast` gives the same bits as an integer, with no copy.

The fields fill the integer from the least significant bit. Thus the first field is bit 0, and the last field is in the high byte. The result is `0x2A0B`. Use this method to build the value of a hardware register, or to decode the value.

## Extern structs match C

An `extern struct` follows the C ABI of the platform. The fields stay in order, and the padding follows the rules of C. Thus `CStruct` is 8 bytes, with `b` at offset 4.

Use this layout across an FFI boundary. The [ABI chapter](https://www.ziglang.in/learn/working-with-c/abi/) shows in full how to send these structs to C and get them back from C.

## Variations

- **`std.debug.print("{}", .{@typeInfo(T)})`** shows the fields of a type and their declared types. Use it when you want all of the information at comptime.
- **`@sizeOf` and `@bitSizeOf`:** the second function reports the width in bits. Packed fields use that number of bits.
- **Write the bytes and read them back:** first, set the layout with `packed` or `extern`. Then [the binary round-trip recipe](https://www.ziglang.in/learn/how-to/binary-roundtrip/) writes the struct as raw bytes and reads it back, with a known endianness.
