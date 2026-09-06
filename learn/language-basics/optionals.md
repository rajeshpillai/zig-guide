# Optionals

> Zig's answer to null, checked by the compiler.

A `?T` holds either a `T` or `null`. The compiler will not let you use the
value without handling the `null` case first, so there is no such thing as an
accidental null dereference.

These are real tests. Run executes the actual `zig test` runner, compiled to
WebAssembly.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "optional payload capture" {
    var maybe: ?i32 = null;
    try expect(maybe == null);

    maybe = 42;
    if (maybe) |value| {
        try expect(value == 42);
    } else {
        unreachable;
    }
}

test "orelse supplies a default" {
    const nothing: ?u32 = null;
    try expect((nothing orelse 7) == 7);
}

test "optional pointers are free" {
    // A `?*T` is the same size as a `*T`; null is the 0 address.
    try expect(@sizeOf(?*i32) == @sizeOf(*i32));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.optionals`)*

## Payload capture

The `if (maybe) |value|` form is *payload capture*: inside the block, `value`
is a plain `i32`, not an optional. The unwrapping and the null check are the
same piece of syntax, so they cannot drift apart.

`orelse` is the shorthand when all you want is a fallback:

```zig
const port = maybe_port orelse 8080;
```

`orelse` takes an expression on the right, not just a value, and that
expression can exit:

```zig
const port = maybe_port orelse return error.MissingPort;
const item = list.pop() orelse break;
```

Both read as "or else give up this way", and both keep the happy path
unindented. This is the form to reach for when null means the function cannot
continue.

## Forcing it with `.?`

`maybe.?` unwraps and asserts the value is there. It is `orelse unreachable`,
which means: checked and panicking in Debug and ReleaseSafe, undefined
behaviour in ReleaseFast.

Use it where the invariant is genuinely local and visible, such as immediately
after inserting a key you are about to look up. Do not use it to quiet the
compiler on a value that came from outside the function, because the assertion
you are making is about someone else's code.

## What is missing on purpose

There is no way to compare an optional to its payload without unwrapping it.
There is no implicit conversion from `?T` to `T`. There is no way to call a
method on a `?T`. Every one of those exists in languages where null is a value
of every type, and every one of them is a place a null slips through.

The cost is that a chain of optional lookups is more verbose than an `a?.b?.c`
operator would be. The benefit is that each `orelse` names what happens when
that particular step finds nothing, which is usually different at each step
and usually worth saying.

## Optional pointers are free

`?*T` is the same size as `*T`. Zig uses the null address as the `null` tag,
so optional pointers cost nothing: no extra byte, no wrapper struct. The last
test above asserts exactly this with `@sizeOf`.

Note that this only applies to pointers. A `?u32` genuinely needs a tag byte
alongside the payload, because every `u32` bit pattern is a valid `u32`.

The rule is that an optional pays for a tag only when the payload has no bit
pattern to spare. A pointer has one, the null address, and `?T` uses it. A
`u32` does not, so `?u32` is larger than a `u32`.

Error unions do not get the same treatment: `error{A}!*u8` is twice the size
of a `*u8`, because it has to carry the error code as well as the pointer.
Sometimes a value that is genuinely just "there or not" gets returned as an
error union to avoid writing an explanation. This is one more reason to make
it a `?T` instead.

## Optional versus error

Both mean "you might not get a value", and choosing between them is a question
about whether there is anything to say about the failure.

- **`?T`** when absence is ordinary and needs no explanation: a lookup that
  found nothing, an iterator that ended, a field that was not set.
- **`E!T`** when the caller would want to know *why*: the file did not exist, the
  input was malformed, the allocation failed.

A function returning `?T` for something that failed for a reason has thrown
the reason away. A function returning `error{NotFound}!T` for an ordinary miss
makes every caller write a `catch` for a case that is not exceptional.
[Errors](https://www.ziglang.in/learn/language-basics/errors/) covers the other half.
