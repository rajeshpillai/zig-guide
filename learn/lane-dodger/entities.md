# Handles, Not Pointers

> A pool with a fixed capacity and generational handles, and the event stream that the particles and the sound use.

The game creates blocks and coins above the screen. It destroys them after they
leave the bottom. This occurs several times each second while the game runs.

## The storage is a fixed array

A run of any length allocates one time at startup, and never again. The
simulation has no allocator. That is one reason why the simulation imports
nothing.

Forty-eight slots are more than the field can hold. At the smallest spacing and
the highest speed, approximately three rows are on the screen. Each row has a
maximum of three entities, thus approximately nine entities exist at one time. A
test asserts that the peak stays less than the capacity and more than six. Thus
the test finds a change that stops the spawns without an error.

## An index is not sufficient

The usual way to refer to an entity is by its index. This causes a bug that is
very difficult to reproduce.

An event says "the player collected coin 12". One frame later, the pool frees
slot 12 and gives it to a new block. Any code that still has the number 12 now
reads a block and thinks that the block is a coin. The program does not crash.
The score is wrong approximately one time each hour, usually when nobody looks.

A pointer instead of an index does not help, because the pool uses the slot again
in both cases.

## Generational handles

A handle contains the slot index and the generation of that slot at the time
when the pool made the handle. When the pool frees a slot, it increments the
generation of the slot. Thus no handle to the old occupant resolves after that.

```zig
pub fn Pool(comptime T: type, comptime capacity_in: u16) type {
    return struct {
        const Self = @This();

        pub const capacity = capacity_in;

        pub const Handle = struct {
            index: u16,
            generation: u32,

            /// A handle that never resolves. The pool never gives out
            /// generation 0, because live slots start at generation 1.
            pub const none: Handle = .{ .index = 0, .generation = 0 };

            pub fn eql(a: Handle, b: Handle) bool {
                return a.index == b.index and a.generation == b.generation;
            }
        };

        const Slot = struct {
            value: T,
            /// Odd while the slot is live, even while it is free.
            generation: u32,
            /// The index of the next free slot. It is valid only while this
            /// slot is free.
            next_free: u16,
        };

        slots: [capacity]Slot,
        free_head: u16,
        live: u16,

        pub const empty = init: {
            var self: Self = .{
                .slots = undefined,
                .free_head = 0,
                .live = 0,
            };
            for (&self.slots, 0..) |*slot, i| {
                slot.* = .{
                    .value = undefined,
                    .generation = 0,
                    .next_free = @intCast(i + 1),
                };
            }
            break :init self;
        };

        /// Returns null when the pool is full. The caller decides what a full
        /// pool means. The spawner uses a full pool as back-pressure and does
        /// not do the spawn. This is always safe, because the course stays
        /// solvable.
        pub fn create(self: *Self, value: T) ?Handle {
            if (self.free_head >= capacity) return null;
            const index = self.free_head;
            const slot = &self.slots[index];
            self.free_head = slot.next_free;
            slot.generation += 1; // even -> odd: now live
            slot.value = value;
            self.live += 1;
            return .{ .index = index, .generation = slot.generation };
        }

        pub fn destroy(self: *Self, handle: Handle) void {
            const slot = self.resolve(handle) orelse return;
            slot.generation += 1; // odd -> even: now free
            slot.next_free = self.free_head;
            self.free_head = handle.index;
            self.live -= 1;
        }

        pub fn get(self: *Self, handle: Handle) ?*T {
            const slot = self.resolve(handle) orelse return null;
            return &slot.value;
        }

        pub fn contains(self: *const Self, handle: Handle) bool {
            if (handle.index >= capacity) return false;
            const slot = &self.slots[handle.index];
            return slot.generation == handle.generation and slot.generation % 2 == 1;
        }

        fn resolve(self: *Self, handle: Handle) ?*Slot {
            if (handle.index >= capacity) return null;
            const slot = &self.slots[handle.index];
            if (slot.generation != handle.generation) return null;
            if (slot.generation % 2 == 0) return null;
            return slot;
        }

        pub const Entry = struct { handle: Handle, value: *T };

        pub const Iterator = struct {
            pool: *Self,
            index: u16 = 0,

            pub fn next(self: *Iterator) ?Entry {
                while (self.index < capacity) {
                    const i = self.index;
                    self.index += 1;
                    const slot = &self.pool.slots[i];
                    if (slot.generation % 2 == 1) return .{
                        .handle = .{ .index = i, .generation = slot.generation },
                        .value = &slot.value,
                    };
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .pool = self };
        }

        pub fn clear(self: *Self) void {
            var it = self.iterator();
            while (it.next()) |entry| self.destroy(entry.handle);
        }
    };
}
```

*Quoted from the source: `Pool` from `examples/lane-dodger/src/sim/pool.zig`.*

The generation is odd while a slot is live, and even while the slot is free. One
counter tells you two things: which occupant has the slot, and if the slot is in
use. The pool never gives out generation zero. Thus a handle of all zeros is a
null handle.

