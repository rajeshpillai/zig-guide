# Testing

> The assertions past expect, and the allocator that catches leaks.

```zig
const std = @import("std");

test "expectEqual prints both values on failure" {
    // expect(a == b) only tells you "false". expectEqual tells you
    // expected 42, found 41. The expected value comes first.
    try std.testing.expectEqual(42, 41 + 1);
    try std.testing.expectEqual(@as(?u8, null), null);
}

test "slice and string comparisons show where they diverge" {
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &.{ 1, 2, 3 });

    // On failure this prints both strings and the first differing index.
    try std.testing.expectEqualStrings("hello", "hel" ++ "lo");

    try std.testing.expectStringStartsWith("zig build verify", "zig build");
}

fn parseDigit(c: u8) !u4 {
    if (c < '0' or c > '9') return error.NotADigit;
    return @intCast(c - '0');
}

test "expectError asserts the failure path" {
    // Untested error paths rot. This makes them first-class assertions.
    try std.testing.expectError(error.NotADigit, parseDigit('x'));
    try std.testing.expectEqual(7, try parseDigit('7'));
}

test "floats compare within a tolerance" {
    const third: f64 = 1.0 / 3.0;
    // Never == on computed floats; state how close is close enough.
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

    // expectEqual on these would compare the slice pointers.
    // expectEqualDeep compares what they point at.
    try std.testing.expectEqualDeep(a, b);
}

test "expectFmt checks formatted output" {
    try std.testing.expectFmt("0x00ff", "0x{x:0>4}", .{255});
}

test "the test allocator reports leaks" {
    // std.testing.allocator fails the test if anything is still
    // allocated when the test returns. Forget this free and the test
    // fails with a stack trace of the leaked allocation.
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 64);
    defer gpa.free(buf);

    // It also detects double-free and use-after-free in test builds.
    try std.testing.expect(buf.len == 64);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.testing`)*

## expect tells you nothing; the others tell you what

`try std.testing.expect(a == b)` fails with "expected true, found false" and
leaves you to add print statements. The typed assertions carry the values into
the failure message:

| Assertion | Reports on failure |
| --- | --- |
| `expectEqual(expected, actual)` | both values |
| `expectEqualStrings` | both strings and the first differing byte |
| `expectEqualSlices(T, ...)` | both slices and the diverging index |
| `expectError(err, expr)` | which error, or that none was returned |

The expected value comes first by convention. `expectEqual` infers its type
from that first argument, which is why `@as(?u8, null)` sometimes needs the
cast: it tells the comparison what type `null` is.

## Assert the error paths too

Untested failure paths are where bugs hide. `expectError` makes "this input is
rejected" a first-class assertion, as checkable as the success case. A parser
test should pin both the digit it accepts and the character it refuses.

## Floats need a tolerance

Never compare computed floats with `==`. `expectApproxEqAbs` takes an absolute
tolerance for values near a known magnitude; `expectApproxEqRel` takes a
relative one, and `std.math.floatEps(f64)` is the natural bound for "as close
as the type allows."

## expectEqualDeep for structures

`expectEqual` on two structs holding slices compares the slice pointers, which
is almost never what you meant. `expectEqualDeep` follows pointers and slices
and compares the pointed-at content.

## The allocator is a test

`std.testing.allocator` fails the test if anything it handed out is still live
when the test returns. A missing `free` is therefore a caught bug rather than
a slow leak in production. In test builds it also detects double-free and
use-after-free. Wire every allocation to a `defer free` and let the allocator
police it.

This is the single highest-value habit in this section. Memory bugs are the
ones that do not reproduce, do not show up in the test that caused them, and
turn into a production incident weeks later. Using the testing allocator
everywhere means every test is also a leak test, at no cost in code.

`std.testing.checkAllAllocationFailures` goes further: it runs your function
repeatedly, failing the allocator at a different call each time, and checks
that every partial failure still cleans up. That is how you find out whether
your `errdefer` ladder is actually right, and it is not a check you could
write by hand.

## How tests are found and run

A `test` block is a top-level declaration, and `zig test` compiles the file
into a runner that executes every one it can see. "Can see" is the part with a
rule behind it. Tests in a file that nothing imports are never compiled, so a
test file added to the tree does not run until something reaches it.

`std.testing.refAllDecls(@This())` at the bottom of a file forces every
declaration to be analysed. That pulls in the tests of imported files, and
also catches code that no longer compiles but that nothing currently calls.

`zig build test --test-filter <substring>` runs the subset whose names match,
which is what you want when iterating on one failure. Test names are plain
strings, so writing them as sentences that describe the behaviour helps here:
filtering on `"rejects"` finds every negative case.

## Tests are documentation that cannot go stale

A `test` next to the function it exercises is the usage example, and unlike a
comment it fails the build when it stops being true. That is why the standard
library is full of them, and it is worth copying. A reader arriving at an
unfamiliar function will read the test before the doc comment, because the
test cannot be lying.

That is also the principle this entire site is built on. Every snippet here is
compiled and run before the page is published, which is the same guarantee at
a larger scale. See [how this guide is verified](https://www.ziglang.in/verification/).

## Skipping and expected failures

`return error.SkipZigTest` skips a test at run time, which is the way to
handle a case that only applies on some targets. The runner reports it as
skipped rather than passed, so a permanently skipped test is visible rather
than silently absent.

For code that should not compile, there is no assertion to write: a compile
error fails the build, which is the point. Testing that a misuse is rejected
is done by not writing it, and by trusting the type.
