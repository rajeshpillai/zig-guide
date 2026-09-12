# MultiArrayList

> Struct of arrays, laid out for the cache.

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

    // items(.hp) is a real []u32: every hp value, contiguous in memory.
    // A loop that only touches hp never loads x or y into cache.
    var total: u32 = 0;
    for (monsters.items(.hp)) |hp| total += hp;
    try expect(total == 75);
}

test "get and set reassemble the struct" {
    const gpa = std.testing.allocator;

    var monsters: std.MultiArrayList(Monster) = .empty;
    defer monsters.deinit(gpa);
    try monsters.append(gpa, .{ .hp = 10, .x = 1.0, .y = 2.0 });

    const m = monsters.get(0); // gathers one element from all three arrays
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

    // The slice is live storage, not a copy.
    for (monsters.items(.hp)) |*hp| hp.* += 5;
    try expect(monsters.get(0).hp == 15);
    try expect(monsters.get(1).hp == 25);
}

test "cache the slice when touching several fields" {
    const gpa = std.testing.allocator;

    var monsters: std.MultiArrayList(Monster) = .empty;
    defer monsters.deinit(gpa);
    try monsters.append(gpa, .{ .hp = 1, .x = 3.0, .y = 4.0 });

    // Each items() call recomputes field pointers; slice() does it once.
    const s = monsters.slice();
    const xs = s.items(.x);
    const ys = s.items(.y);
    try expect(xs[0] * xs[0] + ys[0] * ys[0] == 25.0);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.multi-array-list`)*

## Same API, transposed storage

`MultiArrayList(T)` holds the same elements an `ArrayList(T)` would, but stores
each field of `T` in its own contiguous array. Ten monsters with `hp`, `x`,
and `y` become three arrays of ten, not ten structs side by side. You still
`append` whole structs and `get` whole structs back; the transpose is
invisible until you ask for one field.

The two layouts have names worth knowing, because the literature uses them.
`ArrayList` is an array of structs, "AoS". `MultiArrayList` is a struct of
arrays, "SoA". The data is identical; only the order the bytes sit in memory
differs.

## Why bother

`items(.hp)` hands you a real `[]u32`: every hp value packed together. A loop
that sums hp touches only that array, so the CPU loads no `x` or `y` bytes it
will not use. When one field is hot and the struct is wide, this is the
difference between streaming exactly the bytes you need and dragging the whole
struct through cache. It is also what makes bulk field updates vectorize.

The number that makes it concrete is the cache line: memory arrives from RAM in
64-byte blocks whether you wanted 64 bytes or 4. Summing one `u32` field of a
64-byte struct in AoS layout fetches 64 bytes to use 4, so fifteen sixteenths of
the memory bandwidth is wasted. In SoA layout the same loop uses every byte it
fetches. On a large array that is the entire difference, and no amount of
optimising the loop body recovers it.

A second win comes free: the field arrays are separately typed and densely
packed, so `@Vector` operations and the auto-vectoriser can work on them. A
loop over a field of a struct array cannot vectorise because the values are not
adjacent.

## The costs

`get` and `set` gather or scatter across the separate arrays, so touching a
whole element is slightly more work than with a plain `ArrayList`. Reach for
`MultiArrayList` when you iterate columns far more than you handle whole rows.

When several fields are needed in one pass, call `slice()` once and pull each
`items(.field)` from it. Each bare `items()` call recomputes the field
pointers; `slice()` does that work a single time. As with every list here,
those slices are invalidated by the next append.

The other cost is readability, and it is not nothing. Field access becomes
`s.items(.hp)[i]` rather than `list.items[i].hp`, and code that mostly deals in
whole entities reads worse for no gain. This is a layout decision to make
deliberately, on a measurement, for the small number of arrays in a program that
are actually large and actually hot.

It also only works on structs whose fields are known: `MultiArrayList` uses the
same comptime reflection everything else here does, walking the field list of
`T` to generate the arrays. That is why `.hp` is checked at compile time and a
typo is a build error rather than a runtime lookup.

## Where it shows up

Anywhere the array is large and the access pattern is columnar. Game entity
systems are the canonical example, which is where the term "SoA" comes from.
Compilers are another: Zig's own compiler stores its abstract syntax tree this
way, because the passes over it walk one field of every node at a time.

If you are storing thousands of small records and iterating them field by field,
this is the container. If you are storing a few dozen of anything, use an
`ArrayList` and spend the attention elsewhere.
