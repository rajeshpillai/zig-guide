# Recipe: Word Frequencies

> Count occurrences with a hash map, then rank them with a sort.

To count words in Zig, divide the text into words with `std.mem.tokenizeAny`. Count the words into a `StringHashMapUnmanaged(u32)` with `getOrPut`. Then copy the entries into an `ArrayList`, and sort the list with `std.mem.sort`.

## The problem

You have a block of text, and you want the five most common words. These are the conditions:

- Upper case and lower case are the same.
- The program ignores punctuation.
- The order is stable, thus two runs always give the same order for words with equal counts.

Log analysis, tag clouds and all types of "top N by count" reports use this shape.

Be careful about one thing. A hash map is the correct tool to count, but a hash map **has no order**. To rank the words, you need a second structure.

## The plan

1. **Tokenize.** Use whitespace and punctuation as delimiters. `tokenizeAny` never gives an empty token.
2. **Count** with `getOrPut`. This function does one lookup for each word, not a `get` and then a `put`.
3. **Rank.** Sort a copy of the entries with a comparator. When two counts are equal, the comparator uses alphabetical order.

```zig
const std = @import("std");

const Count = struct { word: []const u8, n: u32 };

fn moreFrequent(_: void, a: Count, b: Count) bool {
    if (a.n != b.n) return a.n > b.n;
    // For equal counts, use alphabetical order. Thus the ranking is deterministic.
    return std.mem.lessThan(u8, a.word, b.word);
}

pub fn main(init: std.process.Init) !void {
    // An arena is correct for this job. The map, the list and the copied keys
    // have the same lifetime. Thus one `deinit` frees all of them at one time.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const text =
        \\the quick brown fox jumps over the lazy dog.
        \\The dog barks, and the fox runs.
    ;

    // Step 1: count. `getOrPut` does one hash lookup, for a new word and for
    // a word that the map already has.
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(gpa);

    var lower_buf: [64]u8 = undefined;
    var words = std.mem.tokenizeAny(u8, text, " \n\t.,!?");
    while (words.next()) |raw| {
        const word = std.ascii.lowerString(&lower_buf, raw);
        const entry = try counts.getOrPut(gpa, word);
        if (!entry.found_existing) {
            // `word` is in a buffer that the loop uses again. Thus keys must own their bytes.
            entry.key_ptr.* = try gpa.dupe(u8, word);
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }

    // Step 2: a hash map has no order. Move the entries into a list. Then
    // the program can sort them.
    var ranked: std.ArrayList(Count) = .empty;
    defer ranked.deinit(gpa);

    var it = counts.iterator();
    while (it.next()) |entry| {
        try ranked.append(gpa, .{ .word = entry.key_ptr.*, .n = entry.value_ptr.* });
    }

    // Step 3: rank the words, and report the top five.
    std.mem.sort(Count, ranked.items, {}, moreFrequent);

    for (ranked.items[0..@min(5, ranked.items.len)]) |c| {
        try out.print("{d:>2}  {s}\n", .{ c.n, c.word });
    }
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.word-frequency`)*

## Why the program copies the keys

`lowerString` writes each word in lower case into the same buffer, which the program uses again for each word. If the map stores that slice as a key, all of the keys point to one buffer. Then the last word overwrites all of the keys. `gpa.dupe` gives each key its own bytes.

The copy of the keys is the only ownership decision in this recipe, and the arena makes the copy cheap. The map, the list and the copied keys all have the same lifetime. Thus one `arena_state.deinit()` frees all of them. No key needs its own `free`, and no memory leaks.

## Why sort a copy

`counts.iterator()` goes through the entries in hash order. That order is effectively random, and it can change between compiler versions.

The program moves the `(word, count)` pairs into an `ArrayList`. That costs one pass, and it gives you a plain slice. `std.mem.sort` needs a slice.

The comparator sorts by count, from the largest to the smallest, and then in alphabetical order. Without the second rule, the order of equal counts depends on hash order, and the output can change from one run to the next. CI compares the output of this page character by character. Thus the output must be the same on each run.

## Variations

- **Top N of a large set:** at a large scale, a sort of all the words to get five is wasteful. `std.PriorityQueue` gives you the heap. To keep the heap at five items, remove the smallest item after each push. The standard library sorts only full slices. Thus you must write the partial selection yourself. Do either of these only when profiling shows that you need it.
- **Unicode:** `std.ascii.lowerString` works only on ASCII, by design. Real case-folding needs a Unicode library, and [Unicode Recipes](https://www.ziglang.in/learn/standard-library/unicode-recipes/) gives the name of one. The standard library intentionally does not guess.
