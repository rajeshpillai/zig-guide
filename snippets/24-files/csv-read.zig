//! title: Reading CSV
//! A CSV reader as a four-state machine over a `*std.Io.Reader`, with a
//! trace of every byte it reads.

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
