# C Pointers

> [*c]T: the pointer type translate-c emits, and why to convert it at the boundary.

Zig's C pointer type is `[*c]T`. A `[*c]T` can be null, has no length and has
no bounds checks. Convert it to a slice or a `*T` at the C boundary. Do not
use it in the rest of the program.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "a C pointer is the permissive one" {
    var value: i32 = 42;
    // A [*c]T can be null, you can index it, and it coerces freely. It has
    // none of the guarantees of the other pointer types in Zig.
    const c_ptr: [*c]i32 = &value;
    try expect(c_ptr.* == 42);
    try expect(c_ptr[0] == 42);
}

test "it coerces to and from the safe types" {
    var array = [_]i32{ 1, 2, 3 };
    const many: [*]i32 = &array;
    const c_ptr: [*c]i32 = many;
    const back: [*]i32 = c_ptr;
    try expect(back[2] == 3);
}

test "null is representable" {
    const c_ptr: [*c]i32 = null;
    try expect(c_ptr == null);
}

test "convert at the boundary and use real types inside" {
    var array = [_]i32{ 10, 20, 30 };
    const c_ptr: [*c]i32 = &array;

    // The pointer does not carry the length. Supply the length one time.
    // Then use a slice, which has bounds checks.
    const slice: []i32 = c_ptr[0..3];
    try expect(slice.len == 3);
    try expect(slice[1] == 20);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`05-working-with-c.c-pointers`)*

`[*c]T` is Zig's model of C's `T*`. The main reason for the type is that
translate-c can then convert headers automatically.

## A C pointer has no guarantees

| Property | `*T` | `[]T` | `[*c]T` |
| --- | --- | --- | --- |
| can be null | no | no | **yes** |
| carries a length | n/a | yes | no |
| bounds checked | n/a | yes | no |
| indexable | no | yes | yes |
| coerces freely | no | no | **yes** |

The last row is the dangerous row. A `[*c]T` converts to and from the safe
pointer types, and the compiler does not complain. At a C boundary, this
conversion is convenient. In all other places, the conversion causes damage.
The conversion removes the guarantees that the rest of the language depends
on, and nothing tells you.

## Why the type is necessary

A C header cannot tell the translator which of the three things a `T*` is.
Look at `void process(int *data, size_t n)`. A human reads the two parameters
together, and decides that `data` is an array of `n` items. Look at
`int *out`. A human reads the name, and decides that `out` is one item that
the function writes through. But the declaration itself is the same in the
two examples.

Thus translate-c cannot select a type. `[*c]T` is the type that means "any one
of these three things". Each safe pointer type would be a guess. A wrong guess
causes more damage than no guess.

## Read the header, not the signature

Thus at a C boundary, your task is to decide what the C function really
promises. Then write that promise as a Zig type. Ask four questions. Usually,
the documentation of the header is the only place with the answers:

- **How many items?** One, or `n`, or all items until a terminator.
- **Can the pointer be null?** Frequently yes, and frequently null has a
  specific meaning.
- **Who owns the memory?** Does the function keep the pointer after it
  returns? Must the caller free the result, and with which free function?
- **Does the function write to the memory?** A C declaration without `const`
  does not prove that the function writes. It also does not prove the opposite.

The type that you get from translate-c answers none of these questions.
Answer them one time, in the wrapper. Then the rest of the program can use the
answers. When no person answers the questions, C programs get bugs.

## Convert at the boundary

When you know the length, make a slice. After that, use only the slice:

```zig
const slice: []i32 = c_ptr[0..count];
```

The slice gives you bounds checks, `for` loops and `.len`. If the pointer can
be null, check it one time and change it into an optional. Do not send the
uncertainty to other parts of the program.

In practice, you write a thin Zig wrapper for each C function that you use. The signature of the wrapper states what the C function really
promises:

```zig
pub fn process(data: []i32) void {
    c.process(data.ptr, data.len);
}
```

The wrapper has three lines, and all of the program above the wrapper uses a
slice. The unchecked assumption is in one place, where you can compare it
with the header. It is not at each call site.

## Which pointer type to use

If the pointer type does not come from translate-c or from an `extern`
declaration, do not write `[*c]`. Use one of these types:

- `*T` for one item.
- `[*]T` for many items.
- `[]T` when you know the count.
- `?` when the value can be absent.

Sometimes a `[*c]` occurs in a compile error deep inside your own code, far
from any C. Then a `[*c]` came out of a boundary, and your code passed it
to other code from there. Fix the problem at that boundary, not at the place of the
error.
