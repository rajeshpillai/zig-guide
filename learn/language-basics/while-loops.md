# While Loops

> Conditions, continue expressions, and loops that produce values.

The counting loop in Zig is `while (i < n) : (i += 1)`. The continue expression after the colon runs after each iteration. It also runs after an iteration that `continue` ends early.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "basic while" {
    var i: u8 = 2;
    while (i < 100) {
        i *= 2;
    }
    try expect(i == 128);
}

test "while with a continue expression" {
    // The continue expression runs after each iteration, also after one that
    // `continue` ends. Thus it is different from the last statement of the body.
    var sum: u8 = 0;
    var i: u8 = 1;
    while (i <= 10) : (i += 1) {
        sum += i;
    }
    try expect(sum == 55);
}

test "break and continue" {
    var sum: u8 = 0;
    var i: u8 = 0;
    while (i <= 3) : (i += 1) {
        if (i == 2) continue;
        sum += i;
    }
    try expect(sum == 4); // 0 + 1 + 3
}

test "while as an expression with else" {
    // `break x` gives a value. `else` runs when the loop ends normally.
    var i: u8 = 0;
    const found = while (i < 10) : (i += 1) {
        if (i * i > 20) break i;
    } else 0;
    try expect(found == 5);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.while-loops`)*

`while` takes a condition, and runs the body until the condition becomes false. Zig has no C-style `for (init; cond; step)`. A `while` with a continue expression is that loop. Zig uses `for` only for a value that has elements.

## The continue expression

```zig
while (i <= 10) : (i += 1) { ... }
```

The `: (i += 1)` part runs after **each** iteration. It also runs after an iteration that `continue` ends early. For this reason, the continue expression exists. You could put the increment at the end of the body, but when the loop uses `continue`, the two forms are not the same. The bug that results is easy to miss.

For example, this loop stops:

```zig
while (i < 10) : (i += 1) {
    if (skip(i)) continue;
    work(i);
}
```

This loop does not stop:

```zig
while (i < 10) {
    if (skip(i)) continue;   // i never advances
    work(i);
    i += 1;
}
```

The two loops look the same. But the second loop does not stop the first time that `skip` returns true. When the step is in the continue expression, the structure makes it impossible for a `continue` to skip the step.

If necessary, the continue expression can hold more than one statement, as a block: `: ({ i += 1; n += 1; })`.

## Loop until there are no more values

When the condition is an optional, the loop binds its payload. The loop ends when the optional is null. Code in the standard library uses almost all iterators in this way:

```zig
while (it.next()) |item| {
    // item is the payload, not the optional
}
```

There is no separate call that asks "is there another one". There is also no sentinel value to compare against. The same shape works with a continue expression. Thus a loop that counts the items of an iterator is one line:

```zig
while (it.next()) |_| : (n += 1) {}
```

The capture syntax is the same syntax that `if` uses. [Payload captures](https://www.ziglang.in/learn/language-basics/payload-captures/) is the chapter about this syntax.

A condition that is an error union works in the same way. The error goes to an `else` capture:

```zig
while (stream.next()) |chunk| {
    consume(chunk);
} else |err| {
    return err;
}
```

The loop body runs on each success. The `else` runs one time, with the error that ended the loop.

## Loops that produce values

`break` can carry a value. A `while` can have an `else` branch, which runs when the loop ends without a `break`:

```zig
const found = while (i < 10) : (i += 1) {
    if (i * i > 20) break i;
} else 0;
```

This code is a search with a fallback, as one expression. It needs no sentinel variable, and you cannot forget the "not found" case. [Loops as expressions](https://www.ziglang.in/learn/language-basics/loops-as-expressions/) gives the rules, and the error that the compiler gives when there is no `else`.

## Infinite loops

`while (true)` is the usual infinite loop, and the compiler knows that it cannot end normally. When you use it as an expression, it needs no `else`, because `break` is the only exit.

Use `while (true)` when the code decides the exit condition in the middle of the body, not at the top. This is usual for code that reads input until it sees a terminator.

## Give the loop a name

A `while` can have a label. Thus `break :outer` and `continue :outer` work on it exactly as they do on `for`. See [labelled loops](https://www.ziglang.in/learn/language-basics/labelled-loops/). That chapter also explains one rule that can surprise you: a labelled `continue` still runs the continue expression of that loop.
