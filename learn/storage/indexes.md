# An Index Over the Log

> A second structure, made from the first, that you must now keep in agreement with the first.

A read of one key from the append-only store reads the full file. The read must
do this. The newest record for a key can be the last record in the file. Thus
a scan cannot stop early, because then the answer can be stale.

An index solves that problem. People usually describe an index as a thing that
makes lookups fast, but that description hides what an index is. An index is a
**second data structure**. A program builds it from the first, and it holds no data of
its own. It maps a key to the *location* of the record. The rest of this
chapter comes from those two facts.

## The program

```zig
const std = @import("std");
const store = @import("flatdb.zig");

/// Maps a key to the byte offset of the newest record for that key. An index
/// does not copy the data. It maps each key to the location of the data.
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

/// Build the index again from the log. The index is *derived*: the log holds
/// the true data, and you can always build the index again from the log. Thus
/// you can delete an index to save space, and a corrupt index loses no data.
pub fn build(log: []const u8) !Index {
    var ix: Index = .{};
    var offset: usize = 0;

    while (offset < log.len) {
        const end = std.mem.findScalarPos(u8, log, offset, '\n') orelse break;
        const line = log[offset..end];

        var fields = std.mem.splitScalar(u8, line, '|');
        const op = fields.next() orelse break;
        const key = fields.next() orelse break;

        // The index contains tombstones, the same as other records. If the
        // index ignored them, it would point to an older live record. Then a
        // deleted key would seem to be present on read.
        _ = op;
        try ix.put(key, offset);
        offset = end + 1;
    }
    return ix;
}

/// Read one record from a known offset. The read does not touch the data
/// before that offset.
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

    // Sufficient records to show the difference in the output.
    var name_buf: [16][8]u8 = undefined;
    var names: [16][]const u8 = undefined;
    for (0..16) |i| {
        names[i] = try std.mem.print(&name_buf[i], "key{d:0>2}", .{i});
        try store.append(&log, .{ .op = .put, .key = names[i], .value = "first" });
    }
    // Write each key again. Thus the newest record for each key is in the
    // second half of the file. A scan must get to the end to know that it has
    // the newest record.
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

    // Two buffers, not one. Both lookups return slices into the buffer that
    // they get. If the lookups use the same buffer, the second call silently
    // writes over the first answer. Then the comparison below compares a
    // value with itself.
    var scan_buf: [64]u8 = undefined;
    var seek_buf: [64]u8 = undefined;
    const target = "key03";

    // A scan reads all the data, because the last record for a key can be the
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

## What the program did

**The read became 16 bytes, not 528 bytes.** The answer is the same, and the
index went directly to offset 307. That offset is in the second half of the
file. The demo shows this case intentionally. The program wrote each key two
times. Thus the newest record is far from the first record, and a scan cannot
know that it is complete until it gets to the end.

**The index holds offsets, not values.** It has 16 entries for 32 records. The
index answers "where", and the log still answers "what". Because the index
stores only offsets, an index over a terabyte of records can fit in memory.

**You can build the index again from the log.** `build` reads the file one time
and makes the full index again. The index is derived data, and the log is the
source of truth. This has three results:

- A corrupt index is an inconvenience, not a loss of data.
- You can delete an index to get the space back.
- To add a new index to a database that exists, you need one full scan.

**The index also contains tombstones.** If the index ignored delete records,
it would point to an older live record. Then a deleted key would seem to be
present on read. The comment in the code states this, because to ignore
tombstones looks like an optimisation.

## The cost of an index

Each write now does two things. The store appends the record, and it updates
the index. If the index is on disk, each write that you asked for needs a
second write. The name of this effect is **write amplification**. For this
reason, an insert into a table with six indexes is slow. You asked for one
write, and the disk does seven.

Each storage engine makes this trade. Reads become faster in proportion to the
quantity that you index. Writes become slower in the same proportion. No
configuration prevents this. You can only select if reads or writes pay the
cost.

## Check yourself

This index is a linear scan over 16 entries, and that is not clearly better
than a scan of the log. When does the index start to be important, and what
replaces the linear scan?

The answer: the index is already important, because the entries are in memory
and the log is on disk. Memory is several orders of magnitude faster than disk,
before you compare the algorithms. The replacement for the linear scan depends
on the question:

- Use a hash map if each lookup uses only one exact key.
- Use a B-tree if you also need ranges, order, or "the next 50 keys after this
  one". A hash map scatters keys that are near each other, and a B-tree keeps
  them adjacent.

For this reason, relational databases almost always use B-trees for indexes.
Both structures serve `WHERE id = 7` well, but only one structure serves
`ORDER BY id LIMIT 50`. [The data structures
section](https://www.ziglang.in/learn/data-structures/bst/) explains the structure. That section
builds a search tree. Then it shows how sorted input makes the tree as tall as
a list, and then each lookup walks each node.

## If you know C

In C, the index in memory is a hash table that you wrote, or a hash table from a
library. The difficult case is when the index is too large for memory. Then the
index goes on disk, and each design decision changes.

The program reads an on-disk index one block at a time, because the disk has no
smaller unit. Thus the shape of the structure must follow the block size. The
block size is the reason that B-trees have a high branching factor, and the
reason that disks do not use binary trees. A binary tree with a million keys
has 20 levels, and needs 20 reads. A B-tree with 200 keys in each block needs
three.

C also makes you see another fact: the offsets are valid only for the file that
they came from. If you store the index in its own file, you have two files that
must agree. A crash between the two writes makes the two files inconsistent.
The next chapter solves that problem.

Next: [a write-ahead log](https://www.ziglang.in/learn/storage/kvstore/). With a write-ahead log, two
files that must agree stay correct after a power loss between the two writes.
