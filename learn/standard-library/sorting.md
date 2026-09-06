# Sorting

> In-place sorts with an explicit comparator.

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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.sorting`)*

```zig
std.mem.sort(T, slice, context, lessThanFn);
```

For simple orderings the comparator is provided: `std.sort.asc(T)` and
`std.sort.desc(T)`.

The sort is in place and needs no allocator, which is why it takes a slice
rather than a list: it rearranges what is already there. Sorting the contents
of an `ArrayList` means sorting `list.items`.

## The context argument

That third parameter is passed to every comparison. It is `{}` (the void
value) when the ordering depends only on the elements. It becomes useful when
the comparison needs something external, such as sorting indices by the values
they point at:

```zig
std.mem.sort(usize, &indices, values, byReferencedValue);
```

That is what saves you from reaching for a global.

The pattern generalises further than it first looks. Sorting an array of
indices, rather than the data itself, gives you several orderings of one
dataset without copying it. It is also how you sort something too large to
move around cheaply. The context is whatever the comparator needs to do its
job.

## Stable or not

| Function | Stable | Notes |
| --- | --- | --- |
| `std.mem.sort` | yes | equal elements keep their relative order |
| `std.mem.sortUnstable` | no | less work; prefer when elements are interchangeable |

Stability matters when you sort by one key and want a previous sort by another
key preserved within ties.

That is how multi-key ordering is normally done: sort by the least significant
key first, then by the most significant, and stability preserves the earlier
work inside each group. Sort by name, then by department, and each
department's entries are still in name order. Do the same with `sortUnstable`
and the second sort scrambles the first.

When elements are genuinely interchangeable, such as plain integers, stability
is unobservable and `sortUnstable` is the better choice: it does less work and
uses no extra memory.

## Comparators as anonymous structs

Zig has no closures, so a one-off comparator is usually written as a struct
literal with a function in it:

```zig
std.mem.sort([]const u8, &words, {}, struct {
    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
}.lessThan);
```

`std.mem.order` returns `.lt` / `.eq` / `.gt`, which is also what
`std.sort.binarySearch` wants.

The comparator has to be a strict "less than". Returning true for equal
elements breaks the ordering the algorithm assumes, and the result is not
merely mis-sorted: it can read out of bounds in an unchecked build. When
comparing on several fields, compare the first, and only fall through to the
second when the first is equal.

## Searching what you sorted

`std.sort.binarySearch` finds an element in an already-sorted slice, and takes
a three-way comparison rather than a less-than, because it needs to know which
half to keep. `std.sort.isSorted` checks the invariant, which is a cheap
assertion to put in a test.

Two neighbours are worth knowing when you do not need the whole thing ordered.
`std.sort.lowerBound` and `upperBound` find insertion points, which is what a
"how many are below this threshold" query wants. And when you only need the
largest few, sorting everything is the wrong algorithm; a [priority
queue](https://www.ziglang.in/learn/standard-library/priority-queue/) keeps the top *k* without
touching the rest.
