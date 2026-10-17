# Defer

> Cleanup that runs on every path out of a scope.

In Zig, `defer` is how cleanup is written: the release goes on the line under
the acquire, and deferred statements run in reverse order when the scope exits.
`errdefer` does the same only when the function returns an error.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "defer runs at scope exit" {
    var x: i16 = 5;
    {
        defer x += 2;
        try expect(x == 5); // not yet
    }
    try expect(x == 7); // now
}

test "defers run in reverse order" {
    // Last registered runs first, so cleanup unwinds in the order things
    // were acquired.
    var order: [3]u8 = undefined;
    var index: usize = 0;
    {
        defer {
            order[index] = 1;
            index += 1;
        }
        defer {
            order[index] = 2;
            index += 1;
        }
        defer {
            order[index] = 3;
            index += 1;
        }
    }
    try expect(order[0] == 3);
    try expect(order[2] == 1);
}

fn mightFail(fail: bool) !u8 {
    var cleaned = false;
    // `errdefer` runs only when the function returns an error.
    errdefer cleaned = true;
    if (fail) return error.Nope;
    return @intFromBool(cleaned);
}

test "errdefer only fires on the error path" {
    try expect(try mightFail(false) == 0);
    try std.testing.expectError(error.Nope, mightFail(true));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.defer`)*

The scope is the enclosing block, not the whole function. Every path out of
it counts: falling off the end, an early `return`, or an error propagating
through `try`.

## Reverse order is the point

Deferred statements run in reverse order: the last one registered runs first.
If you acquire A and then B, cleanup releases B and then A. This is almost
always the correct order. Writing the release directly under the acquire keeps
the pair visible in one glance:

```zig
const buf = try allocator.alloc(u8, n);
defer allocator.free(buf);
```

Because the release sits on the next line, checking an allocation for a leak
means reading one line. You do not have to search for the matching `free`
somewhere below.

## The scope really is the scope

A `defer` inside a loop body runs at the end of **every iteration**, not when
the function returns:

```zig
var n: u32 = 0;
for (0..3) |_| {
    defer n += 1;
}
// n == 3
```

Go differs here. Its `defer` is function-scoped, so one inside a loop quietly
piles up until the function ends. In Zig, opening a file inside a loop and
deferring its close closes it on each pass, so the loop cannot run out of
descriptors.

It also means a bare block is a way to bound a cleanup tightly:

```zig
{
    const lock = mutex.acquire();
    defer lock.release();
    // held only inside these braces
}
```

## Ordering against the return value

The return value is computed first, then the deferred statements run, then the
function returns. So this returns 0, not 1:

```zig
fn f() u8 {
    var x: u8 = 0;
    defer x += 1;
    return x;      // the 0 is already captured
}
```

Use `defer` to release resources. Do not use it to change a result.

You also cannot `return` from inside one:

```
error: cannot return from defer expression
```

A deferred statement runs while the scope is already exiting. If it could
return, it could choose a different exit, and the exit path of every function
with cleanup would be hard to follow.

## `errdefer` for the failure path only

`errdefer` runs **only** when the function returns an error. That lets you
write a constructor that cleans up partial work without also undoing itself on
success:

```zig
const thing = try create();
errdefer destroy(thing);   // only if a later step fails
try initialise(thing);
return thing;
```

With plain `defer` that would destroy the object you just successfully
returned.

Choosing between them is a question about ownership. If this scope owns the
resource for its whole life, use `defer`. If the resource is on its way to the
caller and only stays yours when something goes wrong, use `errdefer`. A
multi-step initialiser gets one `errdefer` per step, each undoing only that
step. A half-built object is then undone one step at a time, in reverse:

```zig
const a = try makeA();
errdefer freeA(a);
const b = try makeB();     // if this fails, only a is freed
errdefer freeB(b);
const c = try makeC();     // if this fails, b then a are freed
return .{ .a = a, .b = b, .c = c };
```

Read the `errdefer` lines from the bottom up to see what runs on failure.
Each one is written next to the step it undoes.

## If you have written C++ or Rust

`defer` does the work of a destructor, with the pairing written at the use
site instead of attached to a type. Zig chose this on purpose. No code runs
unseen at a closing brace. Everything that happens on the way out is a
statement in the function you are reading. The cost is that a `defer` can be
forgotten. For that reason the [allocator
chapter](https://www.ziglang.in/learn/standard-library/allocators/) relies on a leak-checking
allocator to catch what review misses.
