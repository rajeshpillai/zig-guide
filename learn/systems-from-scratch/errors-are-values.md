# Errors Are Values

> There is no exception mechanism underneath you, so failure has to be part of what a function returns.

Higher up the stack, failure has somewhere to go. You raise or throw, and
something you did not write unwinds the calls between you and whoever is
prepared to deal with it. It works because a runtime is watching.

Down here nobody is watching. There is no runtime under your program to catch
anything, and the machine has no notion of an exception. So failure has to be
carried the only way anything is carried: as a value, in the return.

Which raises the question that decides how pleasant the language is to use:
**what stops the caller from ignoring it?**

That is not a rhetorical question. It is the actual difference between error
handling that works and error handling that everybody agrees is important and
nobody does. If ignoring a failure is a keystroke shorter than handling it, it
gets ignored, and the program carries on with a number that means "this did
not happen".

Zig's answer is to put the failure in the **type**. A function that can fail
does not return a `u16`. It returns "either a `u16` or an error", and those
are different types. You cannot use the first without saying what happens in
the second, because until you do, you do not have a `u16` at all.

## The program

```zig
const std = @import("std");

/// The return type says two things: on success a u16, on failure one of a
/// known set of errors. A caller can see both without reading the body.
fn parsePort(text: []const u8) !u16 {
    const value = try std.fmt.parseInt(u16, text, 10);
    if (value < 1024) return error.ReservedPort;
    return value;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const inputs = [_][]const u8{ "8080", "http", "99999", "80" };

    for (inputs) |text| {
        // `if` on a call that can fail splits the two cases apart. Neither
        // branch can see the other's value, so there is no way to read a
        // result that was never produced.
        if (parsePort(text)) |port| {
            try out.print("{s: <6} -> port {d}\n", .{ text, port });
        } else |err| {
            // An error is an ordinary value. It can be compared, switched on,
            // and passed around like any other. There is no `else` prong here
            // because there is nothing left to catch: the compiler worked out
            // the complete set of errors parsePort can return, and adding an
            // `else` would be rejected as unreachable.
            const reason = switch (err) {
                error.InvalidCharacter => "not a number",
                error.Overflow => "too large for a u16",
                error.ReservedPort => "below 1024, needs privileges",
            };
            try out.print("{s: <6} -> {t}: {s}\n", .{ text, err, reason });
        }
    }

    // When a default is genuinely correct, say so in one word rather than
    // writing a branch that pretends to handle it.
    const port = parsePort("nonsense") catch 8080;
    try out.print("\nfalling back: {d}\n", .{port});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.errors-are-values`)*

## What just happened

**The return type is `!u16`, and the `!` is the whole idea.** It reads as "a
`u16` or an error". The caller receives one value in one of two states. The
language will not let you treat it as a number until you have dealt with the
other state.

**`if` split the two states apart.** `if (parsePort(text)) |port| ... else |err|`
gives the success branch a `port` and the failure branch an `err`, and neither
can see the other's value. There is no moment where a variable holds a result
that was never produced.

**`try` is the short way to pass it upward.** Inside `parsePort`, the line
`try std.fmt.parseInt(...)` means: if that failed, return its error to my
caller; otherwise give me the number. It is the everyday case, which is why it
is three letters. Nothing is unwound and nothing is searched for. It is a
return.

**The errors were values.** `switch (err)` on them works like a switch on
anything else. And there is **no `else` prong**. Slow down for that one. The
compiler worked out on its own that `parsePort` can return exactly three
errors, so adding an `else` was rejected as unreachable code. So if you later
make the function able to fail a fourth way, every switch like this one stops
compiling until it is updated. The set of failures is checked, not documented.

**`catch 8080` handled it in one word.** When a default really is correct,
`catch` says so without a branch that pretends to think about it. `catch` is
also where the honest ignore lives: `catch unreachable` asserts it cannot
happen, and `catch |e| std.debug.panic(...)` stops on purpose. All three are
visible at the call site. What you cannot do is say nothing.

## Check yourself

`parsePort("99999")` reported `Overflow`, but `parsePort` never mentions
overflow. Where did that error come from?

From `std.fmt.parseInt`, passed straight through by `try`. `parsePort`'s error
set is inferred, and it is the union of what it returns itself
(`error.ReservedPort`) and everything its `try` lines can propagate. That is
why the switch has three prongs for a function with one `return error` in it.
It is also why you can trust the set. It comes from the code, not from a
comment somebody remembered to update.

## If you have written C

C has the same constraint and no help with it, so the conventions are all
different from each other:

```c
int fd = open(path, O_RDONLY);       /* -1 means failure, errno says why */
long n = strtol(text, &end, 10);     /* 0 might be failure or might be zero */
void *p = malloc(size);              /* NULL means failure */
```

Three functions, three encodings, and in every case the failure is a value
that looks exactly like a success. Nothing stops you assigning `fd` and using
it. The `strtol` case is the worst: you have to check `errno` and the end
pointer to tell a real 0 from a failed parse, and almost nobody does.

Zig's `!u16` is the same idea with the encoding taken away from you and given
to the type system. There is one convention, it is in the signature, and
skipping it is a compile error rather than a habit.

The language-level detail, error sets as types, `errdefer`, and how error
returns interact with cleanup, is in [Errors](https://www.ziglang.in/learn/language-basics/errors/).

Next: [Talking to the Operating
System](https://www.ziglang.in/learn/systems-from-scratch/talking-to-the-os/), the last chapter in
this track.
