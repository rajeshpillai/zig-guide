# Testing

> The assertions other than expect, and the allocator that finds leaks.

Zig tests are `test` blocks, and `zig test` runs them. `std.testing` supplies the assertions, for example `expectEqual` and `expectError`. It also supplies `std.testing.allocator`, which fails a test that leaks memory.

```zig
const std = @import("std");

test "expectEqual prints both values on failure" {
    // expect(a == b) tells you only "false". expectEqual tells you
    // expected 42, found 41. The expected value comes first.
    try std.testing.expectEqual(42, 41 + 1);
    try std.testing.expectEqual(@as(?u8, null), null);
}

test "slice and string comparisons show where they diverge" {
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &.{ 1, 2, 3 });

    // On failure, this assertion prints the two strings and the index of the
    // first byte that is different.
    try std.testing.expectEqualStrings("hello", "hel" ++ "lo");

    try std.testing.expectStringStartsWith("zig build verify", "zig build");
}

fn parseDigit(c: u8) !u4 {
    if (c < '0' or c > '9') return error.NotADigit;
    return @intCast(c - '0');
}

test "expectError asserts the failure path" {
    // If no test runs an error path, the path can break and nobody sees it.
    // expectError makes the error path a normal assertion.
    try std.testing.expectError(error.NotADigit, parseDigit('x'));
    try std.testing.expectEqual(7, try parseDigit('7'));
}

test "floats compare within a tolerance" {
    const third: f64 = 1.0 / 3.0;
    // Never use == on calculated floats. Give the tolerance that you accept.
    try std.testing.expectApproxEqAbs(0.333, third, 0.001);
    try std.testing.expectApproxEqRel(1.0, third * 3.0, std.math.floatEps(f64));
}

const Config = struct {
    name: []const u8,
    retries: u8,
};

test "expectEqualDeep follows pointers and slices" {
    const a = Config{ .name = "prod", .retries = 3 };
    const b = Config{ .name = "prod", .retries = 3 };

    // expectEqual on these structs compares the slice pointers.
    // expectEqualDeep compares the data that the slices point at.
    try std.testing.expectEqualDeep(a, b);
}

test "expectFmt checks formatted output" {
    try std.testing.expectFmt("0x00ff", "0x{x:0>4}", .{255});
}

test "the test allocator reports leaks" {
    // std.testing.allocator fails the test if memory is still allocated
    // when the test returns. If you forget this free, the test fails with
    // a stack trace of the leaked allocation.
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 64);
    defer gpa.free(buf);

    // The allocator also finds a double free and a use after free in test builds.
    try std.testing.expect(buf.len == 64);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.testing`)*

## expect tells you nothing, and the others tell you what failed

When `try std.testing.expect(a == b)` fails, it says "expected true, found false". Then you must add print statements. The typed assertions put the values into the failure message:

| Assertion | Reports on failure |
| --- | --- |
| `expectEqual(expected, actual)` | both values |
| `expectEqualStrings` | both strings and the first differing byte |
| `expectEqualSlices(T, ...)` | both slices and the diverging index |
| `expectError(err, expr)` | which error, or that none was returned |

By convention, the expected value comes first. `expectEqual` gets its type from that first argument. For this reason, `@as(?u8, null)` sometimes needs the cast: the cast tells the comparison the type of `null`.

## Assert the error paths too

Bugs hide in failure paths that have no tests. With `expectError`, "this input is rejected" becomes a normal assertion. You can check it as easily as the success case. A parser test must check the digit that the parser accepts, and also the character that it refuses.

## Floats need a tolerance

Never compare calculated floats with `==`. Use one of these assertions:

- `expectApproxEqAbs` takes an absolute tolerance, for values near a known magnitude.
- `expectApproxEqRel` takes a relative tolerance.

`std.math.floatEps(f64)` is the natural limit for "as close as the type permits."

## expectEqualDeep for structures

Take two structs that hold slices. `expectEqual` on these structs compares the slice pointers, and almost always you do not want that. `expectEqualDeep` follows pointers and slices, and compares the content that they point at.

## The allocator is a test

`std.testing.allocator` fails the test if memory from the allocator is still live when the test returns. Thus, if you forget a `free`, the test fails. The leak does not become a slow leak in production.

The allocator also panics on a double free, on a free through the wrong allocator, and on most writes after a free. Put a `defer free` after each allocation, and let the allocator check them.

Use this allocator in each test. Memory bugs are frequently difficult to reproduce. A memory bug can stay hidden in the test that caused it, and it can cause a production incident weeks later. A test that uses this allocator is also a leak test, with no extra code.

`std.testing.checkAllAllocationFailures` does more. It runs your function again and again. Each time, the allocator fails at a different call, and the function checks that each partial failure still releases its memory. That test is too tedious to write by hand. It is the only way to know if your chain of `errdefer` statements is correct.

## How zig test finds and runs tests

A `test` block is a top-level declaration. `zig test` compiles the file into a runner, and the runner executes each test that it can see. "Can see" follows a rule. The compiler never compiles the tests in a file that no other file imports. Thus, when you add a test file to the tree, it does not run until other code imports it.

Put `std.testing.refAllDecls(@This())` at the bottom of a file to make the compiler analyse each declaration. This call includes the tests of imported files. It also finds code that does not compile now, but that no code calls at the moment.

`zig build test --test-filter <substring>` runs only the tests whose names match. Use it when you work on one failure again and again. Test names are plain strings. Thus it helps to write them as sentences that describe the behaviour. For example, a filter on `"rejects"` finds each negative case.

## Tests are documentation that is always current

A `test` next to the function that it uses is the usage example. A comment can become incorrect, but a test fails the build when it is no longer true. For that reason, the standard library has many of these tests, and your code can do the same. A reader who looks at an unfamiliar function reads the test before the doc comment, because the test cannot be out of date.

This site works in the same way. Before the site publishes a page, CI compiles and runs each snippet on the page. The guarantee is the same, on a larger scale. See [how CI verifies this guide](https://www.ziglang.in/verification/).

## Skipped tests and expected failures

`return error.SkipZigTest` skips a test at runtime. Use it for a case that applies only on some targets. The runner reports the test as skipped, not as passed. Thus a test that is always skipped stays visible in the output.

For code that must not compile, there is no assertion to write. The compile error already fails the build. When the type rejects a misuse, do not write that misuse in a test. Trust the type.
