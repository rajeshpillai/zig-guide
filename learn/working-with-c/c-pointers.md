# C Pointers

> [*c]T: the escape hatch, and why to leave it at the door.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "a C pointer is the permissive one" {
    var value: i32 = 42;
    // [*c]T can be null, can be indexed, and coerces freely. It gives up
    // every guarantee Zig's other pointer types provide.
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

    // The length is not carried by the pointer; supply it once, then work
    // with a bounds-checked slice.
    const slice: []i32 = c_ptr[0..3];
    try expect(slice.len == 3);
    try expect(slice[1] == 20);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`05-working-with-c.c-pointers`)*

`[*c]T` is Zig's model of C's `T*`. It exists almost entirely so that
`@cImport` can translate headers automatically.

## It gives up everything

| Property | `*T` | `[]T` | `[*c]T` |
| --- | --- | --- | --- |
| can be null | no | no | **yes** |
| carries a length | n/a | yes | no |
| bounds checked | n/a | yes | no |
| indexable | no | yes | yes |
| coerces freely | no | no | **yes** |

That last row is the dangerous one. A `[*c]T` converts to and from the safe
pointer types without complaint. That is convenient at a C boundary and
harmful anywhere else, because it silently discards the guarantees the rest of
the language is built on.

## Convert at the boundary

The moment you know the length, produce a slice and never look back:

```zig
const slice: []i32 = c_ptr[0..count];
```

Now you have bounds checks, `for` iteration, and `.len`. If the pointer might
be null, check once and turn it into an optional rather than propagating the
uncertainty.

## Why it has to exist

A C header cannot tell the translator which of the three things a `T*` is.
Given `void process(int *data, size_t n)`, a human reads the two parameters
together and concludes `data` is an array of `n`. Given `int *out`, a human
reads the name and concludes it is one item written through. The declaration
itself says the same thing in both cases.

So `@cImport` cannot choose, and `[*c]T` is the type that means "whichever of
these it turns out to be". Every safe pointer type would have been a guess,
and a wrong guess would have been worse than no guess.

## Reading the header, not the signature

Which means the work at a C boundary is deciding what the C function actually
promised, and writing that down in a Zig type. Four questions, and the
header's documentation is usually the only source for the answers:

- **How many?** One, or `n`, or until a terminator.
- **Can it be null?** Frequently yes, and frequently that means something
  specific.
- **Who owns it?** Does the callee keep the pointer after returning; must the
  caller free the result, and with which free.
- **Is it written to?** A missing `const` in C proves nothing either way.

None of that is in the type you were handed. Answering it once, at the
wrapper, is what makes the rest of the program safe. Answering it nowhere is
how C programs get their bugs.

## Convert at the boundary

The moment you know the length, produce a slice and never look back:

```zig
const slice: []i32 = c_ptr[0..count];
```

Now you have bounds checks, `for` iteration, and `.len`. If the pointer might
be null, check once and turn it into an optional rather than propagating the
uncertainty.

In practice this means writing a thin Zig wrapper around each C function you
use, whose signature is the honest one:

```zig
pub fn process(data: []i32) void {
    c.process(data.ptr, data.len);
}
```

Three lines, and everything above it in the program is dealing with a slice.
The unchecked assumption lives in one place where it can be reviewed against
the header, rather than at every call site.

## Rule of thumb

If you did not get it from `@cImport` or an `extern` declaration, you should
not be writing `[*c]`. Use `*T` for one item, `[*]T` for many, `[]T` when you
know the count, and `?` when it may be absent.

A `[*c]` appearing in a compile error deep inside your own code, far from any
C, means one leaked out of a boundary. It has been travelling ever since. The
fix is at the boundary, not at the error.
