# Recipe: A SIMD Dot Product

> Use @Vector to process four elements in each operation, with the tail too.

A SIMD dot product in Zig multiplies chunks of `@Vector(4, i32)` with plain `*` and `+=`. Then `@reduce(.Add, acc)` adds the lanes together, and a scalar loop does the elements that remain.

## The problem

You have two arrays of numbers, and you want their dot product. The scalar loop is slow in your profile.

Modern CPUs (and wasm) have SIMD registers that do one operation on several values at the same time. Zig gives you these registers through `@Vector`, in a portable way, with the usual operators. Thus the vector code looks like the scalar code.

Errors usually occur at the two ends:

- the change from slice data to vector operands
- the tail, when the length is not a multiple of the lane count

## The plan

1. Define a vector type. `@Vector(4, i32)` has four `i32` lanes.
2. Loop over the slice in steps of one full vector. `xs[i..][0..Lanes].*` takes four contiguous elements as an array. The array coerces to a vector.
3. Multiply and accumulate with plain `*` and `+=`. These operators work on each lane at the same time.
4. After the loop, add the lanes together with `@reduce(.Add, acc)`. Then do the zero to three elements that remain with a scalar loop.

```zig
const std = @import("std");

const Lanes = 4;
const V = @Vector(Lanes, i32);

fn dotScalar(xs: []const i32, ys: []const i32) i64 {
    var total: i64 = 0;
    for (xs, ys) |x, y| total += @as(i64, x) * y;
    return total;
}

fn dotSimd(xs: []const i32, ys: []const i32) i64 {
    var acc: V = @splat(0);
    var i: usize = 0;
    // Full vectors first. The cast from slice to array, `[0..Lanes].*`,
    // changes Lanes contiguous elements into vector operands.
    while (i + Lanes <= xs.len) : (i += Lanes) {
        const x: V = xs[i..][0..Lanes].*;
        const y: V = ys[i..][0..Lanes].*;
        acc += x * y; // one multiply and one add on all lanes
    }
    // Horizontal step: add the lanes together into one number.
    var total: i64 = @reduce(.Add, acc);
    // The tail. If the length is not a multiple of Lanes, up to Lanes - 1
    // elements remain. Do them with a scalar loop.
    while (i < xs.len) : (i += 1) total += @as(i64, xs[i]) * ys[i];
    return total;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // 10 elements: two full vectors of 4, and a tail of 2.
    var xs: [10]i32 = undefined;
    var ys: [10]i32 = undefined;
    for (&xs, &ys, 0..) |*x, *y, i| {
        x.* = @intCast(i + 1);
        y.* = @intCast((i + 1) * 2);
    }

    const scalar = dotScalar(&xs, &ys);
    const simd = dotSimd(&xs, &ys);

    try out.print("scalar: {d}\n", .{scalar});
    try out.print("simd:   {d}\n", .{simd});
    try out.print("equal:  {}\n", .{scalar == simd});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.simd-sum`)*

## The cast from slice to vector

`xs[i..][0..Lanes]` is a common pattern. The first slice moves the start. The second slice has a length that is known at comptime. Thus its type is a pointer to an array, `*const [4]i32`.

The dereference with `.*` gives the array by value. An array coerces to a vector of the same length and element type.

This needs no `@memcpy` and no unsafe cast. In safe builds, Zig checks the bounds.

## The tail is necessary

With ten elements and four lanes, two elements remain. If you omit the tail loop, the code works on each test with a length that is a multiple of four. On all other lengths, the code silently loses data.

The standard shape keeps a scalar epilogue. The snippet compares its result with the scalar version, and shows that both versions give the same result.

## Performance

The accumulator has `i32` lanes, and the totals use `i64`. Thus the change to the wider type occurs one time for each reduce and one time for each tail element.

On wasm, this code compiles to the 128-bit SIMD instruction set. On native targets, the same source uses the instructions that the CPU has.

Measure before you assume that the code is faster. For small arrays, the setup and the reduce can cost more than the loop saves.

## Variations

- **Other reductions:** `@reduce` also takes `.Min`, `.Max`, `.And`, `.Or`, `.Xor` and `.Mul`.
- **Lane count:** `std.simd.suggestVectorLength(i32)` asks the target for a good width. Then you do not have to write 4 in the code.
- **Floats:** the same code works with `f32` lanes. Float addition is not associative. Thus the vector sum and the scalar sum can have different last bits.
- **Search, not sum:** [the byte scan recipe](https://www.ziglang.in/learn/how-to/simd-scan/) uses the same loop shape to find and count bytes. It uses comparisons and bit masks in place of arithmetic.
