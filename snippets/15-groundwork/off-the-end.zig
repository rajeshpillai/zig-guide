//! title: Off the End
//! A length is a value you can check, and Zig keeps it next to the pointer.

const std = @import("std");
const builtin = @import("builtin");

/// Reads an element, and does not assume that the caller checked first.
fn at(numbers: []const u32, index: usize) !u32 {
    if (index >= numbers.len) return error.OutOfBounds;
    return numbers[index];
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const row = [_]u32{ 10, 20, 30, 40 };

    // A slice is a pointer and a length together. Thus a function that
    // receives a slice always knows where the data stops.
    const slice: []const u32 = &row;
    try out.print("the slice has {d} elements\n", .{slice.len});
    try out.print("a slice is {d} bytes: a pointer and a length\n\n", .{@sizeOf([]const u32)});

    // Valid index.
    if (at(slice, 2)) |value| {
        try out.print("element 2 is {d}\n", .{value});
    } else |err| {
        try out.print("element 2: {t}\n", .{err});
    }

    // One past the end. The function reads nothing, and tells the caller.
    if (at(slice, 4)) |value| {
        try out.print("element 4 is {d}\n", .{value});
    } else |err| {
        try out.print("element 4: {t}\n", .{err});
    }

    // For `slice[i]`, the language adds this comparison. The build decides
    // if the comparison is present.
    try out.print("\nsafety checks in this build: {}\n", .{builtin.optimize.runtimeSafety()});

    try out.flush();
}
