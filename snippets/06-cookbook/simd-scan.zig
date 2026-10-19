//! title: SIMD Byte Scan
//! Splat, load, compare, extract, tail: the full pattern in one scan.
//! simd

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
