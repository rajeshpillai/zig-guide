# Generate Documentation

> Doc comments, and the site that Zig makes from them.

Zig makes HTML documentation from doc comments.

```bash
zig build-lib src/root.zig -femit-docs
zig build docs        # if your build.zig declares it
```

## The comment forms

| Syntax | Attaches to |
| --- | --- |
| `///` | the declaration that follows |
| `//!` | the file or module that contains it (must be at the top) |
| `//` | ordinary comment, not documentation |

```zig
//! A module for working with points.

/// A point in two dimensions.
pub const Point = struct {
    /// Horizontal position, in pixels.
    x: i32,
};
```

Doc comments are Markdown. Only `pub` declarations are in the output.

If a `///` comment is in a position where it cannot attach to a declaration, the result is a compile error, not a warning. Thus, if a doc comment becomes separate from its declaration, the compiler tells you.

## The output

The generator does one thing. It copies the signature from the source and puts your `///` text below the signature.

```
Source

  /// Adds two integers.
  pub fn add(a: i32, b: i32) i32 { ... }

        │
        │  zig build-lib -femit-docs
        ▼

Generated page

  add(a: i32, b: i32) i32
  Adds two integers.
```

The signature is already on the page. The generator makes the signature from the code, thus the signature is always correct. If your comment repeats the signature, the comment can become incorrect, and the generated signature above it stays correct.

## In `build.zig`

```zig
const docs = b.addInstallDirectory(.{
    .source_dir = lib.getEmittedDocs(),
    .install_dir = .prefix,
    .install_subdir = "docs",
});
b.step("docs", "Generate documentation").dependOn(&docs.step);
```

## What to write in a doc comment

The generated page already shows the signature. Thus do not repeat the signature in prose. Write what the signature cannot show and what a caller must know:

- **The owner of the return value.** If the function allocates, tell which allocator frees the memory and when. In most doc comments, this sentence is the most useful one.
- **The meaning of the errors.** The error set is visible. The cause of each error in the set is not visible.
- **The constraints that the type cannot express.** For example, a slice must be in sorted order, two lengths must be equal, or a pointer must stay valid during the call.
- **The cost**, when the cost is not clear. O(n) and O(1) change how a caller uses the function.

In the example above, "Adds two integers" tells the reader nothing new. The reader can see that from `add(a: i32, b: i32) i32`. The signature cannot tell the reader that the addition has an overflow check, and that it panics on overflow and does not wrap. Write that sentence instead.

## Only `pub` declarations are in the output

Thus the doc build is a check of your interface. When you generate the docs, you can find problems in the public list. For example, the list can show a type that you wanted to keep private, or a helper without a comment. Without the docs, you possibly never examine that list.

The output is a static site: HTML, the source and a search index. The site needs no server, and you can publish it at any location that can hold files. The `addInstallDirectory` call above installs the site for that purpose.

## Doctests

Tests are ordinary language constructs. Thus a `test` block next to a function is both a test and an example. A comment can become incorrect without a message from the build, but a test cannot. This full guide uses the same method.

Give a test the name of the function that it tests, for example `test myFunction { ... }`. The name connects the test and the function. Thus the example stays with the documentation. It is not in a separate file that nobody updates.

Use a test as the main form of documentation, not as an extra. A prose example in a comment tells how the function behaves, but nothing checks the example. Someone wrote the example for the signature on one day. A test that says the same thing gets a check on each build. The two disagree eventually. When the two disagree, the test is correct.
