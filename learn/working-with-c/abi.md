# ABI

> extern and packed, for layouts with a guarantee.

To pass a struct from Zig to C, declare it as `extern struct`. An
`extern struct` uses the field order and padding of the C ABI. A
`packed struct` gives exact bits with no padding, for registers and wire
formats.

```zig
const std = @import("std");
const expect = std.testing.expect;

// `extern struct` guarantees the C layout: the order of the declaration, and
// the C rules for padding.
const CPoint = extern struct {
    x: i32,
    y: i32,
};

// `packed struct` has exact bits and no padding. An integer holds the bits.
const Flags = packed struct {
    a: bool,
    b: bool,
    rest: u6,
};

// The compiler can change the order of the fields of a plain struct, and add
// padding in any way that it selects.
const Loose = struct {
    small: u8,
    big: u64,
};

test "extern struct follows C layout" {
    try expect(@sizeOf(CPoint) == 8);
    try expect(@offsetOf(CPoint, "x") == 0);
    try expect(@offsetOf(CPoint, "y") == 4);
}

test "packed struct is exactly its bits" {
    try expect(@bitSizeOf(Flags) == 8);
    try expect(@sizeOf(Flags) == 1);

    const f = Flags{ .a = true, .b = false, .rest = 0 };
    // Packed structs convert to their backing integer.
    try expect(@as(u8, @bitCast(f)) == 1);
}

test "plain structs make no layout promise" {
    // Zig can put these fields in any order for packing. Do not assume offsets.
    try expect(@sizeOf(Loose) >= 9);
}

test "extern union and enum" {
    const E = extern union { i: i32, f: f32 };
    try expect(@sizeOf(E) == 4);

    // An enum with a C ABI tag type.
    const Colour = enum(c_int) { red, green, blue };
    try expect(@intFromEnum(Colour.green) == 1);
}

// `callconv(.c)` lets C call a Zig function.
export fn addFromC(a: c_int, b: c_int) callconv(.c) c_int {
    return a + b;
}

test "exported function is callable from Zig too" {
    try expect(addFromC(2, 3) == 5);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`05-working-with-c.abi`)*

A plain Zig `struct` makes **no layout promise**. The compiler can put the
fields in a different order and add padding in any way that it prefers. This
freedom is a feature, because it lets the optimiser pack the fields. But you
cannot give a plain `struct` to C.

## The three layouts

| Declaration | Layout | Use for |
| --- | --- | --- |
| `struct` | unspecified | ordinary Zig code |
| `extern struct` | C ABI: declaration order, C padding | C interop |
| `packed struct` | exact bits, no padding, integer-backed | wire formats, registers |

```zig
const CPoint = extern struct { x: i32, y: i32 };   // offsets 0 and 4
const Flags = packed struct { a: bool, b: bool, rest: u6 };  // exactly 8 bits
```

A `packed struct` converts to and from its backing integer with `@bitCast`.
Thus a `packed struct` is the natural way to describe hardware registers and
protocol headers.

## What "ABI" means

The application binary interface is a set of agreements. Two pieces of code
that are compiled separately need these agreements to call each other:

- The position of the fields of a struct.
- The registers that hold each argument.
- The side that cleans the stack.
- The form of a name in the symbol table.

The source language does not specify these items. The platform decides them.
The two sides must agree before they meet, because at that time no type
information remains to check.

Because nothing remains to check, a mistake here makes no noise. An incorrect
field offset is not a compile error in either language. The result is a
program that reads the wrong four bytes and continues.

## Verify the layout

`@sizeOf`, `@offsetOf` and `@bitSizeOf` are comptime values. Thus you can
assert a layout assumption at compile time:

```zig
comptime {
    std.debug.assert(@offsetOf(CPoint, "y") == 4);
}
```

Add these assertions at each real C boundary. An assertion changes a silent
mismatch into a build failure.

A stronger version of the same idea is to not write the declaration by hand.
translate-c reads the header and makes the struct. Thus the struct and the
header cannot become different. See [import C](https://www.ziglang.in/learn/working-with-c/cimport/).
Write an `extern` declaration by hand only when no header exists. Those cases
are exactly the cases that need the assertions.

## Bit order is not portable

`packed struct` gives you exact bit positions. A hardware register or a
protocol header needs exact bit positions. But a `packed struct` does not
always agree with the bitfields of a C compiler. In C, the order of bits in a
unit is implementation-defined. Thus two compilers can put the bits of the
same header in different positions.

For a wire format, this is not a problem. It is even an advantage, because
you define the layout. You do not copy the layout of a different program. If
you must match a C bitfield exactly, do not assume. Compare the layout with
the C compiler that you use.

Byte order is a different question, and `packed struct` says nothing about
it. A protocol header that you read from a socket needs `std.mem.bigToNative`
or an explicit decode, one byte at a time. `@bitCast` gives you the byte order
of the host.

## Calling conventions

`callconv(.c)` gives a function the C calling convention. `export` gives the
function an unmangled symbol name:

```zig
export fn add(a: c_int, b: c_int) callconv(.c) c_int {
    return a + b;
}
```

C needs nothing more to call Zig. To call C from Zig, declare the C function
with `extern`:

```zig
extern "c" fn abs(n: c_int) c_int;
```

`export` does the two jobs. It gives the function an unmangled symbol name
and the C calling convention. Thus the `callconv(.c)` above only states what
`export` already gives. The extra `callconv(.c)` costs nothing, and it shows
what you intend.

With `@export(&add, .{ .name = "add" })`, you must supply the convention
yourself. `@export` exports a function, and the function keeps the convention
that it declares.

Zig errors also do not cross the boundary. If an `export` function returns
`!void`, C has no representation for the return type. Thus a function for C
callers returns a status code, and keeps its error handling inside.

## Do not `extern` everything

An `extern struct` stops the packing that the optimiser can do for a plain
struct. Use `extern struct` at the boundary, and use ordinary structs inside.

An `extern struct` also makes your layout fixed, as part of the interface. You
can add a field to a plain struct, and the only result is a recompile. An
`extern struct` that C code allocates is a promise about size. If you change
the size, all code that was compiled against the old size breaks.
