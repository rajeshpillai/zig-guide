//! title: Word Frequencies
//! Count with a hash map, rank with a sort.

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
