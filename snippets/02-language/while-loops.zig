//! title: While Loops
//! A condition, an optional continue expression, and `break`/`continue`.

const std = @import("std");
const expect = std.testing.expect;

test "basic while" {
    var i: u8 = 2;
    while (i < 100) {
        i *= 2;
    }
    try expect(i == 128);
}

test "while with a continue expression" {
    // The continue expression runs after every iteration, including ones
    // ended by `continue`, which is why it is not just the last statement.
    var sum: u8 = 0;
    var i: u8 = 1;
    while (i <= 10) : (i += 1) {
        sum += i;
    }
    try expect(sum == 55);
}

test "break and continue" {
    var sum: u8 = 0;
    var i: u8 = 0;
    while (i <= 3) : (i += 1) {
        if (i == 2) continue;
        sum += i;
    }
    try expect(sum == 4); // 0 + 1 + 3
}

test "while as an expression with else" {
    // `break x` yields a value; `else` runs when the loop ends normally.
    var i: u8 = 0;
    const found = while (i < 10) : (i += 1) {
        if (i * i > 20) break i;
    } else 0;
    try expect(found == 5);
}
