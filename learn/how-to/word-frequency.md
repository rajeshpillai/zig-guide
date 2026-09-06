# Recipe: Word Frequencies

> Count occurrences with a hash map, then rank them with a sort.

## The problem

You have a block of text and want the five most common words: case-insensitive,
punctuation ignored, and with a stable order so two runs never disagree about
ties. It is the shape behind log analysis, tag clouds, and "top N by count"
reports of every kind.

The catch that trips people up in Zig: a hash map is the right tool for
counting, but a hash map **has no order**. Ranking needs a second structure.

## The plan

1. **Tokenize** with `std.mem.tokenizeAny`, treating whitespace and
   punctuation as delimiters. It never yields an empty token.
2. **Count** into a `StringHashMapUnmanaged(u32)` using `getOrPut`, one
   lookup per word instead of a `get` followed by a `put`.
3. **Rank** by copying the entries into an `ArrayList` and sorting it with a
   comparator that breaks count ties alphabetically.

```zig
const std = @import("std");

const Count = struct { word: []const u8, n: u32 };

fn moreFrequent(_: void, a: Count, b: Count) bool {
    if (a.n != b.n) return a.n > b.n;
    // Tie-break alphabetically so the ranking is deterministic.
    return std.mem.lessThan(u8, a.word, b.word);
}

pub fn main(init: std.process.Init) !void {
    // An arena fits this job: the map, the list and the duplicated keys all
    // share one lifetime, so one `deinit` frees everything at once.
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

    // Step 1: count. `getOrPut` does one hash lookup whether the word is
    // new or already seen.
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(gpa);

    var lower_buf: [64]u8 = undefined;
    var words = std.mem.tokenizeAny(u8, text, " \n\t.,!?");
    while (words.next()) |raw| {
        const word = std.ascii.lowerString(&lower_buf, raw);
        const entry = try counts.getOrPut(gpa, word);
        if (!entry.found_existing) {
            // `word` lives in a reused buffer, so keys must own their bytes.
            entry.key_ptr.* = try gpa.dupe(u8, word);
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }

    // Step 2: a hash map has no order. Move the entries into a list so
    // they can be sorted.
    var ranked: std.ArrayList(Count) = .empty;
    defer ranked.deinit(gpa);

    var it = counts.iterator();
    while (it.next()) |entry| {
        try ranked.append(gpa, .{ .word = entry.key_ptr.*, .n = entry.value_ptr.* });
    }

    // Step 3: rank and report the top five.
    std.mem.sort(Count, ranked.items, {}, moreFrequent);

    for (ranked.items[0..@min(5, ranked.items.len)]) |c| {
        try out.print("{d:>2}  {s}\n", .{ c.n, c.word });
    }
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.word-frequency`)*

## Why the keys are duplicated

`lowerString` writes each lowercased word into the same reused buffer. If the
map stored that slice as a key, every key would alias one buffer and the last
word written would overwrite them all. `gpa.dupe` gives each key its own bytes.

This is the recipe's one real ownership decision, and the arena makes it cheap:
map, list, and duplicated keys all share a lifetime, so a single
`arena_state.deinit()` frees the lot. No per-key `free`, no leak.

## Why sort a copy

`counts.iterator()` walks entries in hash order: effectively arbitrary, and
not even stable across compiler versions. Moving `(word, count)` pairs into an
`ArrayList` costs one pass and gives you a plain slice, which is what
`std.mem.sort` wants anyway.

The comparator sorts by count descending, then alphabetically. Without the
tie-break the order of equal counts would depend on hash order, and the output
would change from run to run. This page's output is verified character-for-
character by CI, so determinism is not optional here.

## Variations

- **Top N of a large set:** sorting everything to take five is wasteful at
  scale; `std.sort.heap` a bounded heap, or `std.mem.sort` a partial
  selection, once profiling says so.
- **Unicode:** `std.ascii.lowerString` is ASCII-only by design. Real
  case-folding needs a Unicode library, and
  [Unicode Recipes](https://www.ziglang.in/learn/standard-library/unicode-recipes/) names one; the standard library deliberately
  does not guess.
