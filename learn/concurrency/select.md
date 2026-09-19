# Select

> Waiting for whichever task finishes first, and cancelling the rest.

`Future.await` waits for one task. `Group.await` waits for all of them.
`std.Io.Select` is the third shape: wait for whichever finishes first, then
decide what to do about the others. A request against a timeout is the case
you will write most often.

```zig
const std = @import("std");

/// Whichever arm wins, the result arrives as this union, tagged with the arm
/// that produced it.
const Outcome = union(enum) {
    reply: u32,
    timeout: void,
};

fn request(io: std.Io, delay: std.Io.Duration) u32 {
    io.sleep(delay, .awake) catch return 0;
    return 42;
}

fn deadline(io: std.Io, after: std.Io.Duration) void {
    io.sleep(after, .awake) catch {};
}

/// Runs both arms and reports the one that finished first, cancelling the
/// other. The margin between the two durations is an hour, so the winner is
/// decided by the code and not by how loaded the machine is.
fn race(
    io: std.Io,
    out: *std.Io.Writer,
    reply_after: std.Io.Duration,
    timeout_after: std.Io.Duration,
) !void {
    var slots: [2]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, &slots);

    try select.concurrent(.reply, request, .{ io, reply_after });
    try select.concurrent(.timeout, deadline, .{ io, timeout_after });

    switch (try select.await()) {
        .reply => |value| try out.print("reply: {d}\n", .{value}),
        .timeout => try out.print("timed out\n", .{}),
    }

    // The losing arm is still running. A select owns its tasks, so cancelling
    // the select stops it, and nothing is left behind when this returns.
    select.cancelDiscard();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    try race(io, out, .fromMilliseconds(1), .fromSeconds(3600));
    try race(io, out, .fromSeconds(3600), .fromMilliseconds(1));

    try out.flush();
}
```

*Built and run natively by CI. A race needs the arms running at the same time, which is io.concurrent, and single-threaded wasm has none to give. (`03-standard-library.select`)*

## The union is the result

```zig
const Outcome = union(enum) {
    reply: u32,
    timeout: void,
};

var slots: [2]Outcome = undefined;
var select: std.Io.Select(Outcome) = .init(io, &slots);
```

Each arm is a field. `Select(U)` is a `Group` and a `Queue(U)` together, so
the buffer you pass is the queue's. It must have room for every task you
spawn. Cancelling with less space than that deadlocks, because the tasks being
cancelled still need somewhere to put their results.

```zig
try select.concurrent(.reply, request, .{ io, reply_after });
try select.concurrent(.timeout, deadline, .{ io, timeout_after });

switch (try select.await()) {
    .reply => |value| ...,
    .timeout => ...,
}
```

The field name is comptime, and the function's return type has to match that
field. So an arm returning the wrong type is a compile error, not a mis-tagged
union at run time. `await` returns as soon as any arm completes; call it again
for the next one, or stop.

## The losers are still running

```zig
select.cancelDiscard();
```

A select owns its tasks the way a `Group` does, and the arm that lost is still
in flight when `await` returns. `cancelDiscard` requests cancellation on all
of them and waits until they are done, throwing the results away. Use `cancel`
instead when an arm can return something that has to be freed: it hands back
one outstanding result per call, and you loop until it returns `null`.

Skipping this does not leak in the ordinary sense. But the select cannot be
destroyed while a task still points into its buffer, so there is nothing to be
gained by leaving it out.

## Use `concurrent` for the arms

`select.async` exists and matches `Group.async`, but a race between arms that
are allowed to run inline is not a race. On an `Io` that runs tasks inline,
the first arm spawned runs to completion first and wins every time. For a
timeout arm, that means sleeping out the entire timeout before the request is
even started. The arms here use `concurrent` for that reason, and the snippet
is native because `concurrent` is what wasm cannot provide.

The durations in the snippet differ by an hour in each direction. That is
deliberate: the winner is decided by the code rather than by how loaded the
machine is, so the expected output holds on CI. A race whose margin is
milliseconds is a flaky test, not a demonstration.
