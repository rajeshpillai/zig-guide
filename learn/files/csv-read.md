# Read CSV

> A CSV reader as a state machine with four states, a trace of each byte, the errors of a comma split, and line numbers.

CSV looks like the easiest file format of all. Each line is a record, and commas separate the fields. Thus the first idea is to read a line and split the line at each `','`.

That method works until a field contains a comma. `2,"Widget, large",12.00` is three fields, not four. The quotes tell the reader that the comma in them is part of the text.

There are two more cases:

- A field can contain a quote, as two quotes: `"the ""best"" one"`.
- A quoted field can contain a newline. Thus one record can use two lines of the file.

A split at commas and newlines gives incorrect results for all three cases.

The Zig standard library does not include a CSV reader. Thus this chapter writes one. The reader is 150 lines, with comments and the code that prints the trace. At its centre is a state machine with four states.

```zig
const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Reads one record at a time. The fields that it returns stay valid until
/// the next call to `next`.
pub const CsvReader = struct {
    r: *Io.Reader,
    gpa: Allocator,
    /// The text of each field in the current record, with no space between.
    text: std.ArrayList(u8) = .empty,
    /// Where each field ends in `text`.
    ends: std.ArrayList(usize) = .empty,
    fields: std.ArrayList([]const u8) = .empty,
    line: usize = 1,
    /// The line where a quoted field opened. The error for a quote that
    /// never closes gives this line.
    quote_line: usize = 0,
    /// If not null, the reader writes one row for each byte that it reads.
    trace: ?*Io.Writer = null,

    const State = enum {
        /// At the start of a field. A quote here opens a quoted field.
        field_start,
        /// In a field that did not start with a quote.
        unquoted,
        /// In a quoted field. Commas and newlines are usual text.
        quoted,
        /// The reader read a quote in a quoted field. The next byte decides:
        /// another quote is an escaped quote, and all other bytes end the field.
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
                    // End of input. In quotes, the end is an error. If the
                    // reader read no bytes, there is no record.
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
                    // Part of a "\r\n" line ending. Discard it outside quotes.
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
                    // Two quotes in a sequence are one quote in the text.
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

    /// Make the slices only here, when `text` does not grow any more. An
    /// earlier slice can point at memory that `append` moved.
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

    // 1. Each byte of one short line, and the state after the byte.
    try out.print("1. trace of: 7,\"say \"\"hi\"\"\",x\n", .{});
    {
        var r: Io.Reader = .fixed("7,\"say \"\"hi\"\"\",x\n");
        var csv: CsvReader = .{ .r = &r, .gpa = gpa, .trace = out };
        defer csv.deinit();
        const fields = (try csv.next()).?;
        try printRecord(out, fields);
    }

    // 2. A file with each case that the format allows.
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

    // 3. Input that is not valid CSV, and the line where the error occurs.
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
        // Show a newline in a field as \n, so that a record stays on one line.
        try out.writeAll(" [");
        for (f) |b| if (b == '\n') try out.writeAll("\\n") else try out.writeByte(b);
        try out.writeByte(']');
    }
    try out.writeByte('\n');
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`24-files.csv-read`)*

## Four states

```zig
    const State = enum {
        /// At the start of a field. A quote here opens a quoted field.
        field_start,
        /// In a field that did not start with a quote.
        unquoted,
        /// In a quoted field. Commas and newlines are usual text.
        quoted,
        /// The reader read a quote in a quoted field. The next byte decides:
        /// another quote is an escaped quote, and all other bytes end the field.
        quote_in_quoted,
    };
```

*Quoted from the source: `State` from `snippets/24-files/csv-read.zig`.*

The reader looks at one byte at a time. The meaning of a byte changes with the current state:

- A comma in `field_start` or `unquoted` ends the field.
- A comma in `quoted` is only a comma.

Thus the reader keeps one variable, `state`. A `switch` on `state` handles each byte.

`quote_in_quoted` is the only state that is not easy to understand. In quotes, `"` can have two meanings:

- It can end the quoted field, as in `"abc",`.
- It can be the first half of an escaped quote, as in `"say ""hi"""`.

The reader cannot know which meaning is correct until it sees the next byte. Thus, after a quote, the reader goes to `quote_in_quoted` and waits for one more byte:

- Another `"` means an escaped quote. The reader adds one `"` to the text and returns to `quoted`.
- A comma or a newline means that the field ended.
- All other bytes cause an error.

## One line, byte by byte

The first part of the program reads `7,"say ""hi""",x` and prints one row for each byte.

```
   '7'  field_start     -> unquoted        [7]
   ','  unquoted        -> field_start     field done: [7]
   '"'  field_start     -> quoted          []
```

The first field is `7`. The comma ends the field. The quote starts a quoted field, and the reader does not add the quote to the text.

```
   ' '  quoted          -> quoted          [say ]
   '"'  quoted          -> quote_in_quoted [say ]
   '"'  quote_in_quoted -> quoted          [say "]
```

After `say `, two quotes come. The first quote moves the reader to `quote_in_quoted`, and the reader adds nothing to the text. The second byte is also a quote. Thus the reader adds one `"` to the text and returns to `quoted`.

