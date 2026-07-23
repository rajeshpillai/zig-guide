//! title: Sorting
//! In-place sorts with an explicit comparator.

const std = @import("std");
const expect = std.testing.expect;

const Person = struct {
    name: []const u8,
    age: u8,
};

fn byAge(_: void, a: Person, b: Person) bool {
    return a.age < b.age;
}

test "sort numbers" {
    var numbers = [_]u8{ 5, 3, 9, 1 };
    std.mem.sort(u8, &numbers, {}, std.sort.asc(u8));
    try expect(numbers[0] == 1 and numbers[3] == 9);

    std.mem.sort(u8, &numbers, {}, std.sort.desc(u8));
    try expect(numbers[0] == 9);
}

test "sort structs with a custom comparator" {
    var people = [_]Person{
        .{ .name = "c", .age = 30 },
        .{ .name = "a", .age = 10 },
        .{ .name = "b", .age = 20 },
    };
    // The `{}` is the context argument: a value passed to every comparison,
    // useful when the ordering depends on something external.
    std.mem.sort(Person, &people, {}, byAge);
    try expect(people[0].age == 10);
}

test "sort strings lexicographically" {
    var words = [_][]const u8{ "pear", "apple", "fig" };
    std.mem.sort([]const u8, &words, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    try expect(std.mem.eql(u8, words[0], "apple"));
}

test "binary search a sorted slice" {
    const sorted = [_]u8{ 1, 3, 5, 7, 9 };
    const index = std.sort.binarySearch(u8, &sorted, @as(u8, 7), struct {
        fn order(key: u8, item: u8) std.math.Order {
            return std.math.order(key, item);
        }
    }.order);
    try expect(index.? == 3);
}

test "sort is not stable; sortUnstable is faster" {
    var numbers = [_]u8{ 4, 2, 6 };
    // `std.mem.sort` is stable. When equal elements are interchangeable,
    // `sortUnstable` avoids the extra work.
    std.mem.sortUnstable(u8, &numbers, {}, std.sort.asc(u8));
    try expect(numbers[0] == 2);
}
