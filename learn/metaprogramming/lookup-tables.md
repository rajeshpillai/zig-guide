# Build Lookup Tables

> The compiler calculates a CRC-32 table, and the program checks it against the standard library.

A lookup table replaces a calculation with an array read. You calculate each answer one time and keep the answers in an array. Then the program reads the answer for an input from the array.

In many languages, you calculate the table with a separate script and paste the numbers into the source. In Zig, the compiler calculates the table from usual Zig code. The source keeps the calculation, and the binary keeps only the numbers.

This chapter builds the table for CRC-32. CRC-32 is the checksum in Zip files, PNG files and Ethernet frames. The program then compares its results with `std.hash.Crc32`.

```zig
const std = @import("std");

// The reflected CRC-32 polynomial. Zip, PNG and Ethernet use it.
const poly: u32 = 0xEDB88320;

// One entry for each possible byte. Each entry is the result of eight
// shift-and-xor steps on that byte. The steps run during compilation, and
// the binary contains only the 256 results.
const table: [256]u32 = blk: {
    // 256 bytes times 8 steps is more than 1000 backward branches.
    @setEvalBranchQuota(256 * 8 + 256);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*entry, byte| {
        var c: u32 = @intCast(byte);
        for (0..8) |_| {
            c = if (c & 1 != 0) poly ^ (c >> 1) else c >> 1;
        }
        entry.* = c;
    }
    break :blk t;
};

// One table read for each byte of input, not eight steps.
fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

// The same eight steps for one byte, at runtime, with each step printed.
// The table block above does exactly this work for each of the 256 bytes,
// during compilation.
fn traceEntry(out: *std.Io.Writer, byte: u8) !u32 {
    var c: u32 = byte;
    try out.print("  start   0x{x:0>8}\n", .{c});
    for (1..9) |step| {
        const low = c & 1;
        c = if (low != 0) poly ^ (c >> 1) else c >> 1;
        const what = if (low != 0) "shift, then xor" else "shift";
        try out.print("  step {d}  low bit {d}, {s: <16} 0x{x:0>8}\n", .{ step, low, what, c });
    }
    return c;
}

// A table can be a type check too. The compiler runs this block, and
// a false condition stops the build.
comptime {
    std.debug.assert(table[0] == 0);
    std.debug.assert(table[128] == poly);
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("table: {d} entries, {d} bytes\n", .{ table.len, @sizeOf(@TypeOf(table)) });
    for (table[0..4], 0..) |entry, i| {
        try out.print("  table[{d}] = 0x{x:0>8}\n", .{ i, entry });
    }

    const inputs = [_][]const u8{ "", "a", "hello, world", "The quick brown fox jumps over the lazy dog" };
    for (inputs) |input| {
        const ours = crc32(input);
        const theirs = std.hash.Crc32.hash(input);
        try out.print("\"{s}\"\n  ours 0x{x:0>8}, std 0x{x:0>8}, {s}\n", .{
            input,
            ours,
            theirs,
            if (ours == theirs) "same" else "DIFFERENT",
        });
    }

    // A table that the compiler made is also usable at compile time.
    const at_compile = comptime crc32("hello, world");
    try out.print("comptime crc32(\"hello, world\") = 0x{x:0>8}\n", .{at_compile});

    try out.print("\nthe 8 steps for byte 1\n", .{});
    const traced = try traceEntry(out, 1);
    try out.print("  table[1] = 0x{x:0>8}, same -> {}\n", .{ table[1], traced == table[1] });
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`25-comptime.lookup-tables`)*

## The calculation without a table

CRC-32 processes the input one bit at a time. For each bit, it does one shift and one conditional xor with a constant, the polynomial `0xEDB88320`. A byte has 8 bits, thus each byte of input costs 8 steps.

The result of the 8 steps depends only on one byte. A byte has 256 possible values. Thus there are only 256 possible results, and a table can hold all of them.

## Build the table

```zig
const table: [256]u32 = blk: {
    @setEvalBranchQuota(256 * 8 + 256);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*entry, byte| {
        var c: u32 = @intCast(byte);
        for (0..8) |_| {
            c = if (c & 1 != 0) poly ^ (c >> 1) else c >> 1;
        }
        entry.* = c;
    }
    break :blk t;
};
```

`table` is a `const` at the top level of the file. The compiler always calculates a top-level `const` during compilation. Thus this block does not need the `comptime` keyword.

The output shows the first entries:

```
table: 256 entries, 1024 bytes
  table[0] = 0x00000000
  table[1] = 0x77073096
  table[2] = 0xee0e612c
  table[3] = 0x990951ba
