# A Contest Template

> The one program in the section that reads real stdin, and three problems that a judge finds and a browser never shows.

Each other chapter in this section parses its input from a `const` string. A judge does not give you a string. A judge gives you standard input, and it compares your standard output with the correct output.

This program is the shape around each solution in the section. The program reads real stdin. Thus it cannot run in your browser, because the WASI sandbox has no standard input.

CI builds the program for the host. Then CI gives it a file as input and compares the output, in the same way as a judge.

```zig
const std = @import("std");

/// The largest `n` that the problem allows. Contest statements always give
/// this limit. If the storage size comes from the limit, the program does not
/// allocate memory.
const max_n = 200_000;

/// The declaration is at container level, not inside `main`.
///
/// 200,000 values of 8 bytes is 1.6 MB. A local array is on the stack. On
/// Linux the stack is usually 8 MB, and on a judge it is frequently smaller.
/// Thus a bound ten times larger crashes before the first read. A global is
/// in the zeroed data of the program, and each test case uses it again.
var values: [max_n]i64 = undefined;

/// Skip whitespace, then read one integer.
///
/// The function reads one byte at a time and does not examine line breaks.
/// Thus the layout of the input has no effect. A judge tells you the tokens
/// and their order, not the line of each token.
fn nextInt(in: *std.Io.Reader) !i64 {
    var c = try in.takeByte();
    while (c == ' ' or c == '\n' or c == '\r' or c == '\t') c = try in.takeByte();

    const negative = c == '-';
    if (negative) c = try in.takeByte();
    if (c < '0' or c > '9') return error.NotANumber;

    var value: i64 = 0;
    while (true) {
        value = value * 10 + (c - '0');
        c = in.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (c < '0' or c > '9') break;
    }
    return if (negative) -value else value;
}

/// One test case: the sum of the values and the largest value.
///
/// The sum is `i64` on purpose. The sum of three values of 10^9 is 3 * 10^9,
/// and the maximum value of `i32` is 2,147,483,647.
fn solve(in: *std.Io.Reader, out: *std.Io.Writer) !void {
    const n: usize = @intCast(try nextInt(in));
    if (n == 0 or n > max_n) return error.BadLength;

    const items = values[0..n];
    for (items) |*v| v.* = try nextInt(in);

    var sum: i64 = 0;
    var largest = items[0];
    for (items) |v| {
        sum += v;
        largest = @max(largest, v);
    }
    try out.print("{d} {d}\n", .{ sum, largest });
}

pub fn main(init: std.process.Init) !void {
    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    const in = &stdin.interface;

    // Each answer goes into this buffer. The operating system gets one write
    // each time the buffer is full, not one write for each line.
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const out = &stdout.interface;

    const cases = try nextInt(in);
    for (0..@intCast(cases)) |_| try solve(in, out);

    try out.flush();
}
```

*CI builds and runs this program natively, with the input below on stdin. The browser has no stdin to give to the program. (`23-competitive.contest-template`)*

## The problem

The problem is small on purpose. Thus you can look at the template and not at the problem.

The input has this format:

- The first number is the number of test cases.
- Each test case is a count `n`, then `n` integers.

For each case, print the sum of the integers and the largest integer.

CI gives the program this input:

```
3
4
3 -1 4 1
3
1000000000 1000000000
1000000000
5
-5 -2 -9 -1 -3
```

The output must be the same as this text, byte for byte:

```
7 4
3000000000 1000000000
-20 -1
```

Look at the second test case. Its three numbers are on two lines. A judge can do this. The problem statement tells you the tokens and their order. It does not tell you the line of each token.

## Read tokens, not lines

The other chapters read a line with `takeDelimiter` and split the line. That method works when you write the input yourself. On a judge, a reader that expects three numbers on one line fails on the second test case above.

Thus the template reads one integer at a time. It uses the same rule for each type of whitespace:

```zig
/// Skip whitespace, then read one integer.
///
/// The function reads one byte at a time and does not examine line breaks.
/// Thus the layout of the input has no effect. A judge tells you the tokens
/// and their order, not the line of each token.
fn nextInt(in: *std.Io.Reader) !i64 {
    var c = try in.takeByte();
    while (c == ' ' or c == '\n' or c == '\r' or c == '\t') c = try in.takeByte();

    const negative = c == '-';
    if (negative) c = try in.takeByte();
    if (c < '0' or c > '9') return error.NotANumber;

    var value: i64 = 0;
    while (true) {
        value = value * 10 + (c - '0');
        c = in.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (c < '0' or c > '9') break;
    }
    return if (negative) -value else value;
}
```

*Quoted from the source: `nextInt` from `snippets/23-competitive/contest-template.zig`.*

`takeByte` returns the next byte from the buffer of the reader. It asks the operating system for more bytes only when the buffer is empty. The buffer here is 64 KB. Thus a large input costs one system call for each 64 KB, not one for each number.

The parser does not make a string for each number. For each byte, it multiplies the value by ten and adds the digit. For this reason, the code does not use `std.fmt.parseInt`: it needs the number as a slice first.

