# Sentinel Termination

> Sequences that end in a known marker.

In Zig, a string literal has type `*const [N:0]u8`, and `[:0]u8` and
`[*:0]u8` are the slice and pointer forms of a zero-terminated sequence, which
can be passed to C without a copy.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "sentinel-terminated array" {
    // `[3:0]u8` is three bytes plus a guaranteed 0 at index 3.
    const array: [3:0]u8 = .{ 1, 2, 3 };
    try expect(array.len == 3); // the sentinel is not counted
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

A sentinel-terminated type guarantees a specific value sits just past the end.
The syntax puts it after a colon:

| Type | Meaning |
| --- | --- |
| `[3:0]u8` | 3 bytes, plus a guaranteed `0` at index 3 |
| `[:0]u8` | slice with a `0` after the last element |
| `[*:0]u8` | many-item pointer, terminated by `0` |

The sentinel is **not** counted in `.len`, but it is really there and you may
read it.

A `[:0]u8` carries a length like any slice, so iterating it is bounds-checked
and `.len` is one instruction. It *also* promises a zero after the last
element, so it can be handed to C without a copy. One value carries both the
length and the terminator.

## The sentinel need not be zero

`0` is the common case because C strings are the common case, but the value is
part of the type: `[:255]u8` and `[: '\n']u8` are legal. Anything with a
recognisable terminator can be described this way. It occasionally lets a
protocol buffer or a line reader state its rule in the type rather than in a
comment.

## String literals get this for free

```zig
const literal = "hi";   // *const [2:0]u8
literal.len;            // 2
literal[2];             // 0
```

So passing a Zig string literal to a C function that wants `const char *`
needs no conversion and no copy. Ordinary Zig code still has the length, so
the C compatibility costs it nothing.

Note the type is a *pointer to an array*, not a slice. That is why a literal
has a comptime-known length, and why `@TypeOf("hi") != @TypeOf("hip")`. It
coerces to `[]const u8` or `[:0]const u8` the moment it is used somewhere
expecting one, which is nearly always, so the difference only shows up in
error messages and in `@TypeOf`.

## Recovering a length

`[*:0]T` has no length, but the sentinel makes it discoverable:

```zig
const slice = std.mem.span(c_string);   // scans to the sentinel
```

Scanning is O(n), the same cost C pays for `strlen`. Do it once at the boundary
and work with slices from there.

Two related functions help here. `std.mem.sliceTo(slice, 0)` truncates at the
first sentinel in something that already has a length, which is what you want
for a fixed-size C struct field holding a padded name. `std.mem.len` gives
just the count without building a slice.

## Producing one

Going the other way, when a C function wants a null-terminated string and
yours is a plain `[]const u8`, the terminator has to exist in memory
somewhere. Three routes:

- **A literal**, if the string is fixed. It is already terminated.
- **`allocator.dupeSentinel(u8, s, 0)`**, which copies and appends the
  terminator, returning a `[:0]u8`. Remember to free it. If you have seen
  `dupeZ` in older code, this is what replaced it, and the sentinel value is now
  an argument rather than baked into the name.
- **A stack buffer with an explicit sentinel slice**, `buf[0..n :0]`, which
  asserts the byte at `buf[n]` really is zero. In a safety build that assertion
  is checked.

Be careful when you slice with a sentinel. `buf[0..n :0]` does not write the
terminator. It claims one is already there. Writing it is your job.

## Why this is not just C strings again

C's model is that the length is *only* discoverable by scanning, so every
operation is O(n) and every buffer overrun begins with a missing terminator.
Zig's model is that the length is carried and the sentinel is an additional
guarantee. Ordinary code uses the length. Only the C boundary uses the
sentinel. In C, a string without a terminator is read until it hits something.
In Zig that can only happen if you built the sentinel type incorrectly by hand.
