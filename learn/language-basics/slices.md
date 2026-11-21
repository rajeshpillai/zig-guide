# Slices

> A pointer and a length, together.

A slice is a pointer plus a length. When you give a sequence to a function, use a slice by default.

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
    try expect(array[0] == 100); // the slice is not a copy
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

## Two words, and the two are both important

`[]T` is exactly a `[*]T` and a `usize`, side by side. All other properties come from that structure:

- An index can have a bounds check, because the length is in the slice.
- `for` knows when to stop.
- A function that takes `[]const u8` cannot receive a buffer without the length of the real data in it.

Compare this with C. In C, the same job needs two parameters and a convention. Each function that does not give the length correctly causes a buffer overrun. A slice puts the two parts in one value. Thus an edit cannot separate the two parts.

## A slice is not a copy

`array[1..4]` gives a view into the same memory. A write through the slice changes the array. The upper bound is exclusive, as in `for` ranges. `array[2..]` makes a slice to the end.

A slice borrows memory. Thus the lifetime of a slice depends on the memory that it points at. A slice of a local array must not live longer than that array. Zig does not catch this error for you.

The type does not check the lifetime, and this is the one hazard of a slice. The slice does not stop you when you use an index on it. For the type, the slice still has a valid pointer and a valid length. But the memory that it points at now belongs to a different part of the program.

A usual example is a function that owns a stack buffer and returns a slice of that buffer. [Who owns this memory](https://www.ziglang.in/learn/systems-from-scratch/who-owns-this-memory/) shows the shape of this problem.

The program *does* check the bounds. If you write `array[1..10]` on an array with three elements, and the two bounds are comptime-known, the compiler rejects the code. When the upper bound comes from a runtime value, the check occurs at runtime. It causes a panic in Debug and ReleaseSafe. In the two cases, the check is on the slice operation. It does not wait for the first access.

[Slice Recipes](https://www.ziglang.in/learn/language-basics/slice-recipes/) shows how to reverse, rotate and shift a slice, and how to remove an element.

## `[]const T` vs `[]T`

In function parameters, use `[]const T`, unless the function changes the data. `[]const T` tells the reader the intent. It also accepts more callers, because `[]T` coerces to `[]const T`, but not in the opposite direction.

A signature that takes `[]const u8` says "I will read your bytes, and I will not keep them". Most functions do this. Also, the `const` decides if the function works on a literal. String literals are const. Thus a parameter of type `[]u8` cannot accept `"hello"`.

## Strings are slices

Zig has no special string type. A literal such as `"hello"` is a `*const [5:0]u8` (a pointer to a null-terminated array), and it coerces to `[]const u8`. There are three results:

- `.len` is the number of bytes, not the number of characters. Here, UTF-8 is bytes.
- To compare two strings, use `std.mem.eql(u8, a, b)`. Never use `==`, because `==` compares the pointers.
- The null terminator is there for C interop, but `.len` does *not* count it.

Zig omits a string type intentionally. A string in Zig is a slice of bytes. Thus each function that works on `[]const u8` also works on strings, and no function has two versions.

The cost is that there is no guarantee that the bytes are valid UTF-8. For this reason, [unicode](https://www.ziglang.in/learn/standard-library/unicode/) is a separate topic. "The length" also has three different answers: bytes, code points, or what a reader calls characters.

## Where slices come from

Slices come from four places. When you know the source of a slice, you know who frees it:

- **A slice of an array or of a different slice.** It borrows memory. You do not free it, and its lifetime is the lifetime of the original.
- **An allocator.** `try allocator.alloc(u8, n)` gives you a `[]u8` that you own. On the next line, put a `defer allocator.free(...)`.
- **A literal.** It is static, it lives for the full program, and it is `const`.
- **A container.** `list.items` is a slice into memory that the list owns. When the list reallocates, the slice becomes invalid immediately. Do not keep the slice across an append.

The last case is an easy mistake. After the list grows, the slice is still a valid pair of numbers. But the numbers point at the old memory of the list.
