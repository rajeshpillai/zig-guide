# Defer

> Cleanup that runs on every path out of a scope.

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

`defer` schedules an expression to run when the enclosing **scope** exits: not
the function, the scope. Every path counts: falling off the end, an early
`return`, or an error propagating through `try`.

## Reverse order is the point

Deferred statements run last-registered-first. That is what makes them
compose: if you acquire A then B, cleanup happens B then A, which is almost
always the correct unwinding order. Writing the release directly under the
acquire keeps the pair visible in one glance:

```zig
const buf = try allocator.alloc(u8, n);
defer allocator.free(buf);
```

That adjacency is what makes `defer` readable rather than clever. Checking an
allocation for a leak is a glance at the next line, not a search for the
matching `free` somewhere below.

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

This is the difference from Go, where `defer` is function-scoped and a `defer`
inside a loop quietly piles up until the function ends. In Zig, opening a file
inside a loop and deferring its close closes it on each pass, so the loop
cannot run out of descriptors.

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

`defer` is for releasing things, not for adjusting results.

You also cannot `return` from inside one:

```
error: cannot return from defer expression
```

A deferred statement runs on the way out of a scope. Letting it pick a
different way out would make the exit path of every function with cleanup
unreadable.

## `errdefer` for the failure path only

`errdefer` runs **only** when the function returns an error. This is how you
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
step, which is exactly the unwinding a half-built object needs:

```zig
const a = try makeA();
errdefer freeA(a);
const b = try makeB();     // if this fails, only a is freed
errdefer freeB(b);
const c = try makeC();     // if this fails, b then a are freed
return .{ .a = a, .b = b, .c = c };
```

Read from the bottom up, that is the failure ladder, and each rung was written
next to the thing it undoes.

## If you have written C++ or Rust

`defer` does the work of a destructor, with the pairing written at the use
site instead of attached to a type. The trade is deliberate. Nothing runs
invisibly at a closing brace: everything that happens on the way out is a
statement in the function you are reading. The cost is that a `defer` can be
forgotten, which is why the [allocator
chapter](https://www.ziglang.in/learn/standard-library/allocators/) relies on a leak-checking
allocator to catch what review misses.
