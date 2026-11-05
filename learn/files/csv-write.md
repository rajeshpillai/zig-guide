# Write CSV

> Quote a field only when it needs quotes, write each quote in it two times, and read the output again to prove the writer.

To write CSV needs less code than to read CSV. The writer writes most fields with no change. If a field contains a comma, a quote or a line break, the writer puts the field in quotes. It also writes each quote in the field two times.

The program below writes six records with this rule, and six more records without the rule. Then it reads the two files with the reader from [Read CSV](https://www.ziglang.in/learn/files/csv-read/). It compares each field with the field that it wrote.

```zig
const std = @import("std");
const csv = @import("csv-read.zig");

const Io = std.Io;

/// A field needs quotes if it contains a special byte for a CSV reader:
/// the separator, a quote, or a line break.
fn needsQuotes(field: []const u8) bool {
    return std.mem.findAny(u8, field, ",\"\r\n") != null;
}

fn writeField(w: *Io.Writer, field: []const u8) !void {
    if (!needsQuotes(field)) return w.writeAll(field);

    try w.writeByte('"');
    for (field) |b| {
        // Write each quote in the field two times.
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
    // In RFC 4180, each record ends with "\r\n", and spreadsheet programs
    // expect "\r\n". A reader that accepts "\n" also accepts "\r\n".
    try w.writeAll("\r\n");
}

/// The mistake that this chapter prevents: a plain join with commas.
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

    // 1. Write the rows and show the bytes. Show \r and \n as text.
    try out.print("1. the file\n", .{});
    try save(io, dir, "out.csv", writeRecord);
    try showBytes(io, dir, "out.csv", out);

    // 2. Read the file again with the reader from the previous chapter.
    //    Compare each field with the field that the program wrote.
    try out.print("2. round trip\n", .{});
    try roundTrip(io, gpa, dir, "out.csv", out);

    // 3. The same rows, with only commas between the fields.
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

/// Formats a field and shows each newline as \n. Thus the field stays on
/// one line.
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

```zig
/// A field needs quotes if it contains a special byte for a CSV reader:
/// the separator, a quote, or a line break.
fn needsQuotes(field: []const u8) bool {
    return std.mem.findAny(u8, field, ",\"\r\n") != null;
}
```

*Quoted from the source: `needsQuotes` from `snippets/24-files/csv-write.zig`.*

A field needs quotes if it contains a byte that has a special meaning for a CSV reader:

- A comma ends the field.
- A line break ends the record.
- A quote starts or ends a quoted field.

`std.mem.findAny` looks for the four bytes `,"\r\n`. It returns the position of the first of these bytes, or `null`.

The writer writes all other fields without quotes. Thus a file of plain numbers and names looks the same as in a text editor.

## Write one field

```zig
fn writeField(w: *Io.Writer, field: []const u8) !void {
    if (!needsQuotes(field)) return w.writeAll(field);

    try w.writeByte('"');
    for (field) |b| {
        // Write each quote in the field two times.
        if (b == '"') try w.writeByte('"');
        try w.writeByte(b);
    }
    try w.writeByte('"');
}
```

*Quoted from the source: `writeField` from `snippets/24-files/csv-write.zig`.*

If a field has no special bytes, the function writes the field with no change. If not, it writes a quote, then the field, then one more quote.

When the function copies the field, it writes each `"` two times. The reader changes each pair back into one quote.

## Write a record

```zig
fn writeRecord(w: *Io.Writer, fields: []const []const u8) !void {
    for (fields, 0..) |field, i| {
        if (i > 0) try w.writeByte(',');
        try writeField(w, field);
    }
    // In RFC 4180, each record ends with "\r\n", and spreadsheet programs
    // expect "\r\n". A reader that accepts "\n" also accepts "\r\n".
    try w.writeAll("\r\n");
}
```

*Quoted from the source: `writeRecord` from `snippets/24-files/csv-write.zig`.*

Commas separate the fields, and each record ends with `"\r\n"`. RFC 4180, the document that describes CSV, uses `"\r\n"`.

The reader in this guide removes a `'\r'` outside quotes. Thus the reader reads `"\r\n"` and `"\n"`.

Here is the file. The program shows `\r` and `\n` as text, so that you can see them.

```
   id,name,note\r\n
   1,Pencil,\r\n
   2,"Widget, large",blue\r\n
   3,Lamp,"two\n
   lines"\r\n
   4,Sign,"the ""best"" one"\r\n
   5, padded ,"ends with a quote"""\r\n
```

Only four fields have quotes: the field with the comma, the field with the newline, and the two fields with a `"` in them.

Record 3 continues on a second line of the file, because its note contains a newline.

The last field ends with a quote. Thus the field ends with three quotes: an escaped quote as two quotes, then the quote that ends the field.

## The round trip

```
2. round trip
   read 6 records, wrote 6
```

`roundTrip` reads the file with `CsvReader`. It compares each field with the field in the original row. No field is different. Thus the function prints only the count.

Test all writers in this way. A writer can make output that looks correct, but that does not agree with what its reader expects. When the real reader reads the output again, the test checks the writer and the reader together.

The snippet does not contain a copy of the reader. It imports the reader with `@import("csv-read.zig")`. Thus, if the reader changes, this test runs against the new version.

## Join with commas

The third part writes the same rows with `writeRecordNaive`. That function puts commas between the fields, and it does nothing more.

```
   2,Widget, large,blue\r\n
   3,Lamp,two\n
   lines\r\n
   4,Sign,the "best" one\r\n
```

Then the program reads the file again.

```
   record 2: field count 4, wrote 3
   record 3 field 2: read [two], wrote [two\nlines]
   record 4: field count 1, wrote 3
   record 5: QuoteInUnquotedField on line 6
```

Record 2 now has four fields. The comma in `Widget, large` became a separator, and the reader reported no error for it. A program that reads this file puts `large` in the note column, and `blue` in a column that does not exist.

The newline cuts record 3, and `lines` becomes a separate record. Thus each record after record 3 moves by one position.

Only record 5 fails with an error. The quote in `the "best" one` is in an unquoted field, and the reader rejects the quote.

Thus two of the three mistakes make incorrect data, and no error occurs.

## Spaces

Record 5 has a name with a space at each end, `" padded "`. The writer does not put the name in quotes, and the round trip keeps the two spaces.

RFC 4180 says that spaces are part of the field. Some other programs remove spaces from the ends of unquoted fields. If a file is for one of these programs, add `' '` to the bytes in `needsQuotes`. Then the writer puts quotes around fields with spaces.

## Formulas in spreadsheets

Frequently, a person opens a CSV file in a spreadsheet program. A spreadsheet uses a cell that starts with `=`, `+`, `-` or `@` as a formula.

If a field comes from a user, a value such as `=HYPERLINK(...)` becomes a formula when a person opens the file. The name of this attack is [CSV injection](https://owasp.org/www-community/attacks/CSV_Injection).

The problem is not in the CSV format. The file is correct. The spreadsheet decides to run the text.

A common defence is to put a `'` before these fields when the file is for a spreadsheet. That change makes the data different. Thus the change must be in the program that knows who will open the file. It must not be in a general CSV writer such as this one.