```
   '"'  quote_in_quoted -> quoted          [say "hi"]
   '"'  quoted          -> quote_in_quoted [say "hi"]
   ','  quote_in_quoted -> field_start     field done: [say "hi"]
```

At the end of the field, there are three quotes in a sequence. The first two quotes are an escaped quote. A comma comes after the third quote. Thus the third quote was the quote that ends the field.

```
   3 fields: [7] [say "hi"] [x]
```

The brackets in the output show where each field starts and ends. The brackets are not part of the text.

## The reader

```zig
    pub fn next(c: *CsvReader) !?[]const []const u8 {
        c.text.clearRetainingCapacity();
        c.ends.clearRetainingCapacity();
        c.fields.clearRetainingCapacity();

        var state: State = .field_start;
        var read_any = false;
        while (true) {
            const byte = c.r.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    // End of input. In quotes, the end is an error. If the
                    // reader read no bytes, there is no record.
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
                    // Part of a "\r\n" line ending. Discard it outside quotes.
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
                    // Two quotes in a sequence are one quote in the text.
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
```

*Quoted from the source: `next` from `snippets/24-files/csv-read.zig`.*

`next` reads until the end of one record and returns the fields of the record. At the end of the input, `next` returns `null`. Thus a `while` loop over `next` stops, the same as the line loop in [Read Line by Line](https://www.ziglang.in/learn/files/read-lines/).

`next` reads from a `*std.Io.Reader`, not from a file. The trace reads from `.fixed(...)`, which is a reader over a string in memory. The second part reads from a file, through `file.reader(io, &buf)`. `next` cannot see the difference, and it does not have to.

The reader discards a `'\r'` outside quotes. In this way, the reader handles `"\r\n"` line endings, which are common in CSV files from spreadsheets.

The reader handles the end of input in one location, at the top of the loop:

- If the reader is in quotes, the quote never closed. This is an error.
- If the reader read no bytes, there is no record. The reader returns `null`.
- If not, the last field ends at that position, also without a final newline.

## The fields, and when the reader makes them

The text of each field goes into one list, `text`, which becomes larger with each byte. `ends` records where each field stops. The reader makes the slices in `finish`, after it reads the full record.

```zig
    /// Make the slices only here, when `text` does not grow any more. An
    /// earlier slice can point at memory that `append` moved.
    fn finish(c: *CsvReader) ![]const []const u8 {
        var start: usize = 0;
        for (c.ends.items) |end| {
            try c.fields.append(c.gpa, c.text.items[start..end]);
            start = end;
        }
        return c.fields.items;
    }
```

*Quoted from the source: `finish` from `snippets/24-files/csv-read.zig`.*

This order is important. `text.append` can need more space, and then it moves the full list to a new location in memory. A slice from before the move still points to the old location.

Thus the reader waits until `text` gets no more bytes. The reader makes slices into `text` only after that.

The slices are valid until the next call to `next`. That call clears the lists and uses them again.

## A real file

```
   4 fields: [id] [name] [price] [note]
   4 fields: [1] [Pencil] [0.50] []
   4 fields: [2] [Widget, large] [12.00] [the "best" one]
   4 fields: [3] [Lamp] [30.00] [two\nlines]
   4 fields: [4] [Mug] [8.25] [no final newline]
```

Each line in the file ends with `"\r\n"`, and no field ends with a `'\r'`.

The first record is the header. The reader does not handle the header differently. The caller must decide what a header means.

The note for Pencil is empty. `1,Pencil,0.50,` ends with a comma. Thus there is a fourth field with no text.

The Lamp record uses two lines of the file, and its note contains a newline. The output shows the newline as `\n`, so that each record fits on one line.

The last line has no final newline, and the reader reads it correctly.

## Errors with line numbers

```
   "a,b\nc,d\"e\n": QuoteInUnquotedField on line 2
   "a,\"b\"c\n": TextAfterClosingQuote on line 1
   "a,b\nc,\"never closed\n": UnterminatedQuote on line 2
```

The first input has a quote in the middle of an unquoted field, `d"e`. RFC 4180, the standard for CSV, does not allow this. Some readers accept the quote and keep it. This reader stops, because the file is probably not what its writer intended.

The second input has text after the quote that ends the field, `"b"c`.

The third input opens a quote on line 2 and never closes it. The reader comes to the end of the input, and it is still in quotes. That end is on line 3, but the error gives line 2, where the quote opened. A person must look at line 2. Thus the reader keeps that line number in `quote_line`.

The count of lines is not the count of records. A newline in quotes is a new line of the file, but not a new record. Thus `line` also increases in the `quoted` state.

## What this reader does not do

- The reader reads bytes. It does not make sure that the text is valid UTF-8.
- It does not change fields to numbers. `"12.00"` stays text, and the caller parses it.
- It does not skip blank lines. A blank line is a record with one empty field.

Each of these is a decision for the program that uses the reader. The [next chapter](https://www.ziglang.in/learn/files/csv-write/) writes CSV. It also makes sure that this reader reads the same data that the writer wrote.
