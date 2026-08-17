//! title: Wrapping and Saturating Arithmetic
//! When the wrap is what you want, ask for it: `+%`, `+|`, `@addWithOverflow`.

const std = @import("std");
const expect = std.testing.expect;

test "+% wraps, and says so at the call site" {
    var x: u8 = 255;
    _ = &x;
    // `x + 1` is the checked add and stops the program. `+%` is a different
    // operator with a defined answer, in every build mode.
    try expect(x +% 1 == 0);
}

test "+| saturates at the limit instead" {
    var x: u8 = 250;
    _ = &x;
    try expect(x +| 10 == 255);
}

test "@addWithOverflow reports rather than stops" {
    var x: u8 = 255;
    _ = &x;
    // A tuple: the wrapped value, and a u1 that is 1 when it overflowed.
    const result = @addWithOverflow(x, 1);
    try expect(result[0] == 0);
    try expect(result[1] == 1);
}
