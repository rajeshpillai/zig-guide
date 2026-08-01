//! title: Off the End
//! A length is a value you can check, and Zig keeps it next to the pointer.

const std = @import("std");
const builtin = @import("builtin");

/// Reading an element without assuming the caller checked first.
fn at(numbers: []const u32, index: usize) !u32 {
    if (index >= numbers.len) return error.OutOfBounds;
    return numbers[index];
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const row = [_]u32{ 10, 20, 30, 40 };

    // A slice is a pointer and a length travelling together, so a function
    // that receives one cannot be ignorant of where the data stops.
    const slice: []const u32 = &row;
    try out.print("the slice has {d} elements\n", .{slice.len});
    try out.print("a slice is {d} bytes: a pointer and a length\n\n", .{@sizeOf([]const u32)});

    // Valid index.
    if (at(slice, 2)) |value| {
        try out.print("element 2 is {d}\n", .{value});
    } else |err| {
        try out.print("element 2: {t}\n", .{err});
    }

    // One past the end. Nothing is read; the caller is told.
    if (at(slice, 4)) |value| {
        try out.print("element 4 is {d}\n", .{value});
    } else |err| {
        try out.print("element 4: {t}\n", .{err});
    }

    // The check the language inserts for `slice[i]` is this comparison, and
    // whether it is present depends on the build.
    try out.print("\nsafety checks in this build: {}\n", .{builtin.mode.runtimeSafety()});

    try out.flush();
}
