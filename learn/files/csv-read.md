# Reading CSV

> A CSV reader as a four-state machine, with a trace of every byte, the cases splitting on commas gets wrong, and errors with line numbers.

CSV looks like the easiest file format there is.

Each line is a record, and commas separate the fields.

So the first idea is to read a line, and split it on `','`.

That works until a field contains a comma.

`2,"Widget, large",12.00` is three fields, not four.

The quotes say the comma inside them is part of the text.

Then a field can contain a quote, written as two quotes: `"the ""best"" one"`.

And a quoted field can contain a newline, so one record can cover two lines of the file.

Splitting on commas and newlines gets all three cases wrong.

Zig's standard library does not include a CSV reader, so we write one.

It is 150 lines, including comments and the code that prints the trace. At its centre is a state machine with four states.

```zig
const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Reads one record at a time. The fields it returns stay valid until the
/// next call to `next`.
pub const CsvReader = struct {
    r: *Io.Reader,
    gpa: Allocator,
    /// The text of every field in the current record, back to back.
    text: std.ArrayList(u8) = .empty,
    /// Where each field ends in `text`.
    ends: std.ArrayList(usize) = .empty,
    fields: std.ArrayList([]const u8) = .empty,
    line: usize = 1,
    /// The line a quoted field opened on, for reporting one never closed.
    quote_line: usize = 0,
    /// When set, one row per byte read.
    trace: ?*Io.Writer = null,

    const State = enum {
        /// At the start of a field. A quote here opens a quoted field.
        field_start,
        /// Inside a field that did not start with a quote.
        unquoted,
        /// Inside a quoted field. Commas and newlines are ordinary text.
        quoted,
        /// Just read a quote inside a quoted field. The next byte decides:
        /// another quote is an escaped quote, anything else ends the field.
        quote_in_quoted,
    };

    const Error = error{ QuoteInUnquotedField, TextAfterClosingQuote, UnterminatedQuote };

    pub fn deinit(c: *CsvReader) void {
        c.text.deinit(c.gpa);
        c.ends.deinit(c.gpa);
        c.fields.deinit(c.gpa);
    }

    pub fn next(c: *CsvReader) !?[]const []const u8 {
        c.text.clearRetainingCapacity();
        c.ends.clearRetainingCapacity();
        c.fields.clearRetainingCapacity();

        var state: State = .field_start;
        var read_any = false;
        while (true) {
            const byte = c.r.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    // End of input. Inside quotes that is an error, and
                    // with nothing read there is no record at all.
                    if (state == .quoted) {
                        c.line = c.quote_line;
                        return Error.UnterminatedQuote;
                    }
                    if (!read_any) return null;
                    try c.endField();
                    return try c.finish();
                },
                else => |e| return e,
            };
            read_any = true;
            const before = state;

            switch (state) {
                .field_start, .unquoted => switch (byte) {
                    ',' => {
                        try c.endField();
                        state = .field_start;
                    },
                    '\n' => {
                        try c.endField();
                        c.trace1(byte, before, .field_start);
                        c.line += 1;
                        return try c.finish();
                    },
                    // Part of a "\r\n" line ending. Dropped outside quotes.
                    '\r' => {},
                    '"' => if (state == .field_start) {
                        c.quote_line = c.line;
                        state = .quoted;
                    } else return Error.QuoteInUnquotedField,
                    else => {
                        try c.text.append(c.gpa, byte);
                        state = .unquoted;
                    },
                },
                .quoted => switch (byte) {
                    '"' => state = .quote_in_quoted,
                    else => {
                        if (byte == '\n') c.line += 1;
                        try c.text.append(c.gpa, byte);
                    },
                },
                .quote_in_quoted => switch (byte) {
                    // Two quotes in a row are one quote in the text.
                    '"' => {
                        try c.text.append(c.gpa, '"');
                        state = .quoted;
                    },
                    ',' => {
                        try c.endField();
                        state = .field_start;
                    },
                    '\n' => {
                        try c.endField();
                        c.trace1(byte, before, .field_start);
                        c.line += 1;
                        return try c.finish();
                    },
                    '\r' => {},
                    else => return Error.TextAfterClosingQuote,
                },
            }
            c.trace1(byte, before, state);
        }
    }

    fn endField(c: *CsvReader) !void {
        try c.ends.append(c.gpa, c.text.items.len);
    }

    /// Slices are made only here, once `text` has stopped growing. A slice
    /// taken earlier would point at memory that `append` may have moved.
    fn finish(c: *CsvReader) ![]const []const u8 {
        var start: usize = 0;
        for (c.ends.items) |end| {
            try c.fields.append(c.gpa, c.text.items[start..end]);
            start = end;
        }
        return c.fields.items;
    }

    fn trace1(c: *CsvReader, byte: u8, before: State, after: State) void {
        const w = c.trace orelse return;
        const shown: []const u8 = switch (byte) {
            '\n' => "'\\n'",
            '\r' => "'\\r'",
            else => &.{ '\'', byte, '\'' },
        };
        const n = c.ends.items.len;
        const field_ended = after == .field_start and (byte == ',' or byte == '\n');
        if (field_ended) {
            const start = if (n < 2) 0 else c.ends.items[n - 2];
            w.print("   {s:<4} {t:<15} -> {t:<15} field done: [{s}]\n", .{
                shown, before, after, c.text.items[start..c.ends.items[n - 1]],
            }) catch {};
        } else {
            const start = if (n == 0) 0 else c.ends.items[n - 1];
            w.print("   {s:<4} {t:<15} -> {t:<15} [{s}]\n", .{
                shown, before, after, c.text.items[start..],
            }) catch {};
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // 1. Every byte of one short line, and the state after it.
    try out.print("1. trace of: 7,\"say \"\"hi\"\"\",x\n", .{});
    {
        var r: Io.Reader = .fixed("7,\"say \"\"hi\"\"\",x\n");
        var csv: CsvReader = .{ .r = &r, .gpa = gpa, .trace = out };
        defer csv.deinit();
        const fields = (try csv.next()).?;
        try printRecord(out, fields);
    }

    // 2. A file with every case the format allows.
    try out.print("2. products.csv\n", .{});
    const dir = Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = "products.csv", .data = "id,name,price,note\r\n" ++
        "1,Pencil,0.50,\r\n" ++
        "2,\"Widget, large\",12.00,\"the \"\"best\"\" one\"\r\n" ++
        "3,Lamp,30.00,\"two\nlines\"\r\n" ++
        "4,Mug,8.25,no final newline" });
    {
        const file = try dir.openFile(io, "products.csv", .{});
        defer file.close(io);
        var buf: [256]u8 = undefined;
        var fr = file.reader(io, &buf);
        var csv: CsvReader = .{ .r = &fr.interface, .gpa = gpa };
        defer csv.deinit();

        while (try csv.next()) |fields| try printRecord(out, fields);
    }
    try dir.deleteFile(io, "products.csv");

    // 3. Input that is not valid CSV, and the line where it breaks.
    try out.print("3. errors\n", .{});
    for ([_][]const u8{
        "a,b\nc,d\"e\n",
        "a,\"b\"c\n",
        "a,b\nc,\"never closed\n",
    }) |input| {
        var r: Io.Reader = .fixed(input);
        var csv: CsvReader = .{ .r = &r, .gpa = gpa };
        defer csv.deinit();
        var records: usize = 0;
        while (csv.next()) |maybe| {
            if (maybe == null) break;
            records += 1;
        } else |err| {
            try out.print("   \"{f}\": {t} on line {d}\n", .{ std.zig.fmtString(input), err, csv.line });
            continue;
        }
        try out.print("   \"{f}\": {d} records\n", .{ std.zig.fmtString(input), records });
    }
}

fn printRecord(out: *Io.Writer, fields: []const []const u8) !void {
    try out.print("   {d} fields:", .{fields.len});
    for (fields) |f| {
        // A newline inside a field is shown as \n so a record stays on one line.
        try out.writeAll(" [");
        for (f) |b| if (b == '\n') try out.writeAll("\\n") else try out.writeByte(b);
        try out.writeByte(']');
    }
    try out.writeByte('\n');
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`24-files.csv-read`)*

## Four states

<SnippetSource name="24-files.csv-read" decl="State" />

The reader looks at one byte at a time.

What a byte means depends on where we are.

A comma in `field_start` or `unquoted` ends the field.

A comma in `quoted` is just a comma.

So the reader keeps one variable, `state`, and every byte is handled by a `switch` on it.

`quote_in_quoted` is the only state that is not obvious.

Inside quotes, `"` can mean two things.

