# Loops as Expressions

> else supplies the value when nothing breaks.

```zig
const std = @import("std");
const expect = std.testing.expect;

fn firstIndexOf(haystack: []const u8, needle: u8) ?usize {
    // The `else` branch runs only if the loop finished without breaking,
    // so "not found" cannot be forgotten.
    return for (haystack, 0..) |c, i| {
        if (c == needle) break i;
    } else null;
}

test "for as an expression" {
    try expect(firstIndexOf("hello", 'l').? == 2);
    try expect(firstIndexOf("hello", 'z') == null);
}

test "while as an expression" {
    var i: u32 = 0;
    const result = while (i < 10) : (i += 1) {
        if (i == 4) break i * 10;
    } else 0;
    try expect(result == 40);
}

test "the else branch runs when nothing breaks" {
    var i: u32 = 0;
    const result = while (i < 3) : (i += 1) {
        if (i == 99) break @as(u32, 1);
    } else @as(u32, 2);
    try expect(result == 2);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.loops-as-expressions`)*

A loop can produce a value: `break x` yields `x`, and the `else` branch
supplies the value when the loop finishes without ever breaking.

```zig
return for (haystack, 0..) |c, i| {
    if (c == needle) break i;
} else null;
```

That is a complete linear search, and the "not found" case is structurally
impossible to forget: leave off the `else` and it does not compile.

Compare the usual alternative:

```zig
var result: ?usize = null;
for (haystack, 0..) |c, i| {
    if (c == needle) { result = i; break; }
}
return result;
```

Same behaviour, but now `result` is mutable, lives longer than it needs to,
and nothing forces you to initialise it correctly.

## What `else` means on a loop

It is not the `else` of an `if`. It runs when the loop ends *normally*: the
`for` ran out of elements, or the `while` condition became false. A `break`
skips it. That is the entire rule, and it is what makes the construct safe for
searches. There are exactly two ways out of the loop, and each one produces a
value.

The third test in the snippet pins that down with a `break` written so it can
never fire:

```zig
const result = while (i < 3) : (i += 1) {
    if (i == 99) break @as(u32, 1);
} else @as(u32, 2);
```

`i` never reaches 99, the condition goes false, and `result` is 2.

## What the missing `else` actually looks like

The failure is worth seeing, because the error does not mention `else` at all.
A loop with no `else` has nothing to evaluate to when it ends normally, so its
type is `void`:

```
error: expected type '?usize', found 'void'
```

pointing at the whole `for` expression. Read it as "this loop does not always
produce a value". Adding the `else` is the fix.

The one loop that needs no `else` is one that cannot end normally. `while
(true)` has no condition to go false, so the only way out is `break`, and the
compiler knows it:

```zig
const v = while (true) : (i += 1) {
    if (i == 3) break i;
};
```

That compiles, and `v` is `usize`. Add an `else` there and it is dead code.

## Both arms must agree on a type

The `break` value and the `else` value are two arms of one expression, so they
have to reach a single type. In the search above they are `usize` and `null`,
which unify as `?usize`, and that is the function's return type.

When the arms are bare integer literals they are comptime-known and coerce to
whatever the surrounding code wants. When there is nothing to coerce toward,
you have to say. That is why the test writes `@as(u32, 1)` and `@as(u32, 2)`
rather than `1` and `2`: `const result = ...` gives the literals no target
type to take their size and signedness from.

If the arms genuinely disagree, the error names both types and points at the
`break`. That check is the reason a search cannot accidentally return an index
on one path and a boolean on another.

## When to reach for it

The pattern is worth using when the loop answers exactly one question: find
this, count until that, decide whether any element qualifies. The value comes
out where it is decided, and the compiler holds you to covering both outcomes.

It stops helping when a loop has five `break` sites carrying five different
meanings. Nothing prevents that, and the result is harder to follow than an
explicit variable, because the reader now has to find every `break` to know
what the expression can be. One or two exits is the shape this is for.
