# printf

> How to change a number into text, one digit at a time, from the last digit to the first.

Each tool before this one moved bytes that already existed. `printf` makes new
bytes. For the number 42, some code must make the two characters `4` and `2`.
Nothing in the computer does this for you. 42 is a bit pattern, `"42"` is two
bytes, and you write the arithmetic for the conversion.

The algorithm is division:

1. Divide the number by ten.
2. The remainder is the last digit.
3. The quotient is the rest of the number.
4. Do the steps again until the quotient is zero.

These steps give you all the digits correctly, but in reverse order, because
you get the last digit first.

Thus write the digits into the **end** of a buffer, and move to the front.
When you stop, the number is the tail of the buffer. Return a slice from the
position where you stopped. You never have to reverse the digits in a second
pass.

## The program

```zig
const std = @import("std");

/// Write `value` as decimal into `buf`, and return the part that it used.
///
/// The digits come out in reverse. The only cheap way to get a digit is
/// `value % 10`, and that gives you the *last* digit. Thus the function writes
/// the digits into the end of the buffer. It takes the slice from the
/// position where it stopped.
fn decimal(buf: []u8, value: i64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    const negative = value < 0;
    // Negate in a wider type. The most negative i64 has no positive
    // equivalent, so `-value` in the same type is an overflow. Printf code
    // that people write by hand often gets this wrong.
    var n: u64 = if (negative) @as(u64, @intCast(-@as(i128, value))) else @intCast(value);

    var i = buf.len;
    while (n > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    if (negative) {
        i -= 1;
        buf[i] = '-';
    }
    return buf[i..];
}

/// The scanner: copy bytes until '%', then dispatch on the next byte.
fn format(out: *std.Io.Writer, comptime fmt: []const u8, args: []const i64) !void {
    var arg: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%') {
            try out.writeByte(fmt[i]);
            continue;
        }
        i += 1;
        if (i == fmt.len) break;
        switch (fmt[i]) {
            'd' => {
                var digits: [24]u8 = undefined;
                try out.writeAll(decimal(&digits, args[arg]));
                arg += 1;
            },
            // With %%, you print the character that the scanner looks for.
            '%' => try out.writeByte('%'),
            else => {
                // Unknown specifier: print it back. Do not guess.
                try out.writeByte('%');
                try out.writeByte(fmt[i]);
            },
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var digits: [24]u8 = undefined;
    for ([_]i64{ 0, 7, 42, -1, 1234567890, std.math.minInt(i64) }) |n| {
        try out.print("{s}\n", .{decimal(&digits, n)});
    }
    try out.writeAll("\n");

    try format(out, "%d + %d = %d\n", &.{ 2, 3, 5 });
    try format(out, "100%% of %d\n", &.{7});
    try format(out, "unknown %q stays put\n", &.{});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`16-unix-tools.printf`)*

## What just happened

**Zero needed its own line of code.** The loop runs while the value is more
than zero. Thus for zero, the loop never runs, and you get an empty string. An
integer formatter that you write by hand needs this special case at the top.
Without the special case, a count of 0 prints as nothing.

**The most negative number printed correctly.** This is the main trap in this
program. The obvious way to handle a negative number is to keep the sign and
negate: `n = -value`. For `i64`, that works for all values except one.

The range is -9223372036854775808 to 9223372036854775807. Thus the smallest
value has no positive equivalent, and `-value` overflows. In C, that is
undefined behaviour. In practice, C gives you the same negative number back.
After that, the loop makes garbage or does not stop.

The program negates in a wider type before it narrows the value. Thus the
intermediate value has space. In a build with safety checks on, a mistake here
stops the program, and the program does not print nonsense. That is [the main
reason](https://www.ziglang.in/learn/systems-from-scratch/when-checks-are-off/) to develop in a
safety build.

**The scanner is a state machine with two states**: it copies bytes, or it
holds a `%`. A format string needs nothing more. `%%` exists because `%` is
special. Thus you need a way to say that you want the character itself.

**An unknown specifier printed itself back.** `%q` came out as `%q`. The
program did not drop it or guess its meaning. When you cannot know the
intention, print the input without change. This helps the user find the typo.

## Check yourself

The buffer for the digits is 24 bytes. Where does that number come from, and
what occurs if the buffer is too small?

The largest `i64` has 19 digits. With a sign, that is 20, so 24 has more space
than necessary. If the buffer is too small, the writes go past the front of
the buffer. In a safety build, the program catches an index-out-of-bounds. In
a release build, the writes go into memory that you do not own.

You must calculate this buffer size by hand, and the size must be correct.
Thus real implementations write the bound next to the buffer. They do not
select a round number.

## If you know C

You wrote this loop before, and you know the problem of `INT_MIN`:

```c
if (value < 0) { *p++ = '-'; value = -value; }   /* UB at INT_MIN */
```

The usual C fix is to do the arithmetic on a negative accumulator, so that no
negation is necessary. The Zig fix here is to widen first, which is easier to
read.

C also makes you build the argument list. `printf` is variadic, so you need
`va_list`, `va_arg`, and a promise to the compiler. The promise is that the
types in the format string match the arguments that you gave. The language
does not check the promise.

`%d` with a `long` is undefined behaviour. In this way, a `printf` that looks
correct often corrupts a program. Modern compilers give a warning through
`__attribute__((format))`. But compiler authors added that warning later,
outside the language itself.

Zig intentionally has no variadic functions. `std.fmt` takes a tuple, and the
compiler checks the format string against the tuple at compile time. A
mismatch is a build error, not a problem at run time. The chapter about this
is [Formatting](https://www.ziglang.in/learn/standard-library/formatting/).

Next: [make](https://www.ziglang.in/learn/unix-tools/make/), the last tool, and the only tool that is
really an algorithm.
