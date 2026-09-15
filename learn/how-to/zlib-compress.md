# Recipe: Compressing with zlib

> One-shot compress and decompress through the system zlib, linked from Zig.

## The problem

You need to shrink a buffer before writing or sending it, and zlib is the
library already on every machine. It is C, so the job is calling three
functions and linking `libz`. This recipe compresses a buffer and decompresses
it back, checking the round trip.

## The plan

1. Ask `compressBound` for the largest the output could be, and size the
   destination buffer to it.
2. `compress2(dest, &destLen, src, srcLen, level)` fills the buffer and updates
   `destLen` to the real size. `Z_OK` means success.
3. `uncompress` reverses it into a buffer the size of the original.
4. Compare the result to the input.

```zig
const std = @import("std");
const c = @import("c");

fn check(rc: c_int) !void {
    if (rc != c.Z_OK) return error.Zlib;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Repetitive data so the win is obvious. (`**` string repeat was removed
    // from the language, so build it in a loop.)
    var input: std.ArrayList(u8) = .empty;
    for (0..32) |_| try input.appendSlice(gpa, "the zig programming language. ");
    const src = input.items;

    // compressBound is the largest the output can be; size the buffer to it.
    var comp_len: c.uLongf = c.compressBound(@intCast(src.len));
    const comp = try gpa.alloc(u8, @intCast(comp_len));
    try check(c.compress2(comp.ptr, &comp_len, src.ptr, @intCast(src.len), 6));

    // Decompress into a buffer the size of the original.
    var back_len: c.uLongf = @intCast(src.len);
    const back = try gpa.alloc(u8, src.len);
    try check(c.uncompress(back.ptr, &back_len, comp.ptr, comp_len));

    // Compressed size is left off stdout on purpose: it varies by zlib version,
    // and every line here has to be reproducible. The relations do not vary.
    try out.print("original:           {d} bytes\n", .{src.len});
    try out.print("compressed smaller: {}\n", .{comp_len < src.len});
    try out.print("roundtrip matches:  {}\n", .{std.mem.eql(u8, src, back[0..@intCast(back_len)])});

    try out.flush();
}
```

*Links the system libz, so CI builds and runs it natively. Browser wasm cannot link a C library. (`06-cookbook.zlib-compress`)*

## Naming the header and the library separately

zlib is the case that shows why a header and a library are not the same name.
The library is `z` (you link it with `-lz`), but the header is `zlib.h`. This
guide's `build.zig` reads two markers from the snippet: `//! link: z` for the
library and `//! cinclude: zlib.h` for the header. It synthesizes a header that
includes `zlib.h`, translates it with a translate-c step, links `z`, and hands
the snippet the module as `c`. For SQLite the two names happen to match, so it
needs only `//! link: sqlite3`; zlib needs both.

## Sizing the output buffer

Compression can, on incompressible input, produce slightly more bytes than it
consumed, so you cannot assume the output fits in the input's size.
`compressBound(srcLen)` returns the worst case, which is what the destination
buffer is sized to. After `compress2` returns, `destLen` holds the actual
compressed length, almost always far smaller. The same in-out length pattern
appears in `uncompress`: you pass the buffer capacity in, and get the real
length back.

## Why the size is not on the page

The output reports that the compressed form is smaller and that the round trip
matches, but not the exact compressed byte count. That number depends on the
zlib version doing the compressing, and every line this guide prints has to be
reproducible across the machines that run it. The relationships (smaller than
the original, decompresses to the original) hold on every version, so those are
what the snippet asserts. Print `comp_len` yourself to see the real ratio.

## Variations

- **Levels:** the last argument to `compress2` is 0 to 9, trading speed for
  size. Level 6 is the usual default.
- **Streaming:** for data too large to hold at once, zlib's `deflate`/`inflate`
  work on chunks through a `z_stream`, at the cost of more bookkeeping.
- **Gzip framing:** `compress2` writes a zlib stream; for a `.gz` file with its
  header and CRC, use `deflateInit2` with the gzip window bits.
- **Pure Zig:** `std.compress.flate` does deflate and gzip in the standard
  library, no C linking, when you would rather not depend on the system zlib.
