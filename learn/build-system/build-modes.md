# Build Modes

> Four modes, and the cost and the benefit of each one.

Zig has four build modes: `Debug`, `ReleaseSafe`, `ReleaseFast` and `ReleaseSmall`. The modes are different in two ways:

- Some modes keep the runtime safety checks in the binary, and some modes remove them.
- The optimiser makes the code fast in some modes, and small in a different mode.

```zig
const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

test "the current mode is known at compile time" {
    // The build makes these snippets as .small. Master changed the mode tags
    // to lowercase: .Debug/.ReleaseSafe/.ReleaseFast/.ReleaseSmall are now
    // .debug/.safe/.fast/.small.
    try expect(builtin.optimize == .small);
}

test "safety checks follow the mode" {
    // True in .debug and .safe. False in .fast and .small.
    const safety_on = switch (builtin.optimize) {
        .debug, .safe => true,
        .fast, .small => false,
    };
    try expect(!safety_on); // because this build is .small
}

test "safety can be forced back on for a scope" {
    // Use this call to keep the bounds checks in one risky function of a
    // ReleaseFast build.
    @setRuntimeSafety(true);
    var index: usize = 1;
    _ = &index;
    const array = [_]u8{ 1, 2, 3 };
    try expect(array[index] == 2);
}

test "branch hints and unreachable" {
    // In safety builds, `unreachable` panics. In ReleaseFast, `unreachable`
    // is a promise to the optimiser. If the program gets to it, the result
    // is illegal behaviour.
    const value: u8 = 2;
    switch (value) {
        1, 2, 3 => {},
        else => unreachable,
    }
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`04-build-system.build-modes`)*

| Mode | Safety checks | Optimised | Size |
| --- | --- | --- | --- |
| `Debug` | yes | no | large |
| `ReleaseSafe` | yes | yes | medium |
| `ReleaseFast` | **no** | yes | medium |
| `ReleaseSmall` | **no** | yes | small |

Select the mode with `-O`:

```bash
zig build-exe main.zig -OReleaseSafe
zig build -Doptimize=ReleaseSafe
```

## The purpose of each mode

- **`Debug`** is the default. Use it while you develop. The compiler does almost no optimisation, thus the compilation is fast. All safety checks are on. The compiler fills `undefined` memory with `0xaa`, thus a read of memory without a value is easy to see. The binaries are large and the code is slow. That is not a problem while you edit the code.
- **`ReleaseSafe`** is the mode to ship, if you do not have a reason to use a different mode. It has full optimisation, and it keeps the checks.
- **`ReleaseFast`** removes the checks. Use it when a measurement shows that the checks make the program too slow. That occurs less frequently than people expect.
- **`ReleaseSmall`** makes the code small instead of fast, and it also removes the checks. Embedded targets use this mode. This site also uses it. A snippet here is about 60 KB. The same snippet in `ReleaseSafe` is more than one megabyte. The browser of the reader must download the file before the snippet can run.

These numbers come from measurements of this project. They are not estimates. Thus only five snippets on this site use `.safe`. These five snippets show a panic, and the panic is the lesson.

## Use `ReleaseSafe` more frequently

In C and C++, a release build is usually a build without checks. Zig keeps the two choices separate. `ReleaseSafe` has optimisation, *and* it keeps the bounds checks, the overflow checks and the null-unwrap checks. For most software, the cost is small. Without the checks, memory can become corrupt and nothing tells you.

Use `ReleaseFast` when you measured that the checks are important to the speed. Do not use it as the default.

The two costs are very different:

- A check that stays in the binary costs a compare and a predictable branch. On modern hardware, that cost is almost zero, unless the speed of the code is already limited by memory.
- A check that the compiler removes costs nothing until an index is wrong. Then the cost is a corrupt heap and a bug that you cannot reproduce.

Thus a default without checks is a bad exchange. You remove a small cost that you always pay, and you get a large cost that occurs rarely. For decades, C and C++ gave no other choice.

## When the checks go, the rules stay

In `ReleaseFast` and `ReleaseSmall`, an index out of bounds is **illegal behaviour**. Illegal behaviour is the same category as undefined behaviour in C. The check only reported that the code broke the rule. When you remove the check, the rule stays. If code works only because Debug found the panic, the code is already wrong.

If a program works in ReleaseFast, the result does not show that the program is correct. It only shows that nothing found the problem until now. The optimiser can assume that the code obeys the rules. The optimiser uses that assumption to delete branches that you think are in the code.

## Change the mode for one scope

```zig
@setRuntimeSafety(true);
```

This call keeps the checks in one function of a build that has no other checks. Use it for a function that parses input that you cannot trust.

The opposite also works: put `@setRuntimeSafety(false)` in one hot function of a safe build. Use this approach when you can. The unsafe code stays small, and it is easy to find and examine. The other approach removes the checks from the full program to make one loop faster.

## Get the mode at compile time

`@import("builtin").optimize` is a comptime value. Thus code for one mode has no cost at runtime: the compiler does not compile the branch that cannot run.

The tags are lowercase: `.debug`, `.safe`, `.fast`, `.small`. Before, the tags were `.Debug`, `.ReleaseSafe`, `.ReleaseFast` and `.ReleaseSmall`. Thus a comparison from an older tutorial does not compile.

The name of the field also changed from `mode` to `optimize`. `builtin.mode` still works at this time, and the std source marks it for removal after 0.18.0. On the command line, both forms work: `-O ReleaseFast` and `-O fast` make the same build.

Because the mode is a comptime value, expensive assertions are practical. You can put a check of a full data structure behind `if (builtin.optimize == .debug)`. In a release build, that check is not in the binary.

`std.debug.assert` is a different tool. It becomes `unreachable`. Thus it follows the safety checks and not the name of the mode, and it still fires in `ReleaseSafe`.
