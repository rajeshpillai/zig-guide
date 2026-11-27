# Sentinel Termination

> Sequences that end in a known marker.

In Zig, a string literal has the type `*const [N:0]u8`. `[:0]u8` is the slice form of a zero-terminated sequence, and `[*:0]u8` is the pointer form. You can give these types to C without a copy.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "sentinel-terminated array" {
    // `[3:0]u8` is three bytes plus a guaranteed 0 at index 3.
    const array: [3:0]u8 = .{ 1, 2, 3 };
    try expect(array.len == 3); // `.len` does not count the sentinel
    try expect(array[3] == 0); // but it is there
}

test "string literals are sentinel terminated" {
    const literal = "hi";
    try expect(@TypeOf(literal) == *const [2:0]u8);
    try expect(literal.len == 2);
    try expect(literal[2] == 0); // compatible with C at no extra cost
}

test "span recovers the length from a sentinel" {
    const c_string: [*:0]const u8 = "hello";
    // `[*:0]T` has no length, but the sentinel makes it recoverable.
    const slice = std.mem.span(c_string);
    try expect(slice.len == 5);
    try expect(std.mem.eql(u8, slice, "hello"));
}

test "sentinel slices coerce to ordinary ones" {
    const sentinel_slice: [:0]const u8 = "abc";
    const plain: []const u8 = sentinel_slice;
    try expect(plain.len == 3);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.sentinel-termination`)*

A sentinel-terminated type guarantees a specific value immediately after the end. In the syntax, the value comes after a colon:

| Type | Meaning |
| --- | --- |
| `[3:0]u8` | 3 bytes, plus a guaranteed `0` at index 3 |
| `[:0]u8` | slice with a `0` after the last element |
| `[*:0]u8` | many-item pointer, terminated by `0` |

`.len` does **not** count the sentinel. But the sentinel is really in memory, and you can read it.

A `[:0]u8` has a length, as each slice has. Thus iteration over it has bounds checks, and `.len` is one instruction. The type *also* promises a zero after the last element. Thus you can give it to C without a copy. One value holds the length and the terminator.

## The sentinel can be a value other than zero

`0` is the usual case, because C strings are the usual case. But the value is part of the type: `[:255]u8` and `[: '\n']u8` are legal. You can use this form for any data that has a known terminator. Sometimes a protocol buffer or a line reader can use the type to state its rule, and a comment is not necessary.

## String literals have a sentinel

```zig
const literal = "hi";   // *const [2:0]u8
literal.len;            // 2
literal[2];             // 0
```

Thus, when you give a Zig string literal to a C function that wants `const char *`, you need no conversion and no copy. Usual Zig code still has the length. Thus the C compatibility has no cost for Zig code.

The type is a *pointer to an array*, not a slice. For this reason, a literal has a comptime-known length, and `@TypeOf("hi") != @TypeOf("hip")`.

A literal coerces to `[]const u8` or `[:0]const u8` when code uses it in a place that expects one of these types. This occurs almost always. Thus you see the difference only in error messages and in `@TypeOf`.

## Find the length

`[*:0]T` has no length, but the sentinel lets you find the length:

```zig
const slice = std.mem.span(c_string);   // scans to the sentinel
```

The scan is O(n), the same cost that C has for `strlen`. Do the scan one time at the boundary, and then use slices.

Two related functions are also useful:

- `std.mem.sliceTo(slice, 0)` cuts a value that already has a length at the first sentinel. Use it for a C struct field of fixed size that holds a name with padding.
- `std.mem.len` gives only the count, and does not make a slice.

## Make a sentinel-terminated value

Sometimes a C function wants a null-terminated string, and your string is a plain `[]const u8`. Then the terminator must be in memory. There are three methods:

- **A literal**, if the string does not change. A literal already has the terminator.
- **`allocator.dupeSentinel(u8, s, 0)`**. It copies the string, adds the terminator and returns a `[:0]u8`. Remember to free it. Older code used `dupeZ`. `dupeSentinel` replaced `dupeZ`, and the sentinel value is now an argument. It is not part of the name.
- **A stack buffer with an explicit sentinel slice**, `buf[0..n :0]`. This slice asserts that the byte at `buf[n]` is really zero. In a safety build, the program checks that assertion.

Be careful when you slice with a sentinel. `buf[0..n :0]` does not write the terminator. It states that the terminator is already there. You must write the terminator yourself.

## How this is different from C strings

In C, a scan is the only way to find the length. Thus each operation is O(n), and each buffer overrun starts with a terminator that is not there.

In Zig, the value carries the length, and the sentinel is an additional guarantee. Usual code uses the length. Only the C boundary uses the sentinel.

In C, the program reads a string without a terminator until the read finds a zero or fails. In Zig, this can occur only if you made the sentinel type incorrectly by hand.
