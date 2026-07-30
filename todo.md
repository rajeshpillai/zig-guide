# Todo

Planned work, in the order it is worth doing. Decisions already made are
recorded here so they do not have to be made again; the reasoning behind the
structural ones lives in [CLAUDE.md](CLAUDE.md).

## The sequence

1. **A Redis server** (Projects). Largest, already scoped, and the reason the
   Projects track exists with one occupant.
2. **Memory and the Machine** (Foundations). Cheapest, no new CI surface, and
   it fixes the steepest cliff in the guide as it stands.
3. **Terminal Programming** (Systems).

**Done, 2026-07-30: the Operating System section**, seven chapters at the front
of the Systems track. It moved ahead of Terminal Programming and was built
first, because raw mode is `termios` on file descriptor 0 and resize handling
is a `SIGWINCH` handler: both are a link now, and both would have been a detour
inside a chapter about drawing a screen. Four of the seven run in the browser,
against a stub that said "mostly `//! native`". The section is headed
"Operating System" in the sidebar rather than "Talking to the Operating
System", which is the voice of the lede and too long for a chapter list.

One and two are independent of each other and could swap on appetite. The
half-day `std.Io.Writer` vtable spike belongs to the Redis section but unblocks
the buffering chapter listed at the bottom, so it is worth doing first whatever
order the rest lands in.

## 1. A Redis server, in the Projects track

The largest remaining piece, and the reason the Projects track exists with one
occupant. Source material is `/home/rajesh/lab/rust/rust-redis/tutorial`, a
19-step Redis clone on Tokio. Do not port it directly: its parser takes a
`BufReader<TcpStream>`, and ours parses from a `std.Io.Reader` so the codec,
store and dispatch layers stay browser-runnable and only the accept loop is
`//! native`. That rule is in CLAUDE.md and the Networking section already
follows it.

**Do this first (half a day, de-risks the rest).** Implement a custom
`std.Io.Writer` vtable over a counting sink. It buys two things: the buffering
chapter cut from Networking (see below), and an in-memory transport that lets
the Redis chapters run a full client-and-server round trip in the browser
rather than the one-directional buffer `many-clients` uses today.

Fourteen chapters, as its own section under the Projects track (a project is a
section, not a group):

1. What we are building, and the three layers
2. RESP by hand, the five types, encode and decode (browser)
3. A parser that survives a partial read (browser)
4. The store: a StringHashMap with owned keys, and who frees them (browser)
5. Dispatch as a comptime command table (browser)
6. Expiry with an injected clock, lazy against active (browser)
7. Lists and hashes as a tagged union (browser)
8. Sorted sets, and what Zig gives you instead of `Ord` (browser)
9. Serving it over TCP, `io.async` per connection, `Group` for shutdown (native)
10. Pub/sub fan-out (browser, over the in-memory transport)
11. An append-only file and replay on start (native)
12. MULTI/EXEC/WATCH as a version counter (browser)
13. A client and a REPL (native)
14. Making it fast, measured

Cut from the Rust original, and say so on the page rather than quietly:
replication and cluster are each a section's worth; jemalloc has no Zig
analogue worth a chapter; steps 16 to 18 collapse into chapter 14.

The accumulating library goes in `snippets/12-zedis/_resp.zig`, `_store.zig`
and so on. `_`-prefixed files are helper modules rather than snippets
([build.zig](build.zig) skips them), which is how the graphics chapters share
`_canvas.zig` across ten pages.

**Benchmarks: do not put them in CI.** The Rust repo compares against Redis 7
in Docker. A Docker-plus-network perf gate would go red on an unchanged tree,
which is the one failure this project cannot tolerate. Ship the harness for
the reader to run locally and state numbers as measured on named hardware.

## 2. Memory and the Machine

The cheapest section left and the one that fixes the steepest cliff, since
`standard-library/allocators.mdx` currently assumes the reader knows what a
heap is. Seven chapters, all browser-runnable, no new CI surface. Goes at the
end of the Foundations track.

Where a value lives, using `@intFromPtr` ordering rather than addresses ·
size, alignment and padding (absorbs `how-to/memory-layout.mdx`) · byte order ·
bits (`@popCount`, `@clz`, `@ctz`, shift-amount types) · who owns this memory,
including returning a slice into a dead frame as `//! norun` · what an
allocator actually is, by writing a bump allocator in about forty lines ·
arenas, and why they change your design.

Chapter six is the payoff: after writing the vtable yourself, the allocator
parameter stops being Zig trivia.

## 3. Terminal Programming

Source material is `/home/rajesh/lab/c/classic-snake/tutorial`, a 15-lesson
ncurses course ending in a capstone rebuild of `snake.c`. Same move as the
Redis section: make the screen differ pure Zig writing escape bytes into a
`Writer`, which is lesson one's central idea ("curses is a screen differ") and
happens to produce deterministic bytes, so it gets an `.expected` and runs in
the browser.

Escape sequences, cursor positioning, SGR colour, box drawing and the
arrow-key escape parser are all pure-function chapters. Only raw mode
(termios), the frame loop and SIGWINCH resize need `//! native`, and raw mode
needs `//! native` plus `//! norun` for the same reason the X11 chapter does.

Capstone: port `minisnake.c`. Seed the RNG and the simulation runs headless
against an `.expected` transcript in wasm, with the interactive build as
native and norun. Link back to the C repo for the ncurses version.

## Smaller things

- **The buffering chapter cut from Networking.** "One message, one write", and
  why `BufWriter` changes the throughput number. It was cut because teaching it
  honestly needs a counting sink, and a chapter that fakes its own point is
  worse than no chapter. The vtable spike above unblocks it.
- **`npm run check` has never been runnable.** `@astrojs/check` is not a
  dependency and CI does not run it, so the script prompts to install and then
  fails. Either add the dependency and put it in the workflow, or drop the
  script.
- **The ORM's snippet directory is still `07-building-libraries`** while its
  section is `/orm/`. Harmless, since snippet slugs are an internal namespace,
  but it will read oddly next to `12-zedis`. Rename when touching those
  snippets for another reason.
- **Ads below the footer only.** Blocked on the AdSense dashboard, not on this
  repo. The full note is in CLAUDE.md and should stay there.
