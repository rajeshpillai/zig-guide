# cut

> Splitting on a delimiter, and the edge cases that decide whether it is correct.

`cut -d: -f2` pulls the second field out of each line. It is the smallest tool
here, and whether it is correct depends entirely on its edge cases. So we need
to say exactly what "splitting" means.

Split `a:b:c` on `:` and you get three fields. One rule covers every other
case: **n delimiters produce n+1 fields, always.** Runs of delimiters are not
merged, and empty fields are not skipped. With that rule, the awkward inputs
have clear answers. With any other rule, you keep adding special cases to fix
them.

## The program

```zig
const std = @import("std");

/// Field `n` of `line`, counting from 1 the way cut does. Returns null when
/// the line has fewer fields, which is different from the field being empty
/// and has to stay different.
fn field(line: []const u8, delimiter: u8, n: usize) ?[]const u8 {
    if (n == 0) return null;

    var it = std.mem.splitScalar(u8, line, delimiter);
    var i: usize = 1;
    while (it.next()) |part| : (i += 1) {
        if (i == n) return part;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const rows = [_][]const u8{
        "alice:30:london",
        "bob:25:paris",
        // An empty field in the middle: two delimiters with nothing between.
        "carol::berlin",
        // Fewer fields than asked for.
        "dave",
    };

    for ([_]usize{ 1, 2 }) |n| {
        try out.print("--- field {d}\n", .{n});
        for (rows) |row| {
            if (field(row, ':', n)) |value| {
                try out.print("{s} -> \"{s}\"\n", .{ row, value });
            } else {
                try out.print("{s} -> (no such field)\n", .{row});
            }
        }
        try out.writeAll("\n");
    }

    // Splitting never invents or loses a field: n delimiters give n+1 fields,
    // even when some of them are empty.
    var it = std.mem.splitScalar(u8, "carol::berlin", ':');
    var parts: usize = 0;
    while (it.next()) |_| parts += 1;
    try out.print("\"carol::berlin\" has {d} fields\n", .{parts});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`16-unix-tools.cut`)*

## What just happened

**`carol::berlin` has three fields, and the middle one is empty.** Two
delimiters, three fields, exactly as the rule says. Many splitters that look
correct get this case wrong. It is tempting to treat a run of delimiters as
one, because that is how splitting on whitespace usually works. For a
delimited data format it is wrong, and the error is silent. Every field after
it shifts by one. Field 3 of a CSV row becomes field 2, and the data is
corrupted without any error being reported.

**An empty field and a missing field printed differently.** `carol::berlin`
field 2 is `""`. `dave` field 2 is `(no such field)`. This is why the function
returns `?[]const u8` instead of `[]const u8`. An empty string is a field that
was there and was empty. Null means there is no field. If you merge the two, a
caller cannot tell "this record has no email" from "this record's email is
blank". A program that acts on the record needs to know which one it has.

Each field is a slice of the line it came from, as in the last chapter. No
bytes are copied, which is why `cut` runs at the speed of the disk.

## Check yourself

The real `cut` treats a line with no delimiter at all specially: `cut -d: -f2`
prints the whole line instead of nothing. Does the rule above explain that,
or is it an exception?

It is an exception. By the rule, zero delimiters means one field, so field 1
is everything and field 2 does not exist. The program above answers the rule:
`dave` gives `"dave"` for field 1 and no field 2. POSIX makes `cut` print a
line with no delimiter unchanged, whatever field you asked for. The reason
given is that dropping a line you did not parse is worse than passing it on.
The `-s` flag turns the exception off.

## If you have written C

C has `strtok`. Here is why you should not use it for this:

```c
char *field = strtok(line, ":");
while (field) field = strtok(NULL, ":");
```

Three problems. It **modifies the input**, writing `\0` over each delimiter,
so the line you were handed is destroyed and you cannot use the original
afterwards. It **collapses runs of delimiters**, so `carol::berlin` gives two
fields instead of three. That is the bug described above, built into the
standard library. And it keeps its position in a **static variable**, so it is
not reentrant, and two loops using it at once corrupt each other.

`strtok_r` fixes only the third problem. The collapsing is by design, because
`strtok` was written for whitespace. Programmers still use it on data formats
out of habit.

Zig's `splitScalar` returns slices of the original. It does not modify the
input, does not merge delimiters, and keeps no static state.

Next: [printf](https://www.ziglang.in/learn/unix-tools/printf/), where a number has to become text.
