//! title: MultiArrayList
//! One list, stored as a separate contiguous array per field.

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
