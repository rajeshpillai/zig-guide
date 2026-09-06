# Slices

> A pointer and a length, together.

A slice is a pointer plus a length. It is the type you should reach for by
default when passing sequences around.

```zig
const std = @import("std");
const expect = std.testing.expect;

fn total(values: []const u8) u32 {
    var sum: u32 = 0;
    for (values) |v| sum += v;
    return sum;
}

test "slicing an array" {
    var array = [_]u8{ 1, 2, 3, 4, 5 };
    const slice = array[1..4]; // end is exclusive
    try expect(slice.len == 3);
    try expect(total(slice) == 9);
}

test "slices share memory" {
    var array = [_]u8{ 1, 2, 3 };
    const slice = array[0..2];
    slice[0] = 100;
    try expect(array[0] == 100); // no copy was made
}

test "strings are slices" {
    // A string literal is a `*const [N:0]u8` (a pointer to a
    // null-terminated array), which coerces to `[]const u8`.
    const message: []const u8 = "hello";
    try expect(message.len == 5);
    try expect(std.mem.eql(u8, message[0..2], "he"));
}

test "slicing to the end" {
    const array = [_]u8{ 1, 2, 3, 4 };
    const rest = array[2..];
    try expect(rest.len == 2);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.slices`)*

## Two words, and both of them matter

`[]T` is exactly a `[*]T` and a `usize`, side by side. Everything else follows
from that. Indexing can be bounds-checked because the length is right there.
`for` knows when to stop. A function taking `[]const u8` cannot be handed a
buffer without also being told how much of it is real.

Compare that with C, where the same job takes two parameters and a convention.
Every function that forgets to pass the length correctly is a buffer overrun.
The slice makes it one value, so the two halves cannot be separated by an
edit.

## Slicing does not copy

`array[1..4]` produces a view into the same memory: writing through the slice
writes through to the array. The upper bound is exclusive, matching `for`
ranges. `array[2..]` slices to the end.

Because a slice borrows, its lifetime is tied to whatever it points at. A
slice of a local array must not outlive that array; Zig will not catch this
for you.

That is the one unchecked hazard in the type, and it is worth naming
precisely. The slice will not stop you indexing it, because as far as the type
is concerned it still has a valid pointer and a valid length. What changed is
that the memory it points at now belongs to something else. Returning a slice
of a stack buffer from the function that owns the buffer is the common
instance; [who owns this
memory](https://www.ziglang.in/learn/systems-from-scratch/who-owns-this-memory/) works through the
shape of the problem.

The bounds themselves *are* checked. `array[1..10]` on a three-element array
panics in Debug and ReleaseSafe with a clear message, and the check is on the
slicing operation, not deferred to the first access.

Reversing, rotating, shifting and removing an element are in [Slice
Recipes](https://www.ziglang.in/learn/language-basics/slice-recipes/).

## `[]const T` vs `[]T`

Take `[]const T` in function parameters unless you intend to mutate. It
documents intent and accepts more callers, since `[]T` coerces to `[]const T`
but not the reverse.

This is the single most useful habit on this page. A signature taking `[]const
u8` says "I will read your bytes and not keep them", which is what most
functions do. It is also the difference between a function that works on a
literal and one that does not. String literals are const, so a parameter typed
`[]u8` cannot accept `"hello"`.

## Strings are slices

Zig has no dedicated string type. A literal like `"hello"` is a `*const
[5:0]u8` (a pointer to a null-terminated array), which coerces to `[]const
u8`. Consequences worth internalising:

- `.len` is the byte count, not a character count. UTF-8 is bytes here.
- Compare with `std.mem.eql(u8, a, b)`, never `==`, which would compare
  pointers.
- The null terminator is present for C interop but is *not* included in `.len`.

The absence of a string type is a real design decision rather than a gap. A
string in Zig is a slice of bytes, so every function that works on `[]const
u8` works on strings, and none of them had to be written twice. What you give
up is any guarantee that the bytes are valid UTF-8. That is why
[unicode](https://www.ziglang.in/learn/standard-library/unicode/) is a separate topic, and why "the
length" has three different answers: bytes, code points, or what a reader
would call characters.

## Getting one

Slices come from four places, and knowing which you have tells you who frees
it:

- **Slicing an array or another slice.** Borrowed. Nothing to free, and the
  lifetime is the original's.
- **An allocator.** `try allocator.alloc(u8, n)` gives you a `[]u8` you own.
  Pair it with a `defer allocator.free(...)` on the next line.
- **A literal.** Static, lives for the whole program, and is `const`.
- **A container.** `list.items` is a slice into memory the list owns, and it is
  invalidated the moment the list reallocates. Do not hold it across an append.

That last one catches everyone once. The slice is still a valid pair of
numbers after the list grows; they just point at the memory the list used to
be in.
