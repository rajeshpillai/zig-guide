# An Index Over the Log

> A second structure, derived from the first, that you now have to keep in sync.

Reading one key from the append-only store reads the whole file. It has to:
the newest record for a key could be the last record written, so a scan cannot
stop early without risking a stale answer.

An index fixes that. It is usually described as something that makes lookups
fast, but that description hides what it is. An index is a **second data
structure**, built from the first, holding no data of its own. It maps a key to
*where* the record is. The rest of this chapter follows from those two facts.

## The program

```zig
const std = @import("std");
const store = @import("flatdb.zig");

/// Key to byte offset of the most recent record for that key. An index does
/// not copy the data. It maps each key to where the data is.
pub const Index = struct {
    keys: [64][]const u8 = undefined,
    offsets: [64]usize = undefined,
    count: usize = 0,

    fn put(ix: *Index, key: []const u8, offset: usize) !void {
        for (ix.keys[0..ix.count], 0..) |existing, i| {
            if (std.mem.eql(u8, existing, key)) {
                ix.offsets[i] = offset;
                return;
            }
        }
        if (ix.count == ix.keys.len) return error.IndexFull;
        ix.keys[ix.count] = key;
        ix.offsets[ix.count] = offset;
        ix.count += 1;
    }

    pub fn get(ix: Index, key: []const u8) ?usize {
        for (ix.keys[0..ix.count], 0..) |existing, i| {
            if (std.mem.eql(u8, existing, key)) return ix.offsets[i];
        }
        return null;
    }
};

/// Rebuild from the log. The index is *derived*: the log holds the true data,
/// and the index can always be rebuilt from it. So an index can be deleted to
/// save space, and a corrupt index loses no data.
pub fn build(log: []const u8) !Index {
    var ix: Index = .{};
    var offset: usize = 0;

    while (offset < log.len) {
        const end = std.mem.findScalarPos(u8, log, offset, '\n') orelse break;
        const line = log[offset..end];

        var fields = std.mem.splitScalar(u8, line, '|');
        const op = fields.next() orelse break;
        const key = fields.next() orelse break;

        // Tombstones are indexed like anything else. Skipping them would leave
        // the index pointing at an older live record, so a deleted key would
        // read back as present.
        _ = op;
        try ix.put(key, offset);
        offset = end + 1;
    }
    return ix;
}

/// Read one record, starting at a known offset. Nothing before it is touched.
fn readAt(log: []const u8, offset: usize, scratch: []u8) !?[]const u8 {
    const end = std.mem.findScalarPos(u8, log, offset, '\n') orelse log.len;
    var fields = std.mem.splitScalar(u8, log[offset..end], '|');
    const op = fields.next() orelse return null;
    _ = fields.next();
    const raw_value = fields.next() orelse "";
    if (std.mem.eql(u8, op, "del")) return null;
    @memcpy(scratch[0..raw_value.len], raw_value);
    return scratch[0..raw_value.len];
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var file: [4096]u8 = undefined;
    var log: std.Io.Writer = .fixed(&file);

    // Enough records to make the difference visible in the output.
    var name_buf: [16][8]u8 = undefined;
    var names: [16][]const u8 = undefined;
    for (0..16) |i| {
        names[i] = try std.mem.print(&name_buf[i], "key{d:0>2}", .{i});
        try store.append(&log, .{ .op = .put, .key = names[i], .value = "first" });
    }
    // Every key written again, so the newest record for each sits in the back
    // half of the file. A scan has to reach the end to know it has the latest.
    for (0..16) |i| {
        try store.append(&log, .{ .op = .put, .key = names[i], .value = "second" });
    }
    const written = log.buffered();

    var ix = try build(written);
    try out.print("log is {d} bytes, {d} records, {d} distinct keys\n\n", .{
        written.len,
        32,
        ix.count,
    });

    // Two buffers, not one. Both lookups return slices into whatever they
    // were handed, so sharing a buffer means the second call silently
    // rewrites the first answer and the comparison below compares a value
    // with itself.
    var scan_buf: [64]u8 = undefined;
    var seek_buf: [64]u8 = undefined;
    const target = "key03";

    // A scan reads everything, because the last record for a key could be the
    // last record in the file.
    try out.print("scan for {s}: read {d} bytes\n", .{ target, written.len });
    const scanned = try store.lookup(written, target, &scan_buf);

    const offset = ix.get(target).?;
    const end = std.mem.findScalarPos(u8, written, offset, '\n') orelse written.len;
    const seeked = try readAt(written, offset, &seek_buf);
    try out.print("index for {s}: offset {d}, read {d} bytes\n", .{ target, offset, end - offset });
    try out.print("  both say \"{s}\": {}\n\n", .{
        seeked orelse "",
        std.mem.eql(u8, scanned orelse "", seeked orelse ""),
    });

    try out.print("the index costs {d} entries and one update per write\n", .{ix.count});
    try out.print("and it is derived: delete it and `build` reconstructs it\n", .{});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`20-storage.index`)*

## What just happened

**528 bytes read became 16.** The answer is the same, and the index went
straight to offset 307. That offset is in the back half of the file. The demo
is built to show this case. Every key was written twice, so the newest record is
nowhere near the first one, and a scan cannot know it is done until it reaches
the end.

**The index holds offsets, not values.** It has 16 entries for 32 records. The
index answers "where", and the log still answers "what". Because it stores only
offsets, an index over a terabyte of records can fit in memory.

**It can be rebuilt from the log.** `build` walks the file once and reconstructs
the whole thing. The index is derived data and the log is the source of truth.
This has three consequences. A corrupt index is an inconvenience, not data
loss. An index can be dropped to reclaim space. And adding a
new index to an existing database means a full scan once.

**Tombstones are indexed too.** Skipping delete records would leave the index
pointing at an older live record, and a deleted key would read back as
present. The comment in the code says so, because skipping them looks like an
optimisation.

## What it costs

Every write now does two things. The record is appended and the index is
updated. If the index is on disk, that is a second write for every write you
asked for. This is called **write amplification**. It is why a table with six
indexes is slow to insert into: you asked for one write and the disk does
seven.

Every storage engine makes this trade. Reads get faster in proportion to how
much you index. Writes get slower in the same proportion. No configuration
avoids it. You can only choose whether reads or writes pay the cost.

## Check yourself

This index is a linear scan over 16 entries, which is not obviously better
than scanning the log. When does it start to matter, and what replaces it?

It already matters, because the entries are in memory and the log is on disk.
Memory is several orders of magnitude faster than disk, before you compare the
algorithms at all. What replaces the linear scan depends on the question. A hash
map if you only ever look up one exact key. A B-tree if you also need ranges,
ordering, or "the next 50 keys after this one", because a hash map scatters
neighbouring keys and a B-tree keeps them adjacent.

For this reason, relational databases almost always index with B-trees: `WHERE
id = 7` is served fine by either, and `ORDER BY id LIMIT 50` is only served by
one. The structure itself is in [the data structures
section](https://www.ziglang.in/learn/data-structures/bst/), which builds a search tree and then
shows how sorted input makes it as tall as a list, so every lookup walks every
node.

## If you have written C

The index in memory is a hash table you wrote or one from a library. The hard
case is when it no longer fits in memory. Then it goes on disk, and every
design decision changes.

An on-disk index is read a block at a time, because the disk has no smaller
unit. So the structure has to be shaped around the block size. The block size is
why B-trees have a high branching factor, and why binary trees are not used on
disk. A binary tree with a million keys is 20 levels and 20 reads. A B-tree
with 200 keys per block is three.

C also makes you face another fact: the offsets are only valid for
the file they came from. If you store the index in its own file, you have two
files that must agree. A crash between writing one and the other leaves them
inconsistent. Fixing that is the next chapter.

Next: [a write-ahead log](https://www.ziglang.in/learn/storage/kvstore/), which is how two files that
must agree survive losing power between them.
