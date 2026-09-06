# Recipe: Struct Memory Layout

> Read the size, alignment, and field offsets a struct actually gets, and control them.

## The problem

You need to know how a struct sits in memory: how big it is, where each field
lands, and whether you can hand it to C or to hardware. Guessing from the
field types is a mistake, because the default layout is allowed to reorder
fields and insert padding. Zig gives you builtins to read the real numbers and
keywords to pin them down when it matters.

## The plan

1. Inspect any type with `@sizeOf`, `@alignOf`, and `@offsetOf`.
2. Force a field boundary with `align(N)`.
3. Use `packed struct` for bit-level fields with no padding, then `@bitCast`
   it to an integer.
4. Use `extern struct` when the layout must match the C ABI.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.memory-layout`)*

## The default layout reorders fields

`Padded` is declared `a: u8, b: u64, c: u32`. A C programmer expects `a` at
offset 0, seven bytes of padding, `b` at 8, `c` at 16, for 24 bytes. Zig's
default layout is unspecified, and the current compiler uses that freedom. It
places `id` at 0, `name` at 8, and `age` at 12, for a total of 16 bytes.
Putting the largest field first removes the padding a naive order would need.

The lesson is not the specific numbers, which belong to this compiler and this
target. It is that you must not depend on the field order of an `auto` struct.
If a byte offset matters, read it with `@offsetOf`, or use a layout that
guarantees order.

## `align(N)` raises the whole struct

`Aligned` forces `a` to a 16-byte boundary. A field's alignment cannot lower
the struct's alignment, only raise it, so the whole struct becomes 16-aligned
and 16 bytes. Reach for this when a buffer must be cache-line aligned or when
a device expects a specific boundary.

## Packed structs give you bits

`packed struct` drops padding, keeps fields in declaration order, and allows
sub-byte integers. `Register` packs a `bool`, a `u3`, a `u4`, and a `u8` into
exactly two bytes. `@bitCast` reinterprets it with no copy. The fields fill
the integer from the least significant bit up, so the first field is bit 0 and
the last occupies the high byte. The result is `0x2A0B`, which is how you
would build a hardware register value or decode one.

## Extern structs match C

`extern struct` follows the platform C ABI: fields stay in order, padding
follows C rules, so `CStruct` is 8 bytes with `b` at offset 4. This is the
layout to use across an FFI boundary. The [ABI
chapter](https://www.ziglang.in/learn/working-with-c/abi/) covers passing these to and from C in
full.

## Variations

- **`std.debug.print("{}", .{@typeInfo(T)})`** dumps a type's fields and
  their declared types when you want the whole picture at comptime.
- **`@sizeOf` versus `@bitSizeOf`:** the second reports bit width, which is
  what packed fields actually consume.
- **Round-tripping bytes:** once a layout is fixed with `packed` or `extern`,
  [the binary round-trip recipe](https://www.ziglang.in/learn/how-to/binary-roundtrip/) writes and reads
  it as raw bytes with defined endianness.
