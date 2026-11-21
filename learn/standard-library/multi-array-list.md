# MultiArrayList

> A struct of arrays, with a memory layout that helps the cache.

`std.MultiArrayList(T)` is the struct-of-arrays container in Zig. Like an `ArrayList(T)`, it takes full structs through `append`. The call `items(.field)` returns one field of all the elements as a separate slice.

```zig
const std = @import("std");
const expect = std.testing.expect;

const Monster = struct {
    hp: u32,
    x: f32,
    y: f32,
};

test "append structs, read fields as plain slices" {
    const gpa = std.testing.allocator;

    var monsters: std.MultiArrayList(Monster) = .empty;
    defer monsters.deinit(gpa);

    try monsters.append(gpa, .{ .hp = 10, .x = 1.0, .y = 2.0 });
    try monsters.append(gpa, .{ .hp = 25, .x = 3.0, .y = 4.0 });
    try monsters.append(gpa, .{ .hp = 40, .x = 5.0, .y = 6.0 });

    // items(.hp) is a real []u32. All the hp values are next to each other
    // in memory. A loop that uses only hp does not load x or y into the cache.
    var total: u32 = 0;
    for (monsters.items(.hp)) |hp| total += hp;
    try expect(total == 75);
}

test "get and set reassemble the struct" {
    const gpa = std.testing.allocator;

    var monsters: std.MultiArrayList(Monster) = .empty;
    defer monsters.deinit(gpa);
    try monsters.append(gpa, .{ .hp = 10, .x = 1.0, .y = 2.0 });

    const m = monsters.get(0); // collects one element from the three arrays
    try expect(m.hp == 10 and m.x == 1.0);

    monsters.set(0, .{ .hp = 99, .x = 0.0, .y = 0.0 });
    try expect(monsters.items(.hp)[0] == 99);
}

test "mutate one column in place" {
    const gpa = std.testing.allocator;

    var monsters: std.MultiArrayList(Monster) = .empty;
    defer monsters.deinit(gpa);
    try monsters.append(gpa, .{ .hp = 10, .x = 0, .y = 0 });
    try monsters.append(gpa, .{ .hp = 20, .x = 0, .y = 0 });

    // The slice is the real storage. It is not a copy.
    for (monsters.items(.hp)) |*hp| hp.* += 5;
    try expect(monsters.get(0).hp == 15);
    try expect(monsters.get(1).hp == 25);
}

test "cache the slice when touching several fields" {
    const gpa = std.testing.allocator;

    var monsters: std.MultiArrayList(Monster) = .empty;
    defer monsters.deinit(gpa);
    try monsters.append(gpa, .{ .hp = 1, .x = 3.0, .y = 4.0 });

    // Each items() call calculates the field pointers again. slice() does
    // that work one time.
    const s = monsters.slice();
    const xs = s.items(.x);
    const ys = s.items(.y);
    try expect(xs[0] * xs[0] + ys[0] * ys[0] == 25.0);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.multi-array-list`)*

## The same API with a different storage

Ten monsters with `hp`, `x` and `y` become three arrays of ten values. They do not become ten structs next to each other. `get` still gives you full structs. You see the separate arrays only when you ask for one field.

The two layouts have names, and books and papers use these names:

- `ArrayList` is an array of structs, "AoS".
- `MultiArrayList` is a struct of arrays, "SoA".

The data is the same in the two layouts. Only the order of the bytes in memory is different.

## Why use it

`items(.hp)` gives you a real `[]u32`, with all the hp values next to each other. A loop that adds the hp values reads only that array. Thus the CPU loads no `x` or `y` bytes that it does not use.

When a program uses one field frequently and the struct is wide, this loop reads only the bytes that it needs. It does not move the full struct through the cache. This layout also lets the compiler vectorize changes to one field of all the elements.

The cache line gives the numbers. Memory comes from RAM in 64-byte blocks. The block size is the same when you need 64 bytes and when you need only 4. Take a 64-byte struct in AoS layout, and a loop that adds one `u32` field. The loop gets 64 bytes to use 4 bytes, thus fifteen sixteenths of the memory bandwidth is lost.

In SoA layout, the same loop uses all the bytes that it gets. On a large array, the layout causes all of the difference. Optimisation of the loop body cannot recover that difference.

The layout has a second benefit. Each field array has one type, and its values are next to each other. Thus `@Vector` operations and the auto-vectoriser can operate on them. A loop over one field of an array of structs cannot vectorise, because the values are not adjacent.

## The costs

`get` and `set` collect or distribute the values across the separate arrays. Thus an operation on a full element is slightly more work than with a plain `ArrayList`. Use `MultiArrayList` when you iterate over columns much more frequently than you use full rows.

When a loop needs several fields, call `slice()` one time and get each `items(.field)` from the result. Each separate `items()` call calculates the field pointers again. `slice()` does that work one time. As with each list in this guide, the next append makes those slices invalid.

The other cost is readability, and that cost is real. Field access becomes `s.items(.hp)[i]` and not `list.items[i].hp`. Code that usually works with full entities becomes more difficult to read, and it gets no benefit. Select this layout after you measure. Use it only for the few arrays in a program that are both large and frequently used.

`MultiArrayList` also works only on structs with known fields. It uses the same comptime reflection as the other containers in this guide. It walks the field list of `T` and makes the arrays from that list. Thus the compiler checks `.hp` at compile time. A typo is a build error, and not a lookup at runtime.

## Where programs use it

Programs use it where the array is large and the code reads it one column at a time. Game entity systems are the usual example, and the term "SoA" comes from them.

Compilers are another example. The Zig compiler stores its abstract syntax tree in this layout, because each pass over the tree walks one field of all the nodes.

If you store thousands of small records and iterate over them one field at a time, use this container. If you store a few dozen items, use an `ArrayList` and put your attention on other parts of the program.
