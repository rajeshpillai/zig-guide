# Writing CSV

> Quote a field only when it needs it, double the quotes inside it, and prove the writer by reading its output back.

Writing CSV is shorter than reading it.

Most fields are written as they are.

A field that contains a comma, a quote or a line break goes inside quotes, and any quote inside it is written twice.

The program below writes six records with the rule, and six more without it.

Then it reads both files back with the reader from [Reading CSV](https://www.ziglang.in/learn/files/csv-read/), and compares every field with what it wrote.

```zig
const std = @import("std");
const csv = @import("csv-read.zig");

const Io = std.Io;

/// A field needs quotes if it contains a byte that means something to a
/// CSV reader: the separator, a quote, or a line break.
fn needsQuotes(field: []const u8) bool {
    return std.mem.findAny(u8, field, ",\"\r\n") != null;
}

fn writeField(w: *Io.Writer, field: []const u8) !void {
    if (!needsQuotes(field)) return w.writeAll(field);

    try w.writeByte('"');
    for (field) |b| {
        // A quote inside the field is written twice.
        if (b == '"') try w.writeByte('"');
        try w.writeByte(b);
    }
    try w.writeByte('"');
}

fn writeRecord(w: *Io.Writer, fields: []const []const u8) !void {
    for (fields, 0..) |field, i| {
        if (i > 0) try w.writeByte(',');
        try writeField(w, field);
    }
    // RFC 4180 ends each record with "\r\n", and spreadsheet programs expect
    // it. A reader that accepts "\n" also accepts "\r\n".
    try w.writeAll("\r\n");
}

/// The mistake this chapter exists to prevent: join the fields with commas.
fn writeRecordNaive(w: *Io.Writer, fields: []const []const u8) !void {
    for (fields, 0..) |field, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(field);
    }
    try w.writeAll("\r\n");
}

const rows = [_][]const []const u8{
    &.{ "id", "name", "note" },
    &.{ "1", "Pencil", "" },
    &.{ "2", "Widget, large", "blue" },
    &.{ "3", "Lamp", "two\nlines" },
    &.{ "4", "Sign", "the \"best\" one" },
    &.{ "5", " padded ", "ends with a quote\"" },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();

    // 1. Write the rows and show the bytes, with \r and \n made visible.
    try out.print("1. the file\n", .{});
    try save(io, dir, "out.csv", writeRecord);
    try showBytes(io, dir, "out.csv", out);

    // 2. Read the file back with the reader from the previous chapter, and
    //    compare every field with what we wrote.
    try out.print("2. round trip\n", .{});
    try roundTrip(io, gpa, dir, "out.csv", out);

    // 3. The same rows, joined with commas and nothing else.
    try out.print("3. naive join\n", .{});
    try save(io, dir, "naive.csv", writeRecordNaive);
    try showBytes(io, dir, "naive.csv", out);
    try roundTrip(io, gpa, dir, "naive.csv", out);

    try dir.deleteFile(io, "out.csv");
    try dir.deleteFile(io, "naive.csv");
}

fn save(io: Io, dir: Io.Dir, name: []const u8, comptime writeFn: anytype) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var fw = file.writer(io, &buf);
    for (rows) |row| try writeFn(&fw.interface, row);
    try fw.interface.flush();
}

fn roundTrip(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var fr = file.reader(io, &buf);
    var reader: csv.CsvReader = .{ .r = &fr.interface, .gpa = gpa };
    defer reader.deinit();

    var i: usize = 0;
    while (reader.next()) |maybe| : (i += 1) {
        const got = maybe orelse break;
        const want = if (i < rows.len) rows[i] else &[_][]const u8{};
        if (got.len != want.len) {
            try out.print("   record {d}: field count {d}, wrote {d}\n", .{ i, got.len, want.len });
            continue;
        }
        for (got, want, 0..) |g, w, f| {
            if (!std.mem.eql(u8, g, w)) {
                try out.print("   record {d} field {d}: read [{f}], wrote [{f}]\n", .{ i, f, visible(g), visible(w) });
            }
        }
    } else |err| {
        try out.print("   record {d}: {t} on line {d}\n", .{ i, err, reader.line });
        return;
    }
    try out.print("   read {d} records, wrote {d}\n", .{ i, rows.len });
}

/// Formats a field with its newlines shown as \n, so it stays on one line.
fn visible(field: []const u8) std.fmt.Alt([]const u8, writeVisible) {
    return .{ .data = field };
}

fn writeVisible(field: []const u8, w: *Io.Writer) Io.Writer.Error!void {
    for (field) |b| if (b == '\n') try w.writeAll("\\n") else try w.writeByte(b);
}

fn showBytes(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    var buf: [512]u8 = undefined;
    const bytes = try dir.readFile(io, name, &buf);
    try out.writeAll("   ");
    for (bytes, 0..) |b, i| switch (b) {
        '\r' => try out.writeAll("\\r"),
        '\n' => try out.writeAll(if (i + 1 == bytes.len) "\\n\n" else "\\n\n   "),
        else => try out.writeByte(b),
    };
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`24-files.csv-write`)*

## When a field needs quotes

<SnippetSource name="24-files.csv-write" decl="needsQuotes" />

A field needs quotes if it contains a byte that means something to a CSV reader.

A comma would end the field.

A line break would end the record.

A quote would start or end a quoted field.

`std.mem.findAny` looks for any of the four bytes `,"\r\n` and returns the position of the first one, or `null`.

Every other field is written without quotes, so a file of plain numbers and names looks the same as it would in a text editor.

## Writing one field

<SnippetSource name="24-files.csv-write" decl="writeField" />

A field without special bytes is written as it is.

Otherwise we write a quote, then the field, then a closing quote.

While copying the field, each `"` is written twice.

The reader turns each pair back into one quote.

## Writing a record

<SnippetSource name="24-files.csv-write" decl="writeRecord" />

Fields are separated by commas, and each record ends with `"\r\n"`.

RFC 4180, the document that describes CSV, uses `"\r\n"`.

Our reader drops a `'\r'` outside quotes, so it reads both `"\r\n"` and `"\n"`.

Here is the file, with `\r` and `\n` shown as text so we can see them.

```
   id,name,note\r\n
   1,Pencil,\r\n
   2,"Widget, large",blue\r\n
   3,Lamp,"two\n
   lines"\r\n
   4,Sign,"the ""best"" one"\r\n
   5, padded ,"ends with a quote"""\r\n
```

Only four fields have quotes: the comma, the newline, and the two with a `"` inside.

Record 3 continues onto a second line of the file, because its note contains a newline.

The last field ends with a quote, so it ends with three: one escaped quote written as two, then the closing quote.

## The round trip

```
2. round trip
   read 6 records, wrote 6
```

`roundTrip` reads the file with `CsvReader` and compares every field with the row it came from.

Nothing differs, so the only line it prints is the count.

Test every writer this way.

A writer can produce output that looks right and still not match what its reader expects.

Reading the output back with the real reader checks both halves together.

The reader is not copied into this snippet. It is imported with `@import("csv-read.zig")`.

So if the reader changes, this test runs against the new version.

## Joining with commas

The third part writes the same rows with `writeRecordNaive`.

It joins the fields with commas, and does nothing else.

```
   2,Widget, large,blue\r\n
   3,Lamp,two\n
   lines\r\n
   4,Sign,the "best" one\r\n
```

Then it reads the file back.

```
   record 2: field count 4, wrote 3
   record 3 field 2: read [two], wrote [two\nlines]
   record 4: field count 1, wrote 3
   record 5: QuoteInUnquotedField on line 6
```

Record 2 now has four fields. The comma in `Widget, large` became a separator.

No error was reported for it.

A program reading this file would put `large` in the note column, and `blue` in a column that does not exist.

Record 3 is cut at the newline, and `lines` becomes a record of its own. That moves every record after it by one.

Only record 5 fails with an error. The quote in `the "best" one` is in an unquoted field, and the reader rejects it.

So two of the three mistakes produce wrong data without any error.

## Spaces

Record 5 has a name with a space at each end, `" padded "`.

The writer does not quote it, and the round trip keeps both spaces.

RFC 4180 says spaces are part of the field.

Some other programs trim spaces from unquoted fields.

If a file is for one of those programs, add `' '` to the bytes in `needsQuotes`, and fields with spaces will be quoted.

## Formulas in spreadsheets

A CSV file is often opened in a spreadsheet program.

Spreadsheets treat a cell that starts with `=`, `+`, `-` or `@` as a formula.

If a field comes from a user, a value like `=HYPERLINK(...)` becomes a formula when someone opens the file.

This is called [CSV injection](https://owasp.org/www-community/attacks/CSV_Injection).

The CSV format is not the problem here. The file is correct. The spreadsheet decides to run the text.

A common defence is to put a `'` in front of such fields when the file is meant for a spreadsheet.

That changes the data, so it belongs in the program that knows who will open the file, not in a general CSV writer like this one.
