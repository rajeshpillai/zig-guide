# For Loops

> Iterate over sequences and ranges, never a bare counter.

In Zig, `for` loops over a slice, an array or a range, and the index comes
from zipping in a second sequence: `for (items, 0..) |item, index|`.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "iterate values" {
    const string = [_]u8{ 'a', 'b', 'c' };
    var count: usize = 0;
    for (string) |character| {
        if (character == 'b') count += 1;
    }
    try expect(count == 1);
}

test "iterate with an index" {
    const string = [_]u8{ 'a', 'b', 'c' };
    var last_index: usize = 0;
    for (string, 0..) |_, index| {
        last_index = index;
    }
    try expect(last_index == 2);
}

test "ranges" {
    var sum: usize = 0;
    for (0..5) |i| sum += i;
    try expect(sum == 10);
}

test "iterate two sequences at once" {
    // Multi-object `for` requires equal lengths; a mismatch is checked.
    const names = [_][]const u8{ "a", "b" };
    const scores = [_]u8{ 1, 2 };
    var total: u8 = 0;
    for (names, scores) |name, score| {
        _ = name;
        total += score;
    }
    try expect(total == 3);
}

test "mutate through a pointer capture" {
    var numbers = [_]u8{ 1, 2, 3 };
    for (&numbers) |*n| n.* *= 2;
    try expect(numbers[2] == 6);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.for-loops`)*

There is no three-clause `for (i = 0; i < n; i++)`. Use `while` for that.
The `for` loop takes its length from the sequence, so you never write the
bound yourself. The common case has no place for an off-by-one error.

## Indices are opt-in

```zig
for (items, 0..) |item, index| { ... }
```

The `0..` is not special syntax. It is a second sequence, iterated in
lockstep with the first. You get an index only when you ask for one. The loop
still cannot run off the end, because the length of `items` decides how long
it runs.

## Iterating several sequences together

The same mechanism zips any number of sequences:

```zig
for (names, scores) |name, score| { ... }
```

Lengths must match. When both are known at compile time, a mismatch is a
compile error that names the lengths:

```
error: non-matching for loop lengths
note: length 3 here
note: length 2 here
```

When they are runtime slices, it is a safety check that panics in Debug and
ReleaseSafe. Either way, the loop cannot silently read past the end of the
shorter one. An indexed loop can easily make that mistake.

A range with no upper bound pairs with anything: `0..` takes its length from
whatever it is zipped with. A bare `for (0..)` with nothing to bound it is a
compile error, because nothing says when to stop.

## Mutating in place

Capturing by value gives you a copy. To modify the underlying elements,
iterate over a pointer to the array and capture by pointer:

```zig
for (&numbers) |*n| n.* *= 2;
```

Both halves are needed. `&numbers` is what makes the loop walk the original
rather than a copy of the array, and `|*n|` is what makes each capture a
pointer into it. Leave off either and the loop compiles and does nothing
useful.

For a slice, the `&` is unnecessary: a slice already refers to memory it does
not own, so `for (slice) |*item|` writes through to the underlying elements.

## Going backwards

There is no reverse range and no step. Counting down is a `while`:

```zig
var i = items.len;
while (i > 0) {
    i -= 1;
    use(items[i]);
}
```

The decrement comes first for a reason: `items.len` is a `usize`, and a loop
written `while (i >= 0) : (i -= 1)` never terminates, because an unsigned
counter cannot go below zero. In a safety build it panics on the wraparound
instead, so at least you find out. Zig accepts this cost on purpose. The
forward loop cannot make this mistake. Going backwards means you manage the
index yourself again.

## `for` also breaks and yields

`break`, `continue`, labels and `else` all work here exactly as on `while`. A
`for` used as an expression yields a value with `break x` and needs an `else`
for the ran-out-of-elements case, which makes linear search a single
expression. See [loops as
expressions](https://www.ziglang.in/learn/language-basics/loops-as-expressions/) and [labelled
loops](https://www.ziglang.in/learn/language-basics/labelled-loops/).

`inline for` unrolls the loop at compile time and makes the capture
comptime-known. This lets a loop walk the fields of a struct or the tags of
an enum. `inline for` is a different tool with a different purpose, covered in
[inline loops](https://www.ziglang.in/learn/language-basics/inline-loops/).
