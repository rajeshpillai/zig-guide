# ArrayList

> The growable array, now unmanaged.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "build up a list" {
    const gpa = std.testing.allocator;

    // `.empty` replaces `init(allocator)`. The list does not store the
    // allocator, so every method that may allocate takes one.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try list.append(gpa, 'h');
    try list.appendSlice(gpa, "ello");

    try expect(std.mem.eql(u8, list.items, "hello"));
    try expect(list.items.len == 5);
}

test "items is a plain slice" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);

    for (0..5) |i| try list.append(gpa, @intCast(i * i));

    // `.items` is a `[]T` into the list's buffer, valid until the next
    // reallocation, so do not hold it across an append.
    try expect(list.items[4] == 16);
}

test "pop and remove" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try list.appendSlice(gpa, "abcd");
    try expect(list.pop().? == 'd');
    _ = list.orderedRemove(0); // shifts the rest down
    try expect(std.mem.eql(u8, list.items, "bc"));
}

test "preallocate when the size is known" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    // One allocation instead of a growth sequence.
    try list.ensureTotalCapacity(gpa, 100);
    for (0..100) |_| list.appendAssumeCapacity('x');
    try expect(list.items.len == 100);
}

test "take ownership of the buffer" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(gpa, "owned");

    // `toOwnedSlice` hands you the memory and empties the list, so the
    // caller frees the slice rather than deinit-ing the list.
    const slice = try list.toOwnedSlice(gpa);
    defer gpa.free(slice);
    try expect(std.mem.eql(u8, slice, "owned"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.arraylist`)*

## It is unmanaged now

This is the change most likely to break code you find online. `std.ArrayList`
used to store its allocator:

```zig
var list = std.ArrayList(u8).init(allocator);   // old
defer list.deinit();
try list.append('a');
```

On master, `ArrayList` **is** the unmanaged variant. It holds no allocator, so
you supply one to every method that might allocate:

```zig
var list: std.ArrayList(u8) = .empty;           // current
defer list.deinit(gpa);
try list.append(gpa, 'a');
```

More typing, but the allocator is visible at every call site that can fail,
and the struct is two words smaller.

The second reason for the change matters more at scale: a program holding ten
thousand small lists was storing ten thousand copies of the same allocator
pointer and vtable. Now it stores none, and a struct with several list fields
does not carry the allocator once per field.

`.empty` is a declaration on the type, so `var list: std.ArrayList(u8) =
.empty;` works by inference. When you already know roughly how many items are
coming, `try .initCapacity(gpa, n)` allocates once up front.

## What it actually is

Three fields: a pointer, a length, and a capacity. `items` is the slice of the
first `len` elements, and `capacity` is how many the buffer could hold before
it has to grow. Appending past the capacity allocates a larger buffer, copies,
and frees the old one, which is why append returns an error and why the growth
is amortised rather than free.

## `.items` is a borrowed slice

`list.items` points into the list's buffer. Appending may reallocate, which
invalidates any slice you were holding. Take `.items` when you need it; do not
stash it across mutations.

This is the bug to internalise, because nothing catches it. The old slice is
still a valid pointer and a valid length; it just points into memory that has
been freed. It reads plausible data or crashes, depending on what the
allocator did next. The same applies to a pointer to an element:
`&list.items[0]` is invalid after any append that grows.

Iterating while appending is the common instance. Collect what you want to add
into a second list, then append it after the loop.

## Preallocate when you can

`ensureTotalCapacity` followed by `appendAssumeCapacity` turns a growth
sequence into one allocation, and the `AssumeCapacity` calls cannot fail, so
they need no `try`.

Which is not only a speed argument. A loop of `try list.append(...)` has an
error path on every iteration. In code that must not fail partway through,
reserving the space first turns the whole loop into an operation that either
happens or does not. `appendAssumeCapacity` panics in a safety build if you
were wrong about the capacity, so the assumption is checked where it matters.

## Handing off ownership

`toOwnedSlice(gpa)` gives you the buffer and leaves the list empty. The caller
now frees the slice, and the list needs no `deinit`.

This is the idiomatic way to build something of unknown size and return it:
use the list while you are growing, hand back a plain `[]T` when you are done.
The returned slice is trimmed to the length, so the caller is not carrying the
list's spare capacity around.

The mirror operation is `fromOwnedSlice`, which adopts a slice you already
have so it can keep growing.

## When it is the wrong container

When elements are removed from the front, a list is O(n) per removal and a
[queue](https://www.ziglang.in/learn/standard-library/queues/) is not. When lookup is by key rather
than by position, use a [hash map](https://www.ziglang.in/learn/standard-library/hash-maps/). When
the element is a large struct and you mostly touch one field at a time, use a
[MultiArrayList](https://www.ziglang.in/learn/standard-library/multi-array-list/). It stores each
field in its own array and reads far fewer cache lines.
