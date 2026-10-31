# If Expressions

> No truthiness: if takes a bool.

In Zig, `if` is a control-flow statement. It is also an expression that can give a value.

C, JavaScript and most other languages have truthy and falsy values. Zig does not. The condition must be a `bool`, and no other type converts to `bool`.

Zig also has no ternary `?:`. An `if` that you use as an expression does that job: `const x = if (a) 1 else 2;`.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "if as a statement" {
    const a = true;
    var x: u16 = 0;
    if (a) {
        x += 1;
    } else {
        x += 2;
    }
    try expect(x == 1);
}

test "if as an expression" {
    const a = true;
    // This replaces the ternary operator. The two branches must give the
    // same type.
    const x: u16 = if (a) 1 else 2;
    try expect(x == 1);
}

test "if unwraps an optional" {
    const maybe: ?u8 = 42;
    const doubled: u16 = if (maybe) |value| value * 2 else 0;
    try expect(doubled == 84);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.if-expressions`)*

Zig has no truthiness. `if (1)` does not compile, and `if (pointer)` does not compile. The condition must be a `bool`:

```
error: expected type 'bool', found 'u8'
```

This rule removes a full family of bugs, where code uses a value as a flag by accident. Some examples from C:

- `if (strcmp(a, b))` is true when the strings are *different*.
- `if (n = 0)` is an assignment, and it is always false.
- `if (ptr)` and `if (*ptr)` have one character of difference, but their meanings are completely different.

None of these examples parse in Zig.

## `if` gives a value

Zig has no ternary operator, because it does not need one:

```zig
const x: u16 = if (a) 1 else 2;
```

The two branches must have the same type. When you use `if` as an expression, the `else` is necessary. Without the `else`, the absent branch gives `void`, and the error gives the name of that type:

```
error: expected type 'u16', found 'void'
```

An `if` with no `else` has no value when the condition is false. Thus its type is `void`. Read the message as "this expression does not always give a value".

One case gets past this rule: a condition that the compiler knows. If the compiler knows the condition at comptime, it compiles only the branch that runs. Thus `const x: u16 = if (true) 1;` builds. If you make the condition a runtime value, the build fails.

This is not a special rule for `if`. It is the same constant folding that lets the compiler remove `comptime` code fully.

## Unwrap an optional

You also use `if` to get the value inside an optional, with a payload capture:

```zig
if (maybe) |value| {
    // value is the payload, not the optional
} else {
    // maybe was null
}
```

The captured `value` is a copy. To change the value inside the optional, capture by pointer with `|*value|`, and write through the pointer. Without the `*`, the change goes to the copy, and the change is lost. Remember this, because the compiler gives no warning.

Error unions use the same shape. The error goes to the `else`:

```zig
if (parse(text)) |n| {
    use(n);
} else |err| {
    report(err);
}
```

This idea occurs again and again in Zig. The check and the unwrap are one construct, thus they always agree. No code can test for null and then read the payload through a different path that does not do the test.

## Shorter forms

`if` on an optional is the general form. Three shorter forms are for the common cases:

- `maybe orelse default`, when you only want a fallback value.
- `try f()`, when you only want to return the error to the caller.
- `f() catch |err| ...`, when you want to handle the error here.

Use `if` when the two sides do real work. Use a short form when one side is a single expression. `x orelse 0` says the same as `if (x) |v| v else 0` in a quarter of the space.

[Optionals](https://www.ziglang.in/learn/language-basics/optionals/) explains optionals, and [errors](https://www.ziglang.in/learn/language-basics/errors/) explains the error forms.
