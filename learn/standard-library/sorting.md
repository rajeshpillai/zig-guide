# Sorting

> In-place sorts with a comparator that you supply.

In Zig, `std.mem.sort` sorts a slice in place. The sort is stable, and it uses a less-than function that you supply. `std.mem.sortUnstable` is not stable, but it does less work.

```zig
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
    // The `{}` is the context argument. The sort gives this value to each
    // comparison. It is useful when the order depends on external data.
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

test "sortUnstable is not stable, and it does less work" {
    var numbers = [_]u8{ 4, 2, 6 };
    // `std.mem.sort` is stable. When equal elements are interchangeable,
    // `sortUnstable` does not do the extra work.
    std.mem.sortUnstable(u8, &numbers, {}, std.sort.asc(u8));
    try expect(numbers[0] == 2);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.sorting`)*

```zig
std.mem.sort(T, slice, context, lessThanFn);
```

For simple orders, the standard library supplies the comparator: `std.sort.asc(T)` and `std.sort.desc(T)`.

The sort is in place and needs no allocator. Thus it takes a slice and not a list, because it changes the order of the elements that are already there. To sort the contents of an `ArrayList`, sort `list.items`.

## The context argument

The sort gives the third parameter to each comparison. The parameter is `{}` (the void value) when the order depends only on the elements. The parameter is useful when the comparison needs external data. An example is a sort of indices by the values that they point at:

```zig
std.mem.sort(usize, &indices, values, byReferencedValue);
```

With the context parameter, you do not need a global variable.

The pattern has more uses than you can see at first. Sort an array of indices, and not the data. Then you get several orders of one dataset, and you do not copy the data. You can also use it to sort data that is too large to move cheaply. The context is the data that the comparator needs for its work.

## Stable or not

| Function | Stable | Notes |
| --- | --- | --- |
| `std.mem.sort` | yes | equal elements keep their relative order |
| `std.mem.sortUnstable` | no | less work; prefer when elements are interchangeable |

Stability is important when you sort by one key after an earlier sort by a different key. For equal elements, stability keeps the earlier order.

A sort by more than one key uses this property. Sort by the least significant key first, then by the most significant key. Stability keeps the result of the earlier sort in each group.

For example, sort by name, then by department. The entries of each department are still in name order. If you do the same with `sortUnstable`, the second sort destroys the order from the first sort.

Sometimes elements are fully interchangeable, for example plain integers. Then you cannot see the effect of stability. In that case `sortUnstable` is the better choice, because it does less work and uses no extra memory.

## Comparators as anonymous structs

Zig has no closures. Thus a comparator that you use one time is usually a struct literal with a function in it:

```zig
std.mem.sort([]const u8, &words, {}, struct {
    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
}.lessThan);
```

`std.mem.order` returns `.lt`, `.eq` or `.gt`. `std.sort.binarySearch` also uses this type of result.

The comparator must be a strict "less than". If it returns true for equal elements, it breaks the order that the algorithm expects. Then the result is not only in an incorrect order. In an unchecked build, the sort can read out of bounds.

To compare on several fields, compare the first field. Compare the second field only when the first fields are equal.

## Search a sorted slice

`std.sort.binarySearch` finds an element in a slice that is already sorted. It takes a three-way comparison and not a less-than, because it must know which half to keep. `std.sort.isSorted` checks the invariant. It is a cheap assertion to put in a test.

Two related functions help when you do not need all the elements in order:

- `std.sort.lowerBound` and `upperBound` find insertion points. A query such as "how many are below this threshold" needs these functions.
- When you need only the few largest elements, a full sort is the wrong algorithm. A [priority queue](https://www.ziglang.in/learn/standard-library/priority-queue/) keeps the top *k* and does not touch the other elements.
