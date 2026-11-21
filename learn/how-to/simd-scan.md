# Recipe: Scan Bytes with SIMD

> The five-step pattern that changes a loop of one byte at a time into a scan as wide as a register.

A SIMD byte scan in Zig loads the bytes for a full vector at one time and compares each lane in one operation. Then `@bitCast` changes the bool vector from the comparison to an integer, and `@ctz` finds the first match. The pattern has five steps: splat, load, compare, extract, tail.

## The problem

A parser that reads a JSON string uses most of its time in a loop such as this one:

```zig
while (i < bytes.len and bytes[i] != '"' and bytes[i] != '\\') i += 1;
```

The loop examines one byte in each iteration. But the machine can keep 16 bytes in one 128-bit vector register, and it can compare all 16 bytes in one instruction.

[The dot product recipe](https://www.ziglang.in/learn/how-to/simd-sum/) used vectors for arithmetic. This recipe uses vectors for a search. Parsers, scanners and codecs get large increases in speed from SIMD in their searches.

The shape of this recipe follows the article ["Everyone should know SIMD"](https://mitchellh.com/writing/everyone-should-know-simd) by Mitchell Hashimoto. The article shows the same pattern in the scanner of a terminal emulator.

## The pattern

All vector scans use the same five steps. Learn them one time, and you can read most SIMD code, in all languages.

1. **Splat.** Before the loop, copy each constant that you compare against into each lane of a vector. Do this one time.
2. **Load.** Move through the slice one full vector at a time. `bytes[i..][0..lanes].*` changes 16 contiguous bytes into an operand.
3. **Compare.** `chunk == quote` compares all lanes in one operation, and gives a `@Vector(lanes, bool)`.
4. **Extract.** Change that bool vector into a plain integer. Then use integer instructions to get information about the lanes.
5. **Tail.** Do the last few bytes with the scalar loop from the start.

```zig
const std = @import("std");

// The scalar baseline: a loop that most parsers have. Inside a JSON string,
// the next important byte is the quote at the end or the start of an escape
// sequence.
fn findSpecialScalar(bytes: []const u8, start: usize) ?usize {
    var i = start;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '"' or bytes[i] == '\\') return i;
    }
    return null;
}

// The same scan, one register at a time.
fn findSpecialSimd(bytes: []const u8, start: usize) ?usize {
    // Ask the target how many u8 lanes its vector registers hold. Null means
    // that the target has no SIMD. Then return the scalar version. The
    // compiler does not compile the code below.
    const lanes = std.simd.suggestVectorLength(u8) orelse
        return findSpecialScalar(bytes, start);
    const V = @Vector(lanes, u8);
    const Mask = @Int(.unsigned, lanes); // one bit per lane

    // Step 1: copy each byte to find into each lane, one time.
    const quote: V = @splat('"');
    const backslash: V = @splat('\\');

    // Step 2: move through the slice one full vector at a time.
    var i = start;
    while (i + lanes <= bytes.len) : (i += lanes) {
        const chunk: V = bytes[i..][0..lanes].*;

        // Step 3: compare all lanes at one time. Each == gives a
        // @Vector(lanes, bool). The bitcast packs that vector into an integer
        // with lane 0 in the lowest bit. An integer | merges the two results.
        const hits: Mask = @as(Mask, @bitCast(chunk == quote)) |
            @as(Mask, @bitCast(chunk == backslash));

        // Step 4: zero means that no lane matched. If the value is not zero,
        // the number of trailing zeros is the index of the first lane that matched.
        if (hits != 0) return i + @ctz(hits);
    }

    // Step 5: fewer than `lanes` bytes remain. Do them with the scalar loop.
    return findSpecialScalar(bytes, i);
}

// The same pattern with a different step 4. Do not stop at the first match.
// Count the set bits in each chunk, and continue.
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

    // Scan the "msg" string. Find the first byte that is not a plain byte.
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

Step 4 changes the comparison into an answer. `@bitCast` packs a `@Vector(16, bool)` into a `u16`, with lane 0 in the lowest bit. After that, each question about the lanes is a question about an integer, and one instruction answers it:

| Question | Answer |
| --- | --- |
| did a lane match? | `hits != 0` |
| where is the first match? | `@ctz(hits)` |
| how many matched? | `@popCount(hits)` |

On x86, the name of this operation is movemask. The snippet uses `@ctz` to find the first special byte, and `@popCount` to count the quotes. Both scans use the same steps 1 to 3. They are different only at step 4.

The mask type is `@Int(.unsigned, lanes)`. On current master, this builtin replaces `std.meta.Int`.

## Two needles in one pass

The scan looks for `"` or `\`. Each needle has its own splat and its own compare. An integer `|` merges the two masks.

A third needle costs one more compare, not one more pass over the data. Scalar code pays one branch for each needle, for each byte. The vector loop pays nothing more for each byte, and it has one branch for each 16 bytes.

## Targets without SIMD

`suggestVectorLength` asks the target how many lanes its registers hold. The answer is 16 for the wasm of this site, 32 on x86-64 with AVX2 and 64 with AVX-512. When the target has no vectors that the code can use, the answer is null.

The result is known at comptime. Thus `orelse return findSpecialScalar(...)` does not emit a fallback branch. On a target without vectors, the compiler does not compile the SIMD code at all. Because of that guard, the playground prints the lane count.

The build of this snippet enables the SIMD feature of wasm. Thus the Run button executes real 16-lane vector instructions in your browser.

Only the four chapters that teach vectors have that build. The other snippets of the site use baseline wasm, because SIMD is a feature of the target, not of one function.

When the feature is on, the compiler also auto-vectorizes the memcpy and formatting paths of the standard library. Then hello-world shipped 159 vector opcodes that it did not ask for. That program did not load at all on an engine without SIMD.

## Why not let the compiler do it

Compilers usually auto-vectorize the count loop. The loop that finds the first match is more difficult. The early exit makes the number of iterations depend on the data. The optimizer can succeed or fail, and the result can change after an unrelated edit or a compiler upgrade.

When you write the vectors in the code, you guarantee vector instructions. `@Vector` keeps that guarantee portable across targets. The cost is about twelve more lines of code.

## Variations

- **`std.simd` helpers:** `std.simd.firstTrue(chunk == quote)` contains the bitcast and the `@ctz`. `countTrues` and `lastTrue` answer the other questions.
- **One needle:** `std.mem.findScalar` (the current name for `indexOfScalar`) already uses vectors internally for the scan. Use it before you write your own scan.
- **A match, but not its position:** `@reduce(.Or, mask)` tells you directly from the bool vector if a lane matched. Use it when you do not need the index.
- **Classify, then decide:** real JSON scanners build masks for quotes, backslashes and structural characters for each 64-byte block. Then they combine the masks with integer arithmetic. This is step 4 of this recipe, on 64 bytes at a time.
