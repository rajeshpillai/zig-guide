# While Loops

> Conditions, continue expressions, and loops that produce values.

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
    // The continue expression runs after every iteration, including ones
    // ended by `continue`, which is why it is not just the last statement.
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
    // `break x` yields a value; `else` runs when the loop ends normally.
    var i: u8 = 0;
    const found = while (i < 10) : (i += 1) {
        if (i * i > 20) break i;
    } else 0;
    try expect(found == 5);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.while-loops`)*

`while` takes a condition and runs the body until it goes false. There is no
C-style `for (init; cond; step)` in Zig; `while` with a continue expression is
that loop, and `for` is reserved for walking something that has elements.

## The continue expression

```zig
while (i <= 10) : (i += 1) { ... }
```

The `: (i += 1)` part runs after **every** iteration, including ones cut short
by `continue`. That is precisely why it exists, rather than just putting the
increment at the end of the body. Once `continue` is involved the two are not
the same, and the resulting bug is easy to miss.

Concretely, this terminates:

```zig
while (i < 10) : (i += 1) {
    if (skip(i)) continue;
    work(i);
}
```

and this does not:

```zig
while (i < 10) {
    if (skip(i)) continue;   // i never advances
    work(i);
    i += 1;
}
```

Both look like the same loop. The second hangs the first time `skip` returns
true. Putting the step in the continue expression makes it structurally
impossible for a `continue` to skip it.

The continue expression can hold more than one statement if it needs to,
written as a block: `: ({ i += 1; n += 1; })`.

## Looping until something runs out

A condition that is an optional binds its payload, and the loop ends when the
optional is null. This is how nearly every iterator in the standard library is
consumed:

```zig
while (it.next()) |item| {
    // item is the payload, not the optional
}
```

There is no separate "is there another one" call and no sentinel value to
compare against. The same shape works with a continue expression, so a counted
walk over an iterator is one line:

```zig
while (it.next()) |_| : (n += 1) {}
```

The capture syntax is the same one `if` uses; it is covered on its own in
[payload captures](https://www.ziglang.in/learn/language-basics/payload-captures/).

A condition that is an error union works the same way, with the error going to
an `else` capture:

```zig
while (stream.next()) |chunk| {
    consume(chunk);
} else |err| {
    return err;
}
```

The loop body runs on each success, and the `else` runs once with whatever
error ended it.

## Loops that produce values

`break` can carry a value, and `while` can have an `else` branch that runs
when the loop finishes without breaking:

```zig
const found = while (i < 10) : (i += 1) {
    if (i * i > 20) break i;
} else 0;
```

This is the search-with-fallback pattern as a single expression, with no
sentinel variable and no way to forget the not-found case. The rules for it,
including what the compiler says when the `else` is missing, are in [loops as
expressions](https://www.ziglang.in/learn/language-basics/loops-as-expressions/).

## Infinite loops

`while (true)` is the idiomatic infinite loop, and the compiler knows it
cannot end normally. Used as an expression it needs no `else`, because `break`
is the only way out. Use it when the exit condition is decided in the middle
of the body rather than at the top. That is common for anything reading input
until it sees a terminator.

## Naming the loop

A `while` can carry a label, so `break :outer` and `continue :outer` work on
it exactly as they do on `for`. See [labelled
loops](https://www.ziglang.in/learn/language-basics/labelled-loops/), which also covers the one
surprise: a labelled `continue` still runs that loop's continue expression.
