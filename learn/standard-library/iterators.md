# Iterators

> A convention, not an interface.

```zig
const std = @import("std");
const expect = std.testing.expect;

// Zig has no Iterator trait. A type is iterable if it has `next()` returning
// an optional, because that is what `while (it.next()) |x|` needs.
const Countdown = struct {
    remaining: u32,

    pub fn next(self: *Countdown) ?u32 {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return self.remaining;
    }
};

test "write your own iterator" {
    var it = Countdown{ .remaining = 3 };
    var sum: u32 = 0;
    while (it.next()) |value| sum += value;
    try expect(sum == 3); // 2 + 1 + 0
}

test "split on a single byte" {
    var it = std.mem.splitScalar(u8, "a,b,c", ',');
    try expect(std.mem.eql(u8, it.next().?, "a"));
    try expect(std.mem.eql(u8, it.next().?, "b"));
    try expect(std.mem.eql(u8, it.next().?, "c"));
    try expect(it.next() == null);
}

test "split keeps empty fields, tokenize does not" {
    var split = std.mem.splitScalar(u8, "a,,b", ',');
    var split_count: u32 = 0;
    while (split.next()) |_| split_count += 1;
    try expect(split_count == 3); // "a", "", "b"

    var tokens = std.mem.tokenizeScalar(u8, "a,,b", ',');
    var token_count: u32 = 0;
    while (tokens.next()) |_| token_count += 1;
    try expect(token_count == 2); // "a", "b"
}

test "tokenize on any of several separators" {
    var it = std.mem.tokenizeAny(u8, "one two\tthree", " \t");
    try expect(std.mem.eql(u8, it.next().?, "one"));
    try expect(std.mem.eql(u8, it.next().?, "two"));
    try expect(std.mem.eql(u8, it.next().?, "three"));
}

test "window a slice, overlapping or not" {
    // advance < size overlaps.
    var windows = std.mem.window(u8, "abcd", 2, 1);
    try expect(std.mem.eql(u8, windows.next().?, "ab"));
    try expect(std.mem.eql(u8, windows.next().?, "bc"));

    // advance == size gives non-overlapping blocks. There is no std.mem.chunk.
    var blocks = std.mem.window(u8, "abcd", 2, 2);
    try expect(std.mem.eql(u8, blocks.next().?, "ab"));
    try expect(std.mem.eql(u8, blocks.next().?, "cd"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.iterators`)*

Zig has no `Iterator` trait, no `IntoIterator`, no iterator protocol to
implement. A type is iterable if it has a `next()` method returning an
optional, because that is exactly what this loop needs:

```zig
while (it.next()) |value| { ... }
```

Writing your own is a struct with state and a `next`. That is the whole
mechanism.

```zig
const Countdown = struct {
    n: u32,
    fn next(self: *Countdown) ?u32 {
        if (self.n == 0) return null;
        self.n -= 1;
        return self.n + 1;
    }
};
```

Nothing registers it, nothing implements anything, and `while (c.next()) |v|`
works because the shapes line up. The convention is the interface, and the
compiler checks it the moment you use it.

Two things follow from iterators being ordinary structs. They have to be
`var`, because `next` mutates the state, and passing one to a function means
passing a pointer if the function should advance it. Iterating the same
iterator twice means constructing it twice, since it has been consumed.

## Splitting text

| Function | Behaviour |
| --- | --- |
| `splitScalar(u8, s, ',')` | split on one byte, **keeps** empty fields |
| `splitAny(u8, s, ",;")` | split on any of several bytes |
| `splitSequence(u8, s, "::")` | split on a multi-byte separator |
| `tokenizeScalar(u8, s, ',')` | same, but **skips** empty fields |
| `tokenizeAny(u8, s, " \t")` | skip empties, any of several separators |

The split/tokenize distinction is the one to remember: parsing CSV wants
`split` (an empty field is meaningful); splitting on whitespace wants
`tokenize` (runs of spaces should not produce empty tokens).

All of them yield slices of the original string. Nothing is copied and nothing
is allocated, so splitting a megabyte of text costs no memory and the pieces
stay valid as long as the original does. The flip side is the usual one: if
the source is freed, every piece you kept is dangling.

`peek()` looks at the next value without consuming it. `rest()` gives you
everything not yet returned, which is what you want when a header is parsed
field by field and the remainder is a body. `reset()` starts over.

## Windows

`std.mem.window(T, s, size, advance)` yields views into the original bytes
with no copying, which is what n-gram and block processing want. Overlap is up
to you: `advance` smaller than `size` overlaps, `advance` equal to `size` does
not.

There is no `std.mem.chunk` on master. Non-overlapping blocks are `window(T,
s, n, n)`.

The final window is short when the length does not divide evenly, rather than
being padded or dropped, so code that assumes every window is full size needs
to check.

## No lazy adapter chains

There is no `.map().filter().take()`. Write the loop: it is usually shorter
than the chain, and there is nothing hidden about its cost.

The reason it is absent rather than missing is that Zig has no closures. A
`map` would have to take a function pointer plus a context struct, which is
three lines of ceremony to express what one line of loop body says directly.
The languages where chains read well are the ones where a lambda captures its
environment for free.

What you lose is real. A chain of transformations over a large collection can
be expressed once and read in one pass, whereas nested loops build up
intermediate arrays if written carelessly. The Zig answer is to write the one
loop that does all the steps per element, which is also what the chain
compiles to in those other languages.
