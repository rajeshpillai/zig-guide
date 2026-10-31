# Opaque

> Types with unknown size, used through pointers only.

In Zig, `opaque {}` is the equivalent of the incomplete type in C. Use it for handles that code can hold only through a pointer. translate-c produces handles of this type from a C header.

```zig
const std = @import("std");
const expect = std.testing.expect;

// Usually this type replaces a C type that has no definition that you can
// see: `typedef struct Window Window;`
const Window = opaque {
    // Opaque types can still have methods.
    pub fn close(self: *Window) void {
        _ = self;
    }
};

const Handle = opaque {};

test "opaque types are only usable behind a pointer" {
    // `var w: Window = ...` is impossible, because the size is unknown. Only
    // pointers to a `Window` exist. C code uses C handles in the same way.
    var storage: u32 = 0;
    const handle: *Handle = @ptrCast(&storage);
    try expect(@TypeOf(handle) == *Handle);
}

test "distinct opaque types do not mix" {
    // *Window and *Handle are unrelated types. Thus the compiler does not let
    // you use one type where the other type is necessary. C's void* allows it.
    try expect(*Window != *Handle);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.opaque`)*

An `opaque {}` type has an unknown size and layout. You can never have a value of the type. You can have only a pointer to a value.

The compiler really does not know the size. If you ask for the size, the compiler refuses:

```
error: no size available for uninstantiable type
note: opaque declared here
```

Thus each of these fails, because each one needs a size:

- `@sizeOf` on the type.
- A local variable of the type.
- An array of the type.
- A struct field of the type.

Only a pointer works. The size of a pointer comes from the machine, not from the type that the pointer points at.

## Why an opaque type is useful

An opaque type is the Zig form of an incomplete type in C:

```c
typedef struct Window Window;   /* definition not provided */
Window *create_window(void);
```

The library gives you a `*Window`, and you can only give it back to the library. You cannot examine it, copy it, or put it on the stack. Its size is not part of the public interface.

The compiler enforces this rule. Thus the rule does not depend on callers who read the documentation.

When a library shows a struct definition, its layout cannot change. If the library adds a field, the size changes. Then each caller that put the struct on the stack has the wrong quantity of memory. An opaque type has no public layout. Thus the library can change its layout in a later version, and code that uses it does not have to compile again.

## Better than `void*`

The usual alternative in C is `void*`, which removes the type completely. Nothing prevents a `*File` where the code expects a `*Window`. Different opaque types stay different:

```zig
*Window != *Handle    // different types, checked by the compiler
```

You keep the rule that callers cannot look inside, and you keep type safety at the boundary. Opaque types can also have methods. Thus the handle still reads like an object: `window.close()`.

`opaque {}` has a body. The body can hold `pub fn` declarations, constants and nested types, exactly like a `struct`. But the body cannot hold fields, because fields give a type a size.

Thus the full public interface of a C handle library becomes one opaque type with methods. The code that calls it never learns more than it must.

## Where you find opaque types

Almost always, you find them at a C boundary. translate-c changes each incomplete type in a header into an opaque type. Thus the pointers that translate-c gives you stay different types, and they do not all become `?*anyopaque`. See [C headers](https://www.ziglang.in/learn/working-with-c/cimport/) and [C pointers](https://www.ziglang.in/learn/working-with-c/c-pointers/).

A related type is `anyopaque`. It is the type for "a pointer to a value whose type I removed". `anyopaque` is the direct translation of `void*` in C. A callback takes an `anyopaque` pointer when it receives user data of any type. `anyopaque` removes the type intentionally. An opaque type keeps the type and hides the layout.

To convert between the two, use `@ptrCast`. You must make sure that the conversion is correct. When the layout is unknown, the compiler cannot check the conversion. You accepted this condition when you selected a handle.
