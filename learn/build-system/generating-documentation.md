# Generating Documentation

> Doc comments and the generated site.

Zig generates HTML documentation from doc comments.

```bash
zig build-lib src/root.zig -femit-docs
zig build docs        # if your build.zig declares it
```

## The comment forms

| Syntax | Attaches to |
| --- | --- |
| `///` | the declaration that follows |
| `//!` | the enclosing file/module (must be at the top) |
| `//` | ordinary comment, not documentation |

```zig
//! A module for working with points.

/// A point in two dimensions.
pub const Point = struct {
    /// Horizontal position, in pixels.
    x: i32,
};
```

Doc comments are Markdown, and only `pub` declarations appear in the output.

A `///` comment in a position where it cannot attach to anything is a compile
error, not a warning. So a doc comment cannot become separated from the
declaration it describes without the compiler noticing.

## What comes out

The generator does one thing: it copies the signature from the source and
puts your `///` text under it.

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

The signature is already on the page. It is generated from the code, so it is
always correct. If your comment repeats the signature, that line can go out of
date while the generated signature above it stays right.

## In `build.zig`

```zig
const docs = b.addInstallDirectory(.{
    .source_dir = lib.getEmittedDocs(),
    .install_dir = .prefix,
    .install_subdir = "docs",
});
b.step("docs", "Generate documentation").dependOn(&docs.step);
```

## What to write in one

The generated page already shows the signature, so do not repeat it in prose.
Write what the signature cannot show but a caller needs to know:

- **Who owns the return value.** If it allocates, say which allocator frees it
  and when. In most doc comments, this is the most useful sentence.
- **What the errors mean.** The error set is visible. What causes each member is
  not.
- **The constraints the type cannot express.** That a slice must be sorted, that
  two lengths must match, that a pointer must stay alive for the call.
- **What it costs**, when it is not obvious. O(n) versus O(1) changes how the
  function is used.

In the example above, "Adds two integers" tells the reader nothing new: they
can see that from `add(a: i32, b: i32) i32`. The signature cannot say that the
addition is checked and will panic on overflow instead of wrapping. Write that
sentence instead.

## Only `pub` appears

So the doc build is a check on your interface. Generate the docs and you may
find a type you meant to keep private, or a helper with no comment in the
public list. Without the docs, you might never review that list.

The output is a static site: HTML, plus the source, plus a search index. It
needs no server, and you can publish it anywhere you can put files. The
`addInstallDirectory` call above installs it for that.

## Doctests

Because tests are ordinary language constructs, a `test` block next to a
function serves as both a test and an example. Unlike a comment, it cannot go
out of date without the build noticing. This whole guide works the same way.

Naming a test after the function it exercises, `test myFunction { ... }`,
links the two. The example stays with the documentation instead of sitting in
a separate file that nobody updates.

Treat a test as the main form of documentation, not an extra. A prose example
in a comment describes how the function behaves, but nothing checks it. It was
written against the signature on the day it was typed. A test that says the
same thing is checked on every build. When the two disagree, and eventually
they do, the test is right.
