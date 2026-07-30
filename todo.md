# Todo

Planned work, in the order it is worth doing. Decisions already made are
recorded here so they do not have to be made again; the reasoning behind the
structural ones lives in [CLAUDE.md](CLAUDE.md).

## The sequence

1. **A Redis server** (Projects). Largest, already scoped, and the reason the
   Projects track exists with one occupant.
2. **Memory and the Machine** (Foundations). Cheapest, no new CI surface, and
   it fixes the steepest cliff in the guide as it stands.
3. **Talking to the Operating System** (Systems). Half of it runs in the
   browser (see below), and it owns the two things Terminal Programming needs.
4. **Terminal Programming** (Systems).

Three and four swapped from the order these were first written down, and the
reason is a dependency rather than a preference: raw mode is `termios` on file
descriptor 0, and resize handling is a `SIGWINCH` handler. Both are one
sentence if the OS section is already there to link to, and both are a detour
inside a chapter about drawing a screen if it is not.

One and two are independent of everything else and could swap on appetite. The
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

## 3. Talking to the Operating System

Its own section at the **front of the Systems track**, before Networking. A
socket is a file descriptor, and `networking/what-is-a-socket.mdx` currently has
to explain what a handle is on its way to explaining what an address is. Section
directory `os`, so `/learn/os/`; snippets in `snippets/14-os/`.

**Half of it runs in the browser, and the note that said otherwise was wrong.**
The old entry here read "mostly `//! native`, so it costs more CI surface".
Measured against 0.17.0-dev.1454, four of the seven chapters are
browser-runnable. Under both runners `std.Io.File.stdout().handle` is 1,
`stderr` is 2, `stdin` is 0, and a `File` built by hand out of the raw number
writes to standard output exactly as the one from `stdout()` does. WASI kept the
numbering, so the chapter claiming a descriptor is only a number can prove it
inside a sandbox with no operating system under it, which is a better
demonstration than a native run would be.

Seven chapters:

1. **A file descriptor is a number** (browser). Print the three handles, then
   build `.{ .handle = 1, .flags = .{ .nonblocking = false } }` by hand and
   write through it. Takes an `.expected`.
2. **The three standard streams** (browser). Which stream a diagnostic belongs
   on, why a green run prints nothing at all (the discipline
   [tools/run-wasi.mjs](tools/run-wasi.mjs) documents), and `isTty`, which is
   false in the sandbox and false in a pipe, which is the whole point of asking.
   Links to `getting-started/buffered-stdout.mdx` instead of teaching `flush`
   twice.
3. **The environment** (browser). Build a `std.process.Environ.Map`, put and get
   and count, and the validation rules on keys. The real block arrives on
   `init.minimal`; the page says so and the snippet stays deterministic, which
   is the same split `standard-library/command-line.mdx` already makes for argv.
4. **Spawning a process** (native). `std.process.run`, `Term`, and what a child
   reports when it fails. Spawn *this* binary again through
   `std.process.executablePath` with a flag argument rather than shelling out to
   `/bin/echo`, so the snippet depends on no system binary. It is also the only
   chapter where a nonzero exit code can be shown at all: `build.zig` puts
   `expectExitCode(0)` on every snippet, so the child fails and the parent
   prints the code and exits clean.
5. **Pipes are the child's streams** (native). `.stdout = .pipe`, read
   `child.stdout.?` as an `Io.File`, then `wait`. Carries an API delta worth the
   page on its own: there is no `std.posix.pipe` any more, `pipe2` lives inside
   `Io.Threaded` and `Io.Uring`, and the portable way to hold one end of a pipe
   is to spawn something on the other.
6. **Signals, and why you cannot allocate in a handler** (native). Two drifts
   here, and both are compile errors rather than surprises: `posix.sigaction`
   returns `void` now instead of an error union, and a handler takes
   `std.posix.SIG`, not `c_int`, so every handler a reader finds online fails to
   build. Set an atomic flag, `raise(.USR1)`, observe it, then say what a
   handler may touch and what to do with the rest.
7. **Exiting** (browser). `std.process.exit` does not run your `defer`s, which
   the snippet shows by printing on either side of one; `cleanExit` and when
   skipping teardown is the correct call; `abort` against `exit`. Status stays 0
   so the gate stays green, and the interesting codes are prose.

Chapters 1, 4, 5 and 6 exist as compiled and run spikes against
0.17.0-dev.1454+5faa79730, so the API shapes above are checked rather than
remembered.

Cut, and say so on the page rather than quietly: `mmap` and page protection
(they belong with Memory and the Machine, which owns allocators), users and
permissions, daemonising, and `std.process.replace` beyond a paragraph in
chapter 4.

CI cost is three more native snippets on top of the eighteen already there, all
deterministic, all sub-second, and no new tooling. Wiring a new section is a
`TRACKS` entry (Systems, first), a `SECTIONS` entry in
[web/src/seo.ts](web/src/seo.ts) with a lede and takeaways, `order` values
inside the section only, and back-links from `networking/what-is-a-socket.mdx`
and `standard-library/filesystem.mdx`.

## 4. Terminal Programming

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
