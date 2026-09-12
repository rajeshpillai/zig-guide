# Running Tests

> Tests are part of the language.

A `test` block is a language construct, not a framework. No imports, no
registration, no annotations.

```zig
const std = @import("std");
const expect = std.testing.expect;

fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "a test is just a named block" {
    try expect(add(2, 2) == 4);
}

test "expectEqual reports both values on failure" {
    try std.testing.expectEqual(@as(i32, 4), add(2, 2));
}

test "comparing slices" {
    try std.testing.expectEqualStrings("abc", "ab" ++ "c");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2 }, &[_]u8{ 1, 2 });
}

test "asserting an error is returned" {
    const failing = struct {
        fn f() error{Nope}!void {
            return error.Nope;
        }
    }.f;
    try std.testing.expectError(error.Nope, failing());
}

test "the testing allocator fails the test on a leak" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 10);
    defer gpa.free(buf); // remove this line and the test fails
    try expect(buf.len == 10);
}

test "skipping" {
    if (@import("builtin").cpu.arch != .wasm32) return error.SkipZigTest;
    try expect(true);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`01-getting-started.running-tests`)*

## Running them

```bash
zig test file.zig        # just this file
zig build test           # the test step of a build.zig
zig test file.zig --test-filter "name"
```

Tests in a file only run if that file is the test root or is reachable from it
via `@import`. A test in a module nobody imports never runs, which is worth
knowing when a test you expected to fail stays quiet.

## The assertion helpers

| Helper | Use |
| --- | --- |
| `expect(bool)` | general condition |
| `expectEqual(a, b)` | prints both values on failure |
| `expectEqualStrings` | string comparison with a readable diff |
| `expectEqualSlices(T, a, b)` | slice comparison |
| `expectError(err, expr)` | asserts a specific error |

Prefer `expectEqual` over `expect(a == b)`: when it fails, it tells you what
the values actually were.

## Leak detection is on by default

`std.testing.allocator` fails the test if anything it allocated was not freed.
This is not an optional tool you remember to run. Every test that allocates is
a leak test:

```zig
const buf = try std.testing.allocator.alloc(u8, 10);
defer std.testing.allocator.free(buf);   // omit this and the test fails
```

## Skipping

`return error.SkipZigTest` marks a test skipped rather than failed. It is the
way to handle a test that only applies to some targets.

## Where to put them

Next to the code they test, in the same file. That is the convention in the
standard library and it is worth following, for two reasons that are easy to
miss.

The test can reach private declarations, because privacy is per file. A helper
that is not `pub` has no other way to be tested. Moving tests to a separate
file pushes you toward making things public that should not be.

And the test is read as the example. Someone opening the file to work out how
a function is called finds a call, with real arguments and a checked result, a
few lines below the definition. Documentation in a separate directory does not
get read that way.

Tests are not compiled into your program. A `test` block only exists in a
build produced by `zig test` or a test step. So there is no cost to leaving
them in place, and no reason to move them at release time.

## Naming them

The name is a plain string, so write a sentence:

```zig
test "parseInt rejects a trailing space" { ... }
```

That name is what the runner prints on failure and what `--test-filter`
matches, so a description of the behaviour is more useful than a label.
Reading a failing test's name and knowing what broke, without opening the
file, is the whole benefit.

## Reading a failure

A failed assertion prints the values, then a stack trace pointing at the line.
The trace is the useful part and it is only there because tests are built in
Debug by default, with safety checks on. That is also why a test can catch an
out-of-bounds index that a release build would let through.

## These pages are the tests

Every snippet in this guide is compiled and run by CI, and the `test` ones
report through this same runner. The output you see when you press Run is the
real `zig test` output, executed in your browser as WebAssembly.

There is more in [testing](https://www.ziglang.in/learn/standard-library/testing/). The assertions
that report what actually differed. Checking that error paths clean up after
themselves. And why the testing allocator turns every test into a leak test.