It can end the quoted field, as in `"abc",`.

Or it can be the first half of an escaped quote, as in `"say ""hi"""`.

We cannot tell which until we see the next byte.

So after a quote, we go to `quote_in_quoted` and wait for one more byte.

Another `"` means an escaped quote. We add one `"` to the text and go back to `quoted`.

A comma or a newline means the field has ended.

Anything else is an error.

## One line, byte by byte

The first part of the program reads `7,"say ""hi""",x` and prints one row per byte.

```
   '7'  field_start     -> unquoted        [7]
   ','  unquoted        -> field_start     field done: [7]
   '"'  field_start     -> quoted          []
```

The first field is `7`. The comma ends it.

The quote opens a quoted field. It is not added to the text.

```
   ' '  quoted          -> quoted          [say ]
   '"'  quoted          -> quote_in_quoted [say ]
   '"'  quote_in_quoted -> quoted          [say "]
```

After `say `, two quotes arrive.

The first moves us to `quote_in_quoted`, and nothing is added yet.

The second is another quote, so one `"` goes into the text and we are back in `quoted`.

```
   '"'  quote_in_quoted -> quoted          [say "hi"]
   '"'  quoted          -> quote_in_quoted [say "hi"]
   ','  quote_in_quoted -> field_start     field done: [say "hi"]
```