```

The table in the zlib source, `crc32.h`, starts with the same four numbers. The table is 1024 bytes in the binary, because each of the 256 entries is a `u32`.

## Use the table

```zig
fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}
```

Each byte of input now costs one table read, one xor and one shift. The 8 steps for each bit are gone. They ran one time, in the compiler, for each of the 256 possible bytes.

The program also runs the 8 steps for byte 1 at runtime and prints each step. The figure plays that trace. The last register is `table[1]`, the same value that the compiler put in the table.

*Figure: A 32-bit register that starts at 1. Eight shift steps, two with an xor of the polynomial 0xEDB88320, give 0x77073096, entry 1 of a 256-entry table. The steps for byte 1, as the program above prints them. The bits that a step changed are filled. On a step that xors, the 1 bits of the polynomial are filled too.*

## Check the table against `std`

A table with one wrong entry gives a wrong checksum for some inputs and the correct checksum for others. Thus the program compares its result with `std.hash.Crc32.hash` for four inputs:

```
"The quick brown fox jumps over the lazy dog"
  ours 0x414fa339, std 0x414fa339, same
```

`0x414fa339` is also the published CRC-32 of this sentence. The `.expected` file pins the full output. Thus if a change to the table makes one result different, `zig build verify` fails.

The program also has a `comptime` block at the top level:

```zig
comptime {
    std.debug.assert(table[0] == 0);
    std.debug.assert(table[128] == poly);
}
```

During compilation, a failed `assert` is a compile error. These two checks stop the build before the program can run. Entry 128 is the byte `0x80`, and only its top bit is 1. Seven shifts move that bit to the bottom. Then the eighth step does the only xor, and the result is the polynomial.

## The branch quota

The compiler counts each backward branch during comptime evaluation. A backward branch is a jump back to the start of a loop. After 1000 of them, the compiler stops with an error. The limit makes sure that a loop which never ends gives an error, and the compiler does not run forever.

The table needs more than 1000. The inner loop runs 8 times for each of 256 bytes, and that is 2048 branches. The outer loop adds 256 more. Without `@setEvalBranchQuota`, the same block fails:

```zig
const std = @import("std");

const table: [256]u32 = blk: {
    var t: [256]u32 = undefined;
    for (&t, 0..) |*entry, byte| {
        var c: u32 = @intCast(byte);
        for (0..8) |_| {
            c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        }
        entry.* = c;
    }
    break :blk t;
};

pub fn main() void {
    std.debug.print("0x{x}\n", .{table[1]});
}
```

The compiler says:

```
error: evaluation exceeded 1000 backwards branches
note: use @setEvalBranchQuota() to raise the branch limit from 1000
```

*Compiled by CI, but not runnable in the browser sandbox. (`25-comptime.table-no-quota`)*

`@setEvalBranchQuota(256 * 8 + 256)` sets the limit for the current comptime evaluation. Calculate the number from the loops, as this program does. A number that you calculate tells the next reader why the limit has that value. A large round number such as `1_000_000` tells the reader nothing.

## A table is also comptime-known

The last line of the output is:

```
comptime crc32("hello, world") = 0xffab723a
```

`crc32` reads only `table`, and `table` is comptime-known. Thus the compiler can also run `crc32` during compilation, when the input is comptime-known. The binary then contains only the checksum.

## Check yourself

The program runs `crc32` at runtime on a string from a file. Does the binary contain the 8-step loop?

No. The 8-step loop is inside the block that builds `table`. That block runs only during compilation. At runtime, `crc32` contains only the loop over the input bytes and the table read.

The next chapter reads the fields of a type, and uses them to write a function that works for all struct types.
