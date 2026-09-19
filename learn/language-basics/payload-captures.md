# Payload Captures

> The |value| syntax that unwraps everything.

```zig
const std = @import("std");
const expect = std.testing.expect;

const Shape = union(enum) {
    circle: f32,
    rect: struct { w: f32, h: f32 },
};

test "capture an optional" {
    const maybe: ?u32 = 5;
    if (maybe) |value| {
        try expect(value == 5);
    } else {
        unreachable;
    }
}

test "capture an error union" {
    const result: anyerror!u32 = 7;
    if (result) |value| {
        try expect(value == 7);
    } else |_| {
        unreachable;
    }
}

test "capture a union payload in switch" {
    const s = Shape{ .rect = .{ .w = 2, .h = 3 } };
    const area = switch (s) {
        .circle => |r| 3.14 * r * r,
        .rect => |r| r.w * r.h,
    };
    try expect(area == 6);
}

test "capture by pointer to mutate" {
    var maybe: ?u32 = 5;
    if (maybe) |*value| {
        value.* += 1;
    }
    try expect(maybe.? == 6);
}

test "while captures until null" {
    // A `while` over an optional-returning expression loops until null.
    var countdown: u32 = 3;
    var seen: u32 = 0;
    while (nextValue(&countdown)) |value| {
        seen += value;
    }
    try expect(seen == 6); // 3 + 2 + 1
}

fn nextValue(state: *u32) ?u32 {
    if (state.* == 0) return null;
    defer state.* -= 1;
    return state.*;
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.payload-captures`)*

The `|value|` syntax is one idea reused everywhere something is wrapped:

| Construct | Captures |
| --- | --- |
| `if (optional) \|v\|` | the non-null payload |
| `if (error_union) \|v\| else \|e\|` | the value, or the error |
| `while (iter()) \|v\|` | each value until null |
| `switch (tagged_union) { .a => \|v\| ... }` | the active variant's payload |
| `for (slice) \|item\|` | each element |
| `catch \|err\|` | the error |

Learning it once means every wrapper type in the language is already familiar.

## Why it is one construct and not two

The capture is what makes these safe. There is no `isSome()` followed by a
separate `unwrap()`, because those can be separated by an edit and then the
unwrap runs without the test. Here the payload only has a name inside the
branch where it is known to exist. Outside that branch there is nothing to
misuse.

That also explains the missing operations. There is no way to ask an optional
"are you null" and get a bare bool you can store in a variable. There is no
way to name the payload of a union variant that is not currently active. The
language gives you the payload exactly where it is valid and nowhere else.

## Capture by pointer to mutate

`|*value|` captures a pointer instead of a copy, letting you modify the thing
in place:

```zig
if (maybe) |*value| value.* += 1;

switch (shape) {
    .circle => |*r| r.* *= 2,
    ...
}
```

Without the `*` you get a copy, and mutating it silently does nothing to the
original. This is one of the few places Zig will let you write something that
looks effective but is not.

The rule for spotting it: ask what you are holding. `|v|` is a value you own
and can freely change without affecting anything. `|*v|` is a pointer to the
thing itself, so writes land. When the payload is large, the pointer form also
avoids the copy, but correctness is the reason to reach for it, not speed.

Capturing by pointer requires something to point at. It works when the thing
being unwrapped is a mutable location (a `var`, a field, an element). A
temporary that only exists for the length of the expression has nothing stable
to take the address of. The compiler says so, rather than handing you a
pointer to memory that is already gone.

## `_` is a capture too

When a construct requires a capture and you do not want the value, `_`
discards it without the unused-variable error:

```zig
while (it.next()) |_| : (n += 1) {}

if (result) |v| use(v) else |_| return default;
```

That last one is the idiomatic "I do not care which error". It reads better
than catching and ignoring, because the discard sits where the error arrives.

## Two captures at once

A `for` can capture from several sequences, and the captures line up with the
operands in order:

```zig
for (names, scores, 0..) |name, score, i| { ... }
```

Each can independently be a pointer capture, so `for (&items, extras) |*item,
x|` mutates the first while reading the second. The count has to match the
number of operands, and that is checked. So adding a sequence and forgetting
its capture is a compile error, not a silent shift of every name by one.
