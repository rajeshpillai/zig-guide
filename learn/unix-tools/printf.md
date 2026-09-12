# printf

> Turning a number into text, digit by digit, backwards.

Every tool so far moved bytes that already existed. `printf` makes them. Given
the number 42, something has to produce the two characters `4` and `2`, and
nothing in the machine does that for you. 42 is a bit pattern, `"42"` is two
bytes, and the conversion is arithmetic you write.

The algorithm is division. The last digit of a number is what is left after
dividing by ten, and the rest of the number is the quotient. Repeat until the
quotient is zero. That gives you every digit, correctly, in exactly the wrong
order, because it hands you the last one first.

So you write them into the **end** of a buffer and work backwards. When you
stop, the number is the tail of the buffer, and you return a slice from where
you stopped. No reversing step, no second pass.

## The program

```zig
const std = @import("std");

/// Write `value` as decimal into `buf`, returning the part used.
///
/// The digits come out in reverse because the only cheap way to get one is
/// `value % 10`, which hands you the *last* one. So they are written into the
/// end of the buffer and the slice is taken from where you stopped.
fn decimal(buf: []u8, value: i64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    const negative = value < 0;
    // Negate in a wider type. On the most negative i64 there is no positive
    // counterpart, so `-value` in the same type is an overflow, and this is
    // the trap every hand-written printf has fallen into at least once.
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

/// The scanner: copy bytes through until '%', then dispatch on the next one.
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
            // %% is how you print the character the scanner is looking for.
            '%' => try out.writeByte('%'),
            else => {
                // Unknown specifier: print it back rather than guessing.
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

**Zero needed its own line of code.** The loop runs while the value is greater
than zero, so for zero it never runs and you get an empty string. Every
hand-written integer formatter has this special case at the top, and every one
that does not has shipped a bug where a count of 0 printed as nothing.

**The most negative number printed correctly**, and that is the trap this
chapter exists for. The obvious way to handle a negative is to note the sign
and negate: `n = -value`. For `i64` that works for every value except one. The
range is -9223372036854775808 to 9223372036854775807, so there is no positive
counterpart to the smallest, and `-value` overflows. In C that is undefined
behaviour and in practice gives you the same negative number back, after which
the loop produces garbage or spins.

The program negates in a wider type before narrowing, so the intermediate
value has room. In a build with safety checks on, getting this wrong stops the
program instead of printing nonsense, which is [the whole
argument](https://www.ziglang.in/learn/systems-from-scratch/when-checks-are-off/) for developing in
one.

**The scanner is a state machine with two states**: copying bytes, and holding
a `%`. That is all a format string is. `%%` exists because once `%` is special
you need a way to say you meant the character.

**An unknown specifier printed itself back.** `%q` came out as `%q` rather than
being swallowed or guessed at. When you cannot know what was intended, showing
the input unchanged is the behaviour that helps someone find their typo.

## Check yourself

The buffer for the digits is 24 bytes. Where does that number come from, and
what happens if it is too small?

The largest `i64` is 19 digits, plus a sign is 20, so 24 has room to spare. If
it were too small, the writes would run off the front of the buffer. In a
safety build that is a caught index-out-of-bounds. In a release build it is
memory you do not own. Sizing this buffer is exactly the kind of arithmetic
you must do by hand and get right once. That is why real implementations write
the bound next to the buffer rather than picking a round number.

## If you have written C

You have written this loop, and you have met `INT_MIN`:

```c
if (value < 0) { *p++ = '-'; value = -value; }   /* UB at INT_MIN */
```

The usual C fix is to do the arithmetic on a negative accumulator instead, so
no negation is needed. Zig's fix here is to widen first, which reads more
directly.

The other thing C makes you build is the argument list. `printf` is variadic,
which means `va_list`, `va_arg`, and a promise you make to the compiler that
the types in the format string match what you passed. Nothing checks it: `%d`
with a `long` is undefined behaviour, and it is the single most common way a
correct-looking `printf` corrupts a program. Modern compilers warn via
`__attribute__((format))`, which is a warning bolted onto a hole in the
design.

Zig has no variadic functions on purpose. `std.fmt` takes a tuple, and the
format string is checked at compile time against it, so a mismatch is a build
error rather than a runtime surprise. The chapter on that is
[Formatting](https://www.ziglang.in/learn/standard-library/formatting/).

Next: [make](https://www.ziglang.in/learn/unix-tools/make/), the last tool and the only one that is
really an algorithm.
