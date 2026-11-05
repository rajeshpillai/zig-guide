# Labelled Blocks

> Blocks that produce a value.

In Zig, a labelled block computes a `const` with more than one statement. The block ends with `break :blk value`. The scope of the intermediate variables in the block ends at the closing brace.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "block as an expression" {
    // `break :label value` gives a value from the labelled block. Thus a
    // computation with many steps can still produce one const.
    const count = blk: {
        var sum: u32 = 0;
        for (0..10) |i| sum += i;
        break :blk sum;
    };
    try expect(count == 45);
    try expect(@TypeOf(count) == u32);
}

test "labels also name scopes for shadowing" {
    const outer_value: u32 = 1;
    const result = blk: {
        const outer_value_inner: u32 = 2;
        break :blk outer_value + outer_value_inner;
    };
    try expect(result == 3);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.labelled-blocks`)*

Give a label to a block, and use `break` with a value to leave the block:

```zig
const count = blk: {
    var sum: u32 = 0;
    for (0..10) |i| sum += i;
    break :blk sum;
};
```

You can use any name instead of `blk`. The important point is that a computation with many statements still produces one `const`. Thus the intermediate `var` cannot be visible in the outer scope, and you cannot use it again by accident later.

Use a labelled block when you need a few lines to compute a value, and you want the result to be immutable. Without a labelled block, programmers often use a mutable variable with a scope that is wider than necessary. Or they write a function that they use only one time.

## The label makes the block an expression

A block without a label is a statement. It groups code and starts a scope, but it has no value. The label gives `break` a name to use. The statement `break :blk x` gives the block a type. If you remove the label, you cannot get `x` out of the block.

The compiler also checks the opposite case. A label that no `break` uses is an error:

```
error: unused block label
```

[Labelled loops](https://www.ziglang.in/learn/language-basics/labelled-loops/) get the same error, for the same reason. Usually, an unused label is a part of control flow that a programmer deleted, and the label stayed.

## `break :blk` is not `return`

In a block inside a function, it is easy to confuse the two statements. They do different things:

- `break :blk x` ends the block and gives `x` to the variable that receives the value of the block.
- `return x` ends the *function*.

Think of a block that computes one field of a struct. With `break`, the program sets the value of that field. With `return`, the program stops the construction of the full struct.

Blocks can be inside other blocks, and a `break` names the block that it leaves. Thus an inner block can break to an outer label and skip all the code between the two. In this case the code can be difficult to read. To make the code clear, select a good label name. A comment does not help as much.

## The block is a scope

The second test in the snippet shows this rule. The scope of each declaration inside the braces ends at the closing brace. This includes the `var` that did the work. Only the value that `break` gives out of the block continues to exist, and that value is a `const`.

This limit on scope is the real reason to use a labelled block. Compare the code without a block:

```zig
var sum: u32 = 0;
for (0..10) |i| sum += i;
// sum is mutable, in scope, and still writable fifty lines later
```

In this code, a mutable variable stays alive for the remainder of the function. Nothing shows that the code no longer writes to `sum`. A person who edits the function later must read all of it to know if the code still adds values to `sum`. In the block form, the closing brace gives the answer.

## Where real code uses labelled blocks

There are three usual places:

- **A `const` that needs more than one expression.** For example, to parse a value, to select a default, or to add the values in a table.
- **Switch arms that need statements.** When you use a `switch` as an expression, each arm must produce a value. An arm that needs three lines becomes a labelled block.
- **Comptime tables.** Put `comptime` before the block, and the full block runs during compilation. Thus the compiler can make a lookup table, and you do not have to type it:

  ```zig
  const squares = comptime blk: {
      var t: [5]u32 = undefined;
      for (&t, 0..) |*e, i| e.* = @intCast(i * i);
      break :blk t;
  };
  ```

  `squares` is a `[5]u32`, and the binary contains its value. No code runs at startup. The loop that made the table is not in the compiled program.

If you know C, a labelled block is the standard version of the statement expressions in GCC. If you know JavaScript, a labelled block replaces a function that you call immediately only to give a computation a private scope. The labelled block has no function and no call.