The input can end where the parser reads the byte after the last digit. At that position, `EndOfStream` only means that the file stopped immediately after a number. This is normal, thus the loop stops. At a different position, the end of the input is an error, and the program stops.

## Stdin is one more reader

```zig
pub fn main(init: std.process.Init) !void {
    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    const in = &stdin.interface;

    // Each answer goes into this buffer. The operating system gets one write
    // each time the buffer is full, not one write for each line.
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const out = &stdout.interface;

    const cases = try nextInt(in);
    for (0..@intCast(cases)) |_| try solve(in, out);

    try out.flush();
}
```

*Quoted from the source: `main` from `snippets/23-competitive/contest-template.zig`.*

`std.Io.File.stdin().readerStreaming` puts standard input behind the same `std.Io.Reader` interface that the other chapters use. `nextInt` takes a `*std.Io.Reader` and does not know where the bytes come from.

For this reason, each other chapter parses through a reader, and does not cut its `const` string into slices by hand. To move one of those solutions to a judge, replace the reader and nothing else.

[Readers and Writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/) explains the interface.

## Write one time, at the end

The output also goes through a 64 KB buffer. `print` copies the answer into the buffer. The operating system gets a write only when the buffer is full, or when you call `flush`.

A problem with 200,000 answers of approximately 20 bytes each writes 4 MB. That output needs approximately 60 writes. Without a buffer, each line is a separate system call. This is a common cause when a correct solution fails the time limit.

The cost is that no output appears until you flush. If the program returns early without a flush, the program loses the answers in the buffer.

[Readers and Writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/) shows that failure.

## Size storage from the bound

Each contest statement gives limits, for example `1 ≤ n ≤ 200 000`. The template changes the limit into a constant and a fixed array:

```zig
/// The largest `n` that the problem allows. Contest statements always give
/// this limit. If the storage size comes from the limit, the program does not
/// allocate memory.
const max_n = 200_000;
```

*Quoted from the source: `max_n` from `snippets/23-competitive/contest-template.zig`.*

```zig
/// The declaration is at container level, not inside `main`.
///
/// 200,000 values of 8 bytes is 1.6 MB. A local array is on the stack. On
/// Linux the stack is usually 8 MB, and on a judge it is frequently smaller.
/// Thus a bound ten times larger crashes before the first read. A global is
/// in the zeroed data of the program, and each test case uses it again.
var values: [max_n]i64 = undefined;
```

*Quoted from the source: `values` from `snippets/23-competitive/contest-template.zig`.*

The declaration of the array is outside `main` on purpose. A local array is on the stack. On Linux, the stack of the main thread is usually 8 MB, and a judge can set a lower limit.

This array is 1.6 MB, thus it fits. If you increase the bound to 2,000,000, the array is 16 MB. Then the program crashes before it reads the first number.

A container-level `var` is in the data of the program. Thus the stack does not limit its size.

Each test case uses the same array again. The program does not allocate memory, and it does not have to free memory between cases.

If the bound is too large for a fixed array, pass an allocator in. Then allocate one time for the largest case. [Allocators](https://www.ziglang.in/learn/standard-library/allocators/) explains this method.

## Choose integer widths from the limits

```zig
/// One test case: the sum of the values and the largest value.
///
/// The sum is `i64` on purpose. The sum of three values of 10^9 is 3 * 10^9,
/// and the maximum value of `i32` is 2,147,483,647.
fn solve(in: *std.Io.Reader, out: *std.Io.Writer) !void {
    const n: usize = @intCast(try nextInt(in));
    if (n == 0 or n > max_n) return error.BadLength;

    const items = values[0..n];
    for (items) |*v| v.* = try nextInt(in);

    var sum: i64 = 0;
    var largest = items[0];
    for (items) |v| {
        sum += v;
        largest = @max(largest, v);
    }
    try out.print("{d} {d}\n", .{ sum, largest });
}
```

*Quoted from the source: `solve` from `snippets/23-competitive/contest-template.zig`.*

The second test case adds three values of 1,000,000,000. The answer is 3,000,000,000. The maximum value of `i32` is 2,147,483,647. Thus the sum is an `i64`, but each value alone fits in an `i32`.

Use this rule: multiply the largest value by the largest count, and choose a type that holds the result.

If you choose the wrong type, the result depends on the build mode:

- A safe build stops with an overflow panic.
- A `ReleaseFast` build, which is the build that you submit, has no check. The language does not define the result.

[Integer Rules](https://www.ziglang.in/learn/language-basics/integer-rules/) explains the widths and the overflow operators.

## Before you submit

Build with `-O ReleaseFast`. A Debug build keeps all of the safety checks and does no optimization. Thus a Debug build can be many times slower.

Find which Zig version the judge has, if the judge has Zig. This guide uses Zig master. A judge with an older release can reject much of this code.

[What Changed in Zig 0.17](https://www.ziglang.in/learn/getting-started/zig-0-17/) and [Migrate from an Older Zig](https://www.ziglang.in/learn/getting-started/coming-from-older-zig/) list the differences.
