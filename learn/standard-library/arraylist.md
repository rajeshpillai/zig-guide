# ArrayList

> The array that can grow, now unmanaged.

`std.ArrayList` is the array in Zig that can grow. On master, an `ArrayList` holds no allocator. Create the list with `.empty`. Then give the allocator to each method that can allocate, as in `list.append(gpa, x)`.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "build up a list" {
    const gpa = std.testing.allocator;

    // `.empty` replaces `init(allocator)`. The list does not store the
    // allocator. Thus each method that can allocate takes an allocator.
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

    // `.items` is a `[]T` into the buffer of the list. It is valid until
    // the next reallocation. Thus do not keep it across an append.
    try expect(list.items[4] == 16);
}

test "pop and remove" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try list.appendSlice(gpa, "abcd");
    try expect(list.pop().? == 'd');
    _ = list.orderedRemove(0); // moves the other items down
    try expect(std.mem.eql(u8, list.items, "bc"));
}

test "preallocate when the size is known" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    // One allocation, not a series of growth steps.
    try list.ensureTotalCapacity(gpa, 100);
    for (0..100) |_| list.appendAssumeCapacity('x');
    try expect(list.items.len == 100);
}

test "take ownership of the buffer" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(gpa, "owned");

    // `toOwnedSlice` gives you the memory and makes the list empty. Thus
    // the caller frees the slice, and does not call deinit on the list.
    const slice = try list.toOwnedSlice(gpa);
    defer gpa.free(slice);
    try expect(std.mem.eql(u8, slice, "owned"));
}

test "lock the buffer in place while holding a pointer into it" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);

    try list.appendSlice(gpa, &.{ 1, 2, 3 });

    // Between these two calls, the buffer must not move. Thus a pointer into
    // the buffer stays valid. In a safety build, an operation that
    // reallocates panics. It does not make `first` invalid without a report.
    list.lockPointers();
    const first = &list.items[0];
    first.* += 10;
    list.unlockPointers();

    try expect(list.items[0] == 11);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.arraylist`)*

## The list is unmanaged now

Of all the changes, this change most often breaks code that you find online. In the past, `std.ArrayList` stored its allocator:

```zig
var list = std.ArrayList(u8).init(allocator);   // old
defer list.deinit();
try list.append('a');
```

On master, `ArrayList` **is** the unmanaged variant. It holds no allocator. Thus you give an allocator to each method that can allocate:

```zig
var list: std.ArrayList(u8) = .empty;           // current
defer list.deinit(gpa);
try list.append(gpa, 'a');
```

You type more, but the allocator is visible at each call site that can fail. Also, the struct is two words smaller.

The second reason for the change is visible at scale. A program with ten thousand small lists stored ten thousand copies of the same allocator pointer and vtable. Now the program stores no copies. A struct with several list fields does not keep one allocator for each field.

`.empty` is a declaration on the type. Thus `var list: std.ArrayList(u8) =
.empty;` works by inference. If you know approximately how many items will come, use `try .initCapacity(gpa, n)`. It allocates one time at the start.

## The parts of a list

A list has an `items` slice, a `capacity`, and a safety field. A later section tells you about the safety field. Outside a safety build, the safety field costs nothing.

Thus a list is three words: a pointer, a length, and the number of elements that the buffer can hold before it must grow. An append past the capacity allocates a larger buffer, copies the elements, and frees the old buffer. For this reason, append returns an error, and growth has an amortised cost.

## `.items` is a borrowed slice

`list.items` points into the buffer of the list. An append can reallocate the buffer, and then each slice that you hold is not valid. Get `.items` when you need it. Do not keep it across changes to the list.

If you do nothing, no check finds this error. The old slice still has a valid pointer and a valid length, but it points into freed memory. It reads data that looks correct, or the program crashes. The result depends on what the allocator did next.

The same rule applies to a pointer to an element. After an append that grows the list, `&list.items[0]` is not valid.

The usual example is a loop that appends to the list that it iterates over. Collect the new items into a second list. Then append them after the loop.

## Lock the buffer in place

`lockPointers` and `unlockPointers` mark a region where the buffer must not move. Inside the region, an operation that reallocates or frees the buffer panics. Thus the operation does not make a pointer that you hold invalid:

```zig
list.lockPointers();
const first = &list.items[0];
first.* += 10;
list.unlockPointers();
```

The panic occurs when the buffer moves, not when you call the method. An `append` that fits in the current capacity moves nothing, and it passes. The same `append` panics on the iteration that must grow the buffer. Some methods always make pointers invalid, for example `insert`, `swapRemove` and `toOwnedSlice`. These methods assert directly.

The field behind the lock is a `std.debug.SafetyLock`. Outside a safety build, it checks nothing. Debug and ReleaseSafe have the check. ReleaseFast and ReleaseSmall do not have it. The wasm behind the Run button on this page is ReleaseSmall.

## Allocate the capacity first when possible

Call `ensureTotalCapacity`, then call `appendAssumeCapacity`. This sequence makes one allocation and not a series of growth steps. The `AssumeCapacity` calls cannot fail, thus they need no `try`.

Speed is not the only reason. A loop of `try list.append(...)` has an error path on each iteration. Some code must not fail in the middle. In that code, reserve the space first. Then the full loop either occurs completely or does not occur.

In a safety build, `appendAssumeCapacity` panics if your capacity was wrong. Thus the safety build checks the assumption in the place where the assumption matters.

## Give the ownership to the caller

`toOwnedSlice(gpa)` gives you the buffer and makes the list empty. Then the caller frees the slice, and the list needs no `deinit`.

This is the idiomatic way to make a value of unknown size and return it. Use the list while the data grows. When the data is complete, return a plain `[]T`. The returned slice has the same length as the data, thus the caller does not keep the spare capacity of the list.

The opposite operation is `fromOwnedSlice`. It adopts a slice that you already have, and then the slice can continue to grow.

## When to use a different container

- If you remove elements from the front, a list costs O(n) for each removal. A [queue](https://www.ziglang.in/learn/concurrency/queues/) does not.
- If you find values by a key and not by a position, use a [hash map](https://www.ziglang.in/learn/standard-library/hash-maps/).
- If each element is a large struct and you usually use one field at a time, use a [MultiArrayList](https://www.ziglang.in/learn/standard-library/multi-array-list/). It stores each field in a separate array, and it reads far fewer cache lines.
