# For Loops

> Iterate over sequences and ranges, never over a bare counter.

In Zig, `for` loops over a slice, an array or a range. To get the index, add a second sequence to the loop: `for (items, 0..) |item, index|`.

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
    // A `for` over many sequences needs equal lengths. Zig checks the lengths.
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

Zig has no `for` with three clauses, such as `for (i = 0; i < n; i++)`. Use `while` for that. The `for` loop gets its length from the sequence. Thus you never write the bound yourself, and the common case cannot have an off-by-one error.

## You get an index only when you ask

```zig
for (items, 0..) |item, index| { ... }
```

The `0..` is not special syntax. It is a second sequence, and the loop moves through the two sequences in step. You get an index only when you ask for one. The loop still cannot go past the end, because the length of `items` sets the number of iterations.

## Iterate over several sequences together

The same mechanism pairs any number of sequences:

```zig
for (names, scores) |name, score| { ... }
```

The lengths must be equal. When the compiler knows the two lengths, a difference is a compile error, and the error gives the lengths:

```
error: non-matching for loop lengths
note: length 3 here
note: length 2 here
```

When the sequences are runtime slices, a safety check finds the difference. The check panics in Debug and ReleaseSafe. In the two cases, the loop does not read past the end of the shorter sequence. A loop with an index can easily make that mistake.

A range with no upper bound can pair with each sequence. `0..` gets its length from the sequences next to it. A bare `for (0..)` with no other sequence is a compile error, because nothing tells the loop when to stop.

## Change the elements in place

A capture by value gives you a copy. To change the elements in the array, iterate over a pointer to the array, and capture by pointer:

```zig
for (&numbers) |*n| n.* *= 2;
```

The two parts are necessary:

- `&numbers` makes the loop use the original array, not a copy of the array.
- `|*n|` makes each capture a pointer into the array.

If you remove one of the two parts, the loop compiles but does nothing useful.

For a slice, the `&` is not necessary. A slice already refers to memory that it does not own. Thus `for (slice) |*item|` writes to the elements of that memory.

## Iterate backwards

Zig has no reverse range and no step. To count down, use a `while`:

```zig
var i = items.len;
while (i > 0) {
    i -= 1;
    use(items[i]);
}
```

The decrement comes first for a reason. `items.len` is a `usize`. A loop with `while (i >= 0) : (i -= 1)` never stops, because an unsigned counter cannot go below zero. In a safety build, the loop panics on the wraparound instead, thus you see the problem.

Zig accepts this cost on purpose. The forward loop cannot make this mistake. When you iterate backwards, you must control the index yourself again.

## `for` can also break and give a value

`break`, `continue`, labels and `else` work here exactly as they work on `while`. A `for` that you use as an expression gives a value with `break x`. It needs an `else` for the case where no elements remain. Thus a linear search is a single expression.

See [loops as expressions](https://www.ziglang.in/learn/language-basics/loops-as-expressions/) and [labelled loops](https://www.ziglang.in/learn/language-basics/labelled-loops/).

`inline for` unrolls the loop at compile time, and the compiler knows the capture at comptime. Thus a loop can visit the fields of a struct or the tags of an enum. `inline for` is a different tool with a different purpose. [Inline loops](https://www.ziglang.in/learn/language-basics/inline-loops/) explains it.
