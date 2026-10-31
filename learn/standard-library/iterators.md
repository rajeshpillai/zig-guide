# Iterators

> A convention, not an interface.

The iterators in the Zig standard library are plain structs with a `next` method. Examples are `std.mem.splitScalar`, `std.mem.tokenizeAny` and `std.mem.window`. They give slices of the original bytes, and they do not allocate.

```zig
const std = @import("std");
const expect = std.testing.expect;

// Zig has no Iterator trait. A type is iterable if it has a `next()` that
// returns an optional, because `while (it.next()) |x|` needs exactly that.
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
    // If advance < size, the windows overlap.
    var windows = std.mem.window(u8, "abcd", 2, 1);
    try expect(std.mem.eql(u8, windows.next().?, "ab"));
    try expect(std.mem.eql(u8, windows.next().?, "bc"));

    // If advance == size, the blocks do not overlap. There is no std.mem.chunk.
    var blocks = std.mem.window(u8, "abcd", 2, 2);
    try expect(std.mem.eql(u8, blocks.next().?, "ab"));
    try expect(std.mem.eql(u8, blocks.next().?, "cd"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.iterators`)*

Zig has no `Iterator` trait, no `IntoIterator`, and no iterator protocol to implement. A type is iterable if it has a `next()` method that returns an optional. This loop needs exactly that method:

```zig
while (it.next()) |value| { ... }
```

To write your own iterator, make a struct with state and a `next` method.

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

Nothing registers the struct, and the struct implements nothing. `while (c.next()) |v|` works because the shapes match. The convention is the interface, and the compiler checks the convention when you use it.

An iterator is an ordinary struct, and this fact has two results:

- An iterator must be `var`, because `next` changes the state. If a function must advance the iterator, give the function a pointer.
- After one iteration, the iterator has no more values. To iterate a second time, make the iterator again.

## Split text

| Function | Behaviour |
| --- | --- |
| `splitScalar(u8, s, ',')` | splits on one byte, **keeps** empty fields |
| `splitAny(u8, s, ",;")` | splits on any of several bytes |
| `splitSequence(u8, s, "::")` | splits on a separator of more than one byte |
| `tokenizeScalar(u8, s, ',')` | same, but **skips** empty fields |
| `tokenizeAny(u8, s, " \t")` | skips empty fields, any of several separators |

Remember the difference between split and tokenize:

- To parse CSV, use `split`. An empty field has a meaning.
- To split on whitespace, use `tokenize`. A series of spaces must not make empty tokens.

All of these functions give slices of the original string. They copy nothing and they allocate nothing. Thus a split of a megabyte of text costs no memory, and the parts stay valid while the original is valid. The usual problem also applies: if the program frees the source, each part that you kept is dangling.

Three more methods are available:

- `peek()` gets the next value, but does not consume it.
- `rest()` gives you all of the text that the iterator did not return. Use it when you parse a header field by field and the rest of the text is a body.
- `reset()` starts again from the beginning.

## Windows

`std.mem.window(T, s, size, advance)` gives views into the original bytes, and it copies nothing. Code that works on n-grams or on blocks needs this shape. You control the overlap:

- If `advance` is smaller than `size`, the windows overlap.
- If `advance` is equal to `size`, the windows do not overlap.

On master, there is no `std.mem.chunk`. For blocks that do not overlap, use `window(T,
s, n, n)`.

When the length is not a multiple of the window size, the last window is short. The function does not pad the last window, and it does not discard it. Thus code that expects a full window each time must check the length.

## No lazy adapter chains

Zig has no `.map().filter().take()`. Write the loop. The loop is usually shorter than the chain, and its cost is clear.

Zig has no chains because Zig has no closures. A `map` must take a function pointer and a context struct. That is three lines of setup for a task that one line in a loop body does directly. Chains are easy to read in languages where a lambda captures its environment automatically.

But the loss is real. You can write a chain of transformations over a large collection one time, and it reads the data in one pass. Careless nested loops make intermediate arrays. In Zig, write one loop that does all the steps for each element. In those other languages, the chain also compiles to this loop.
