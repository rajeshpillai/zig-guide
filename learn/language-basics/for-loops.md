# For Loops

> Iterate over sequences and ranges, never a bare counter.

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

Zig's `for` iterates over something: a slice, an array, a range. There is no
three-clause `for (i = 0; i < n; i++)`; that is what `while` is for. The
result is that the common case carries no opportunity for an off-by-one. You
do not write the bound, so you cannot write it wrong.

## Indices are opt-in

```zig
for (items, 0..) |item, index| { ... }
```

The `0..` is a second sequence to iterate in lockstep, not special syntax. You
only pay for the index when you ask for it, and the loop still cannot run off
the end, because `items` is what decides how long it runs.

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
ReleaseSafe. Either way this cannot silently read past the end of the shorter
one, which is the bug the equivalent indexed loop invites.

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
instead, which at least tells you. That asymmetry is a deliberate cost. The
forward loop is the one that is safe by construction, and going backwards
means opting back into managing the index yourself.

## `for` also breaks and yields

`break`, `continue`, labels and `else` all work here exactly as on `while`. A
`for` used as an expression yields a value with `break x` and needs an `else`
for the ran-out-of-elements case, which makes linear search a single
expression. See [loops as
expressions](https://www.ziglang.in/learn/language-basics/loops-as-expressions/) and [labelled
loops](https://www.ziglang.in/learn/language-basics/labelled-loops/).

`inline for` unrolls the loop at compile time and makes the capture
comptime-known. That is what lets a loop walk the fields of a struct or the
tags of an enum. That is a different tool with a different purpose, covered in
[inline loops](https://www.ziglang.in/learn/language-basics/inline-loops/).
