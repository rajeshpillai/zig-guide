# Recipe: A Binary Wire Format

> Serialize a struct to explicit bytes and back, safely.

## The problem

You need to write a struct somewhere outside your process (a file header, a
network packet, a save format) and read it back later, possibly on a
different machine. The tempting shortcut is to blast the struct's memory out
with `std.mem.asBytes` or `@bitCast`. Don't: a plain Zig struct's field order
and padding are unspecified, and its integers are in *host* byte order. The
bytes would change with the compiler, the target, or the optimizer. A wire
format must be pinned down to the byte.

## The plan

1. **Define the format on paper first:** 4-byte magic, 2-byte version,
   4-byte payload length, all big-endian. Ten bytes, no padding, no
   ambiguity.
2. **Encode field by field** with `std.mem.writeInt`, which takes the
   endianness explicitly.
3. **Decode with suspicion.** Input from outside the process is untrusted;
   the magic check is the first line of defense and returns a real error,
   not an assertion.

```zig
const std = @import("std");

const MAGIC: u32 = 0x5A49_4721; // "ZIG!"

const Header = struct {
    version: u16,
    payload_len: u32,

    const encoded_len = 10; // 4 magic + 2 version + 4 length

    // Field-by-field with a fixed endianness. Casting the struct's memory
    // with @bitCast or std.mem.asBytes would leak padding and host byte
    // order into the format: fine in RAM, wrong on a wire.
    fn encode(h: Header, buf: *[encoded_len]u8) void {
        std.mem.writeInt(u32, buf[0..4], MAGIC, .big);
        std.mem.writeInt(u16, buf[4..6], h.version, .big);
        std.mem.writeInt(u32, buf[6..10], h.payload_len, .big);
    }

    // Decoding is where trust ends: check everything you read.
    fn decode(buf: *const [encoded_len]u8) error{BadMagic}!Header {
        if (std.mem.readInt(u32, buf[0..4], .big) != MAGIC) return error.BadMagic;
        return .{
            .version = std.mem.readInt(u16, buf[4..6], .big),
            .payload_len = std.mem.readInt(u32, buf[6..10], .big),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const header = Header{ .version = 2, .payload_len = 400 };

    var wire: [Header.encoded_len]u8 = undefined;
    header.encode(&wire);

    try out.print("encoded {d} bytes:", .{wire.len});
    for (wire) |b| try out.print(" {X:0>2}", .{b});
    try out.print("\n", .{});

    const decoded = try Header.decode(&wire);
    try out.print("decoded: version={d} payload_len={d}\n", .{
        decoded.version, decoded.payload_len,
    });

    // Corrupt the first byte and the decoder refuses it.
    wire[0] ^= 0xFF;
    if (Header.decode(&wire)) |_| unreachable else |err| {
        try out.print("corrupted first byte: {t}\n", .{err});
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.binary-roundtrip`)*

## Why the buffer type does the bounds checking

`encode` takes `*[encoded_len]u8`: a pointer to an array of *exactly* ten
bytes, not a slice. Passing a buffer of the wrong size is a **compile error**,
and inside the function, `buf[0..4]` is a comptime-known sub-array so
`writeInt` needs no runtime length check either. The format's size lives in
one declaration (`encoded_len`) that both sides share.

## Why a magic number

A version field tells you *which* format you're reading; the magic tells you
whether you're reading your format *at all*. Handed a truncated file, a wrong
file, or bytes shifted by one, the decoder fails immediately with
`error.BadMagic` instead of "successfully" decoding garbage lengths. The
snippet's last step corrupts one byte to prove that path is real. Note it
returns an error rather than panicking: bad input is an expected condition,
not a bug.

## Variations

- **Floats:** `writeInt(u32, buf, @bitCast(f), .little)` round-trips an
  `f32` exactly: bit pattern in, bit pattern out. Never format floats as
  text in a binary protocol.
- **`packed struct`** gives you guaranteed bit layout *within* an integer
  (flags, header nibbles). `@bitCast` the packed struct to its backing
  integer, then `writeInt` that with explicit endianness as usual.
- **Streams:** the same encode/decode pair works on a reader/writer; parse
  the fixed-size header first, then the header tells you how many payload
  bytes to expect.
