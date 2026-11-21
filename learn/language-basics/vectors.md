# Vectors

> SIMD with ordinary operators.

Zig gives you SIMD as a type, `@Vector(N, T)`, not as a library of intrinsics. `std.simd.suggestVectorLength` selects `N` for the target.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "element-wise arithmetic" {
    const a: @Vector(4, i32) = .{ 1, 2, 3, 4 };
    const b: @Vector(4, i32) = .{ 10, 20, 30, 40 };
    const sum = a + b; // one operation across all lanes
    try expect(sum[0] == 11);
    try expect(sum[3] == 44);
}

test "reduce across lanes" {
    const v: @Vector(4, i32) = .{ 1, 2, 3, 4 };
    try expect(@reduce(.Add, v) == 10);
    try expect(@reduce(.Max, v) == 4);
}

test "splat fills every lane" {
    const v: @Vector(4, i32) = @splat(7);
    try expect(@reduce(.Add, v) == 28);
}

test "comparisons produce a vector of bools" {
    const a: @Vector(4, i32) = .{ 1, 5, 3, 7 };
    const b: @Vector(4, i32) = .{ 4, 4, 4, 4 };
    const mask = a > b; // @Vector(4, bool)
    try expect(@reduce(.Or, mask));
    try expect(!@reduce(.And, mask));

    // Select lane-wise between two vectors.
    const picked = @select(i32, mask, a, b);
    try expect(picked[0] == 4 and picked[1] == 5);
}

test "vectors and arrays convert" {
    const arr = [_]i32{ 1, 2, 3, 4 };
    const v: @Vector(4, i32) = arr;
    const back: [4]i32 = v;
    try expect(back[2] == 3);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.vectors`)*

`@Vector(N, T)` is a SIMD vector of `N` lanes. Arithmetic operators work element by element across all lanes at the same time. Where the target has vector instructions, the operators compile to real vector instructions:

```zig
const sum = a + b;   // one operation, four lanes
```

SIMD means "single instruction, multiple data". One machine instruction does the same arithmetic on many values at the same time. A 128-bit register holds four `i32` values, and one add instruction adds all four.

In Zig, you write that add with a usual operator on a vector type. You do not use an intrinsic with a name such as `_mm_add_epi32`.

## The builtins for vectors

| Builtin | Does |
| --- | --- |
| `@splat(x)` | fill every lane with `x` |
| `@reduce(.Add, v)` | collapse lanes to one value |
| `@select(T, mask, a, b)` | pick lane-wise between two vectors |
| `@shuffle` | rearrange lanes |

A comparison produces a `@Vector(N, bool)` mask, not one `bool`. Thus you use `@reduce(.Or, mask)` or `@select` to act on the result.

The mask replaces branches. If you wrote only scalar code before, this needs practice:

- A scalar loop says "if this element matches, do the action".
- A vector version computes the condition for all lanes at the same time. Then it uses the mask to select between two answers that it already computed.

There is no branch for each lane. For this reason, the vector version is fast. For the same reason, work that is different for each element does not vectorise.

## Select N

`std.simd.suggestVectorLength(T)` asks the target how many lanes of `T` fit in its widest register. It returns null when the target has no SIMD. Portable code uses this function, and does not hardcode 4 or 8. When the function returns null, the code uses a scalar loop.

This null is important on this site. SIMD in WebAssembly is an optional feature. Thus the site compiles the four chapters that teach vectors with SIMD explicitly on, and it compiles all other snippets without SIMD.

Without SIMD, the function returns null, and the compiler removes the vector path with no message. Then the page says that it shows SIMD, but the page ships a scalar loop.

## Convert between vectors and arrays

```zig
const v: @Vector(4, i32) = arr;   // array -> vector
const back: [4]i32 = v;           // vector -> array
```

The data is the same, and the type is different. Keep values in vector form during a computation, and convert at the edges.

The conversion does no arithmetic, but it can still take time. The values can move between usual registers and vector registers. Inside a loop, those moves can cost more time than the vector arithmetic saves. Load one time, compute, and store one time.

Vectors are not arrays:

- A vector has no `.len`. If you use `.len`, you get a compile error.
- An index works, with a runtime index or a comptime index. In a safety build, the index has a bounds check.
- You cannot slice a vector, or give it to a function by its length.

Use an array when you need these operations. Use a vector when you want arithmetic lane by lane.

## When to use vectors

Zig often auto-vectorises a plain loop. Use explicit vectors when you need the guarantee, or when the operation is not a simple loop. If the target has no SIMD, the code still works, because the compiler changes it to scalar operations.

First write the scalar loop and measure it. Only after that, change to vectors. If the loop was not the bottleneck, a vector version is more difficult to read and change, and it is not faster.

When vectors help, the gain is often large. For that reason, the two recipes below each process a large buffer in one pass.

Two how-to recipes use these builtins: [a SIMD dot product](https://www.ziglang.in/learn/how-to/simd-sum/) for arithmetic, and [a SIMD byte scan](https://www.ziglang.in/learn/how-to/simd-scan/) for search.
