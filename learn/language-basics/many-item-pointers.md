# Many-item Pointers

> [*]T: a pointer to an unknown number of items.

In Zig, `[*]T` is a many-item pointer. It points at an unknown number of `T`. You can use an index on it, but it has no `.len` and no bounds checks. When you know the length, slice the pointer with `many[0..count]`. The result is a `[]T` with bounds checks.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "many-item pointers support indexing" {
    var array = [_]u8{ 1, 2, 3, 4 };
    const many: [*]u8 = &array;

    // You can use an index and pointer arithmetic. But there is no `.len`,
    // thus there is no bounds check. You must make sure that the range is correct.
    try expect(many[0] == 1);
    try expect(many[3] == 4);
}

test "convert to a slice by supplying the length" {
    var array = [_]u8{ 1, 2, 3, 4 };
    const many: [*]u8 = &array;

    // `[*]T` does not have the length. Add the length, and you get a `[]T`.
    // The compiler adds bounds checks to a `[]T` again.
    const slice: []u8 = many[0..3];
    try expect(slice.len == 3);
}

test "single-item pointers do not index" {
    // A `*T` is one item. `ptr[1]` is a compile error. For this reason, Zig
    // has the two types `*T` and `[*]T`, and C has only `T*`.
    var x: u8 = 9;
    const single: *u8 = &x;
    try expect(single.* == 9);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.many-item-pointers`)*

C has one pointer type, `T*`, and C uses it for three different things: one item, many items, and "maybe nothing". Zig has a different type for each:

| Zig | Meaning |
| --- | --- |
| `*T` | exactly one `T` |
| `[*]T` | many `T`, count unknown |
| `[]T` | many `T`, count known (a [slice](https://www.ziglang.in/learn/language-basics/slices/)) |
| `?*T` | one `T`, or nothing |

The different types have a purpose. In C, a function signature with a `char *` parameter gives you no information. A comment or a convention must tell you three things: if the function can use an index, how far, and if null is acceptable. In Zig, the type gives the three answers, and the compiler enforces them.

## What `[*]T` does not have

A many-item pointer supports an index and pointer arithmetic. But it has no `.len`, thus it has **no bounds checks**. The type is mainly for C interop, and for the code that makes the safe abstractions above it.

When you know the length, convert the pointer to a slice:

```zig
const slice: []u8 = many[0..count];
```

This one step gives you bounds checks, `for` iteration and `.len` again. Use slices in all places, except at the boundary where no length is available.

When you slice a `[*]T`, you tell the compiler something that it cannot check. `many[0..count]` makes a slice of exactly `count` elements, also if that number of elements does not exist. If you are wrong, no check fails. After that line, all accesses have checks again. Thus the unchecked statement is in one visible line, not in each access.

Also, `*T` does *not* support an index, and this is intentional. `ptr[1]` on a single-item pointer is a compile error. Thus the type system catches one type of C bug.

## Sentinel-terminated many-item pointers

`[*:0]T` is the one many-item pointer that knows where it ends. The data marks the end, so the pointer does not have to carry a length. This type is exactly a C string. translate-c gives you this type for `char *` parameters when the documentation says that they are null-terminated.

`std.mem.span` moves along the data to the sentinel and returns a slice. Thus the unsafe type exists for only one line at the boundary:

```zig
const name: []const u8 = std.mem.span(c_str);
```

[Sentinel termination](https://www.ziglang.in/learn/language-basics/sentinel-termination/) has all of the sentinel types.

## Where many-item pointers come from

In usual Zig code, you do not often write `[*]T`. A `[*]T` comes from these places:

- **From C.** Each array parameter in a C header is a pointer. Thus translate-c produces `[*c]T`, the C pointer type. When you decide what the header really meant, you convert the `[*c]T` to `[*]T` or `?[*]T`.
- **From the internals of an allocator.** The code of a data structure has a block of memory and a count that the code itself keeps. `ArrayList` holds data of this shape and gives out slices.
- **From hardware or a mapped region.** The address is known, and the length comes from a different source.

All three are boundaries. To keep a program safe, convert at the boundary. Do not let the raw pointer move further into the code than the function that received it.

## `allowzero` and the null case

`[*]T` cannot be null, exactly like `*T`. Use `?[*]T` when the C side can return nothing. The optional uses no more space, because the null address is the tag. `allowzero` is a different modifier. It is for the rare targets where address zero is a correct mapped address. You need `allowzero` only on those targets.
