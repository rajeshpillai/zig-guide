# Recipe: A Binary Wire Format

> Serialize a struct to explicit bytes and back, with safe checks.

In Zig, write a binary wire format one field at a time with `std.mem.writeInt`. Read the format back with `std.mem.readInt`. Each call gives its endianness. The decoder checks a magic number first. Thus bad input returns an error, and the decoder does not return random values.

## The problem

You must write a struct to a location outside your process, for example a file header, a network packet or a save format. Later, you must read the struct back, possibly on a different machine.

A fast method is to copy the memory of the struct directly with `std.mem.asBytes` or `@bitCast`. Do not use this method. For a plain Zig struct, the field order and the padding are not specified. Also, the integers of the struct are in the byte order of the *host*. Thus the bytes can change when the compiler, the target or the optimizer changes. A wire format must specify each byte exactly.

## The plan

1. **Specify the format on paper first.** The format is a 4-byte magic, a 2-byte version and a 4-byte payload length, all big-endian. That is ten bytes, with no padding and only one meaning.
2. **Encode one field at a time** with `std.mem.writeInt`. This function takes the endianness as an argument.
3. **Do not trust the input when you decode.** Input from outside the process is untrusted. The magic check occurs first, and it returns an error value, not an assertion.

```zig
const std = @import("std");

const MAGIC: u32 = 0x5A49_4721; // "ZIG!"

const Header = struct {
    version: u16,
    payload_len: u32,

    const encoded_len = 10; // 4 magic + 2 version + 4 length

    // Write one field at a time with a fixed endianness. A cast of the memory
    // of the struct with @bitCast or std.mem.asBytes puts padding and the byte
    // order of the host into the format. That cast works in RAM. It is wrong
    // in a file or on a network.
    fn encode(h: Header, buf: *[encoded_len]u8) void {
        std.mem.writeInt(u32, buf[0..4], MAGIC, .big);
        std.mem.writeInt(u16, buf[4..6], h.version, .big);
        std.mem.writeInt(u32, buf[6..10], h.payload_len, .big);
    }

    // The decoder reads untrusted bytes. Thus check all of the bytes that you read.
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

    // Change the first byte. The decoder does not accept the result.
    wire[0] ^= 0xFF;
    if (Header.decode(&wire)) |_| unreachable else |err| {
        try out.print("corrupted first byte: {t}\n", .{err});
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.binary-roundtrip`)*

## Why the buffer type does the bounds check

`encode` takes `*[encoded_len]u8`. That type is a pointer to an array of *exactly* ten bytes, not a slice. A buffer of the wrong size is a **compile error**.

Inside the function, `buf[0..4]` is a sub-array with a size that is known at comptime. Thus `writeInt` does not need a length check at runtime. The size of the format is in one declaration (`encoded_len`), and the encoder and the decoder both use that declaration.

## Why a magic number

A version field tells you *which* format you read. The magic tells you if the data is your format *at all*.

The file can be incomplete, or it can be the wrong file, or the bytes can start one position too early. In each of these conditions, the decoder fails immediately with `error.BadMagic`. It does not decode incorrect lengths and report success.

The last step of the snippet changes one byte, and the output shows that this path runs. The decoder returns an error and does not panic. Bad input is an expected condition, not a bug.

## Variations

- **Floats:** `writeInt(u32, buf, @bitCast(f), .little)` writes an `f32` and gets back exactly the same value. The decoder returns the same bit pattern that the encoder wrote. Do not write floats as text in a binary protocol.
- **`packed struct`** gives you a guaranteed bit layout *inside* an integer, for example flags or the nibbles of a header. Use `@bitCast` to change the packed struct to its backing integer. Then write that integer with `writeInt` and an explicit endianness, as usual.
- **Streams:** the same encode and decode functions work on a reader and a writer. Parse the header of fixed size first. Then the header tells you how many payload bytes to expect.
