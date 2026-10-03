# Opaque

> Types with unknown size, used through pointers only.

Zig's `opaque {}` is the equivalent of C's incomplete type. It is used for
handles that code may only hold through a pointer, such as the ones
translate-c produces from a C header.

```zig
const std = @import("std");
const expect = std.testing.expect;

// Typically this stands in for a C type you were never given a definition
// for: `typedef struct Window Window;`
const Window = opaque {
    // Opaque types can still have methods.
    pub fn close(self: *Window) void {
        _ = self;
    }
};

const Handle = opaque {};

test "opaque types are only usable behind a pointer" {
    // `var w: Window = ...` is impossible: the size is unknown. Only
    // pointers to it exist. C handles are used the same way.
    var storage: u32 = 0;
    const handle: *Handle = @ptrCast(&storage);
    try expect(@TypeOf(handle) == *Handle);
}

test "distinct opaque types do not mix" {
    // *Window and *Handle are unrelated types, so the compiler prevents
    // passing one where the other is expected, unlike C's void*.
    try expect(*Window != *Handle);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.opaque`)*

An `opaque {}` type has unknown size and layout. You can never have one by
value, only a pointer to one.

The compiler really does not know the size. Ask for it and the compiler
refuses:

```
error: no size available for uninstantiable type
note: opaque declared here
```

So `@sizeOf` fails, a local variable of that type fails, an array of
them fails, and a struct field of that type fails. Every one of those needs a
size. The only thing that works is a pointer, because a pointer's size is a
property of the machine and not of what it points at.

## Why you would want that

This is the Zig spelling of C's incomplete type:

```c
typedef struct Window Window;   /* definition not provided */
Window *create_window(void);
```

The library hands you a `*Window` and you may only pass it back. You cannot
inspect it, copy it, or put it on the stack, because its size is not
part of the public interface.

The compiler enforces this, so it does not depend on callers reading the
documentation. A library that
exposes a struct definition has frozen its layout. Adding a field changes the
size, and every caller that allocated one on the stack now has the wrong
amount of memory. An opaque type has no layout to freeze, so the library can
change it in a later version without recompiling anything that uses it.

## Better than `void*`

C's usual alternative is `void*`, which erases the type entirely. Nothing
stops you passing a `*File` where a `*Window` was expected. Distinct opaque
types stay distinct:

```zig
*Window != *Handle    // different types, checked by the compiler
```

You keep the "you may not look inside" property without giving up type safety
at the boundary. Opaque types can also have methods, so the handle still reads
like an object: `window.close()`.

`opaque {}` has a body, and it
can hold `pub fn` declarations, constants and nested types, exactly like a
`struct`. What it cannot hold is fields, because fields are what would give it
a size. So the whole public interface of a C handle library translates into
one opaque type with methods on it, and calling code never learns anything it
should not.

## Where you actually meet it

Almost always at a C boundary. translate-c turns every incomplete type in a
header into an opaque type, which is why the pointers it hands you stay
distinct instead of collapsing into `?*anyopaque`. See [importing C
headers](https://www.ziglang.in/learn/working-with-c/cimport/) and [C
pointers](https://www.ziglang.in/learn/working-with-c/c-pointers/).

A related type is `anyopaque`, the type for "a pointer to something whose type
I have erased". It is the direct translation of C's
`void*`, and it is what a callback takes when it is handed arbitrary user
data. `anyopaque` drops the type on purpose. An opaque type keeps the type and
hides the layout.

Converting between them is `@ptrCast`, and you are responsible for getting it
right. The compiler cannot check it once the layout is unknown. You accepted
that when you chose a handle.