`create` returns an optional, and does not assert. Here a full pool is not an
error. The spawner uses a full pool as back pressure and does not do that spawn.
This is safe because the player can always pass the course in both cases.

The name of the test is the name of the bug:

```zig
test "a stale handle does not resolve to the slot's new occupant" {
    var pool: TestPool = .empty;
    const old = pool.create(1).?;
    pool.destroy(old);
    const new = pool.create(2).?;
    // The pool uses the freed slot again. This is the purpose of the pool.
    try std.testing.expectEqual(old.index, new.index);
    // The stale handle must not see the new value.
    try std.testing.expect(pool.get(old) == null);
    try std.testing.expectEqual(@as(i32, 2), pool.get(new).?.*);
}
```

*Quoted from the source: `a stale handle does not resolve to the slot's new occupant` from `examples/lane-dodger/src/sim/pool.zig`.*

The first assertion proves that the pool really used the slot again. Without that
assertion, the test can pass when the pool gives out a new slot, and then the test
does not test the bug.

## One pool, two users

The pool is generic, thus other code can use it. The particle system uses the
same pool with a capacity of 256 and a different element type. The particles are
part of the renderer and not part of the simulation. Because the code has one
pool type for both users, the renderer got storage with a fixed capacity and no
allocator, at no extra cost.

## Events

The simulation reports what occurred. The simulation does not know what other
code does with that report.

```zig
/// What the simulation did in this tick. The parts of the program that react
/// to it read this: particles, screen shake, sound. The simulation does not
/// know that those parts exist. Thus a new sound cannot change the physics.
pub const Event = union(enum) {
    started,
    lane_changed: struct { from: u8, to: u8 },
    coin: struct { x: f32, y: f32, combo: u32, points: u32 },
    coin_missed,
    near_miss: struct { x: f32, y: f32 },
    crashed: struct { x: f32, y: f32 },
};
```

*Quoted from the source: `Event` from `examples/lane-dodger/src/sim/sim.zig`.*

The events collect in a fixed buffer, and the caller empties the buffer one time
in each frame. The buffer counts the events that it had to drop. A test asserts
that this count is zero across forty thousand ticks. If the event stream lost
events, the only symptom would be some particles that do not
appear.

One function contains the full reaction to a tick:

```zig
/// Change the reports from the simulation into what the player sees and
/// feels. No code here can change the result of the run.
fn react(
    world: *const sim.World,
    system: *particles.System,
    shake: *Shake,
    audio: ?*Audio,
) void {
    if (audio) |sound| {
        for (world.events.slice()) |event| sound.onEvent(event);
    }
    for (world.events.slice()) |event| switch (event) {
        .coin => |c| {
            system.burst(c.x, c.y, 10, palette.coin, 190);
            shake.kick(1.5 + @as(f32, @floatFromInt(c.combo)) * 0.4);
        },
        .near_miss => |n| {
            system.graze(n.x, n.y);
            shake.kick(3);
        },
        .crashed => |c| {
            system.debris(c.x, c.y);
            shake.kick(16);
        },
        .lane_changed => |l| {
            const direction: f32 = if (l.to > l.from) 1 else -1;
            system.dust(world.player.x, config.player_y, direction);
        },
        .coin_missed, .started => {},
    };
}
```

*Quoted from the source: `react` from `examples/lane-dodger/src/main.zig`.*

A coin becomes ten amber dots and a small shake of the screen. A crash becomes
debris. The simulation cannot see any of these effects.

## What this split gives you

The sound came after the game was already playable. The sound did not change a
rule of the game, because it reads the same events that the particles read.

```zig
    /// The one entry point that the game uses. It takes the same events as the
    /// particles and the screen shake.
    pub fn onEvent(self: *Audio, event: sim.Event) void {
        switch (event) {
            .coin => |c| {
                // Each combo step increases the pitch of the one coin sound.
                // Thus the game does not need eight coin sounds.
                // A semitone is 2^(1/12). This value is a little less than one
                // semitone for each step. Thus a full combo ends approximately
                // a fifth above its start.
                const step = std.math.pow(f32, 2.0, @as(f32, @floatFromInt(c.combo - 1)) / 14.0);
                self.cue(.coin, 0.85, step);
            },
            .near_miss => self.cue(.near_miss, 0.6, 1),
            .lane_changed => self.cue(.lane, 0.5, 1),
            .crashed => self.cue(.crash, 1, 1),
            .started => self.cue(.start, 0.8, 1),
            .coin_missed => {},
        }
    }
```

*Quoted from the source: `onEvent` from `examples/lane-dodger/src/platform/audio.zig`.*

It is easy to make an event system too large. Here, six variants in a tagged
union, a fixed buffer and one loop are sufficient. To test the design, ask this
question: to add a reaction, must you change the code that caused the event?
Here you do not. The same property lets
[the difficulty tests](https://www.ziglang.in/learn/lane-dodger/fair-by-design/) run the full game
with no renderer and no audio device.