The end of the field has three quotes in a row.

The first two are an escaped quote.

The third is followed by a comma, so it was the closing quote.

```
   3 fields: [7] [say "hi"] [x]
```

The brackets in the output show where each field starts and ends. They are not part of the text.

## The reader

<SnippetSource name="24-files.csv-read" decl="next" />

`next` reads until the end of one record and returns its fields.

At the end of the input it returns `null`, so a `while` loop over it stops, like the line loop in [Reading Line by Line](https://www.ziglang.in/learn/files/read-lines/).

It reads from a `*std.Io.Reader`, not from a file.

The trace reads from `.fixed(...)`, a reader over a string in memory.

The second part reads from a file, through `file.reader(io, &buf)`.

`next` cannot tell the difference, and does not need to.

A `'\r'` outside quotes is dropped. That is how `"\r\n"` line endings, which are common in CSV files from spreadsheets, are handled.

End of input is handled in one place, at the top of the loop.

If we are inside quotes, the quote was never closed, which is an error.

If no bytes were read at all, there is no record, and we return `null`.

Otherwise the last field ends there, even without a final newline.

## The fields, and when they are made

The text of every field goes into one growing list, `text`.

`ends` records where each field stops.

The slices are made in `finish`, after the whole record has been read.

<SnippetSource name="24-files.csv-read" decl="finish" />

This order matters.

`text.append` may need more room, and then it moves the whole list to a new place in memory.

A slice taken before that move still points to the old place.

So we wait until `text` has stopped growing, and only then make slices into it.

The slices are valid until the next call to `next`, which clears the lists and reuses them.

## A real file

```
   4 fields: [id] [name] [price] [note]
   4 fields: [1] [Pencil] [0.50] []
   4 fields: [2] [Widget, large] [12.00] [the "best" one]
   4 fields: [3] [Lamp] [30.00] [two\nlines]
   4 fields: [4] [Mug] [8.25] [no final newline]
```

Every line in the file ends with `"\r\n"`, and none of the fields ends with a `'\r'`.

The first record is the header. The reader does not treat it differently. Deciding what a header means is the caller's job.

Pencil's note is empty. `1,Pencil,0.50,` ends with a comma, so there is a fourth field with no text.

The Lamp record covers two lines of the file, and its note contains a newline. It is shown as `\n` here so each record fits on one line.

The last line has no final newline and still reads.

## Errors with line numbers

```
   "a,b\nc,d\"e\n": QuoteInUnquotedField on line 2
   "a,\"b\"c\n": TextAfterClosingQuote on line 1
   "a,b\nc,\"never closed\n": UnterminatedQuote on line 2
```

The first input has a quote in the middle of an unquoted field, `d"e`.

The standard for CSV, RFC 4180, does not allow this.

Some readers accept it and keep the quote. This one stops, because the file is probably not what its writer meant.

The second input has text after a closing quote, `"b"c`.

The third opens a quote on line 2 and never closes it.

The reader reaches the end of the input still inside quotes.

That end is on line 3, but the error names line 2, where the quote opened.

That is the line a person needs to look at, so the reader remembers it in `quote_line`.

The count of lines is not the count of records.

A newline inside quotes is a new line of the file, but not a new record. So `line` goes up in the `quoted` state too.

## What this reader does not do

It reads bytes and does not check that the text is valid UTF-8.

It does not convert fields to numbers. `"12.00"` stays text, and the caller parses it.

It does not skip blank lines. A blank line is a record with one empty field.

Each of these is a choice for the program that uses the reader. The [next chapter](https://www.ziglang.in/learn/files/csv-write/) writes CSV, and checks that this reader reads back what it wrote.
