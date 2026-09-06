# Recipe: SIMD Byte Scanning

> The five-step pattern that turns a byte-at-a-time loop into a register-wide scan.

## The problem

A parser reading a JSON string spends its life in a loop like this:

```zig
while (i < bytes.len and bytes[i] != '"' and bytes[i] != '\\') i += 1;
```

One byte per iteration. The machine underneath holds 16 bytes in a single
128-bit vector register and can compare all of them in one instruction. [The
dot product recipe](https://www.ziglang.in/learn/how-to/simd-sum/) used vectors for arithmetic; this
one uses them for searching, which is where parsers, scanners, and codecs get
their real SIMD wins. The shape of this recipe follows Mitchell Hashimoto's
["Everyone should know
SIMD"](https://mitchellh.com/writing/everyone-should-know-simd), which walks
the same pattern through a terminal emulator's scanner.

## The pattern

Vectorized scans are all the same five steps. Learn them once and most SIMD
code becomes readable, whatever the language.

1. **Splat.** Broadcast each constant you compare against into every lane
   of a vector, once, before the loop.
2. **Load.** Step through the slice a whole vector at a time:
   `bytes[i..][0..lanes].*` turns 16 contiguous bytes into an operand.
3. **Compare.** `chunk == quote` compares all lanes in one operation and
   yields a `@Vector(lanes, bool)`.
4. **Extract.** Turn that bool vector into a plain integer and use integer
   instructions to ask questions about the lanes.
5. **Tail.** Finish the last few bytes with the scalar loop you started
   with.

```zig
const std = @import("std");

// The scalar baseline: the loop every parser has somewhere. Inside a JSON
// string, the next byte that matters is the closing quote or the start of
// an escape sequence.
fn findSpecialScalar(bytes: []const u8, start: usize) ?usize {
    var i = start;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '"' or bytes[i] == '\\') return i;
    }
    return null;
}

// The same scan, one register at a time.
fn findSpecialSimd(bytes: []const u8, start: usize) ?usize {
    // Ask the target how many u8 lanes fit its vector registers. Null means
    // no SIMD at all; return the scalar version and everything below
    // compiles away.
    const lanes = std.simd.suggestVectorLength(u8) orelse
        return findSpecialScalar(bytes, start);
    const V = @Vector(lanes, u8);
    const Mask = @Int(.unsigned, lanes); // one bit per lane

    // Step 1: broadcast each byte we look for into every lane, once.
    const quote: V = @splat('"');
    const backslash: V = @splat('\\');

    // Step 2: walk the slice a whole vector at a time.
    var i = start;
    while (i + lanes <= bytes.len) : (i += lanes) {
        const chunk: V = bytes[i..][0..lanes].*;

        // Step 3: compare every lane at once. Each == yields a
        // @Vector(lanes, bool); bitcasting packs that into an integer with
        // lane 0 in the lowest bit, and integer | merges the two predicates.
        const hits: Mask = @as(Mask, @bitCast(chunk == quote)) |
            @as(Mask, @bitCast(chunk == backslash));

        // Step 4: zero means no lane matched. Otherwise the number of
        // trailing zeros is the index of the first matching lane.
        if (hits != 0) return i + @ctz(hits);
    }

    // Step 5: fewer than `lanes` bytes remain; finish the boring way.
    return findSpecialScalar(bytes, i);
}

// Same pattern, different step 4: instead of stopping at the first match,
// count set bits per chunk and keep going.
fn countScalar(bytes: []const u8, needle: u8) usize {
    var total: usize = 0;
    for (bytes) |b| total += @intFromBool(b == needle);
    return total;
}

fn countSimd(bytes: []const u8, needle: u8) usize {
    const lanes = std.simd.suggestVectorLength(u8) orelse
        return countScalar(bytes, needle);
    const V = @Vector(lanes, u8);
    const Mask = @Int(.unsigned, lanes);
    const target: V = @splat(needle);

    var total: usize = 0;
    var i: usize = 0;
    while (i + lanes <= bytes.len) : (i += lanes) {
        const chunk: V = bytes[i..][0..lanes].*;
        total += @popCount(@as(Mask, @bitCast(chunk == target)));
    }
    while (i < bytes.len) : (i += 1) total += @intFromBool(bytes[i] == needle);
    return total;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const doc =
        \\{"path": "/var/log/app/2026-07-23.log", "msg": "rotated \"cleanly\", no errors", "level": "info"}
    ;

    if (std.simd.suggestVectorLength(u8)) |lanes|
        try out.print("lanes:  {d}\n", .{lanes})
    else
        try out.print("lanes:  none, scalar fallback\n", .{});

    // Scan the "msg" string: where does its content stop being plain bytes?
    const value_start = std.mem.find(u8, doc, "\"msg\": \"").? + "\"msg\": \"".len;
    const scalar_hit = findSpecialScalar(doc, value_start);
    const simd_hit = findSpecialSimd(doc, value_start);
    try out.print("scalar: {?d}\n", .{scalar_hit});
    try out.print("simd:   {?d}\n", .{simd_hit});
    try out.print("byte:   {c}\n", .{doc[simd_hit.?]});

    const scalar_quotes = countScalar(doc, '"');
    const simd_quotes = countSimd(doc, '"');
    try out.print("quotes: {d} scalar, {d} simd\n", .{ scalar_quotes, simd_quotes });
    try out.print("agree:  {}\n", .{scalar_hit == simd_hit and scalar_quotes == simd_quotes});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.simd-scan`)*

## The mask is an integer

Step 4 is the part the other steps exist for. `@bitCast` packs a `@Vector(16,
bool)` into a `u16`, lane 0 in the lowest bit. After that, questions about
lanes become one-instruction questions about an integer:

| Question | Answer |
| --- | --- |
| did any lane match? | `hits != 0` |
| where is the first match? | `@ctz(hits)` |
| how many matched? | `@popCount(hits)` |

x86 calls this a movemask. The snippet uses `@ctz` to find the first special
byte and `@popCount` to count quotes; both scans share steps 1 through 3 and
differ only here. The mask type is `@Int(.unsigned, lanes)`, the builtin that
replaced `std.meta.Int` on current master.

## Two needles, one pass

The scan looks for `"` or `\`. Each needle is its own splat and its own
compare, and integer `|` merges the two masks. A third needle costs one more
compare, not another pass over the data. Scalar code pays a branch per needle
per byte; the vector loop pays nothing extra per byte and branches once per
16.

## No SIMD, no problem

`suggestVectorLength` asks the target how many lanes its registers hold: 16
for this site's wasm, 32 on x86-64 with AVX2, 64 with AVX-512, and null when
the target has no usable vectors. The result is comptime-known, so `orelse
return findSpecialScalar(...)` does not emit a fallback branch; on a
vectorless target the whole SIMD body is never compiled. That guard is why the
playground prints the lane count. This snippet is built with wasm's SIMD
feature enabled, so the Run button executes real 16-lane vector instructions
in your browser.

Only the four chapters that teach vectors are built that way. The rest of the
site is baseline wasm, because SIMD is a target feature rather than a
per-function one. Turn it on and the compiler auto-vectorizes the standard
library's memcpy and formatting paths too. Hello-world then shipped 159 vector
opcodes it never asked for, and would not load at all on an engine without
SIMD.

## Why not let the compiler do it

Compilers auto-vectorize the counting loop routinely. The find-first loop is
harder. The early exit makes the trip count depend on the data, and whether
the optimizer manages it can change with an unrelated edit or a compiler
upgrade. Writing the vectors out is a guarantee, not a hint, and `@Vector`
keeps that guarantee portable across targets. The cost is the dozen lines you
just read.

## Variations

- **`std.simd` helpers:** `std.simd.firstTrue(chunk == quote)` wraps the
  bitcast and `@ctz`; `countTrues` and `lastTrue` cover the other
  questions.
- **One needle:** `std.mem.findScalar` (the current name for
  `indexOfScalar`) already scans with vectors internally. Reach for it
  before writing your own.
- **Any without where:** `@reduce(.Or, mask)` answers "did any lane match"
  directly from the bool vector when you never need the index.
- **Classify, then decide:** real JSON scanners build masks for quotes,
  backslashes, and structural characters per 64-byte block and combine
  them with integer arithmetic. That is this recipe's step 4, scaled up.
