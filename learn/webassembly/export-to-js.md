# Recipe: Calling Zig from JavaScript

> Build a reactor module with exported functions and call them by name from a host.

## The problem

You want to call a Zig function from JavaScript: a hot loop, a parser, a bit of
math the engine is slow at. The module has no `main`. JavaScript instantiates it
once and then calls its functions on demand. That is the reactor shape from the
[overview](../what-is-wasm/).

## The plan

1. Mark each function you want reachable with `export fn`.
2. Build for `wasm32-freestanding` with `-fno-entry`, naming the exports.
3. Instantiate in JavaScript and call `instance.exports.<name>`.

```zig
const std = @import("std");

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn fib(n: u32) u64 {
    var a: u64 = 0;
    var b: u64 = 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const next = a + b;
        a = b;
        b = next;
    }
    return a;
}

test add {
    try std.testing.expectEqual(@as(i32, 5), add(2, 3));
}

test fib {
    try std.testing.expectEqual(@as(u64, 55), fib(10));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`08-webassembly.export-to-js`)*

The Run button here executes the file's `test` blocks, because that is how this
guide verifies every snippet. In real use nothing calls these as Zig tests: the
functions exist to be called from outside, and the tests only prove they return
what the prose below claims.

## Exporting

`export fn` does two things: it forces the function to survive dead-code
elimination, and it puts it in the module's export table under its exact Zig
name. No name mangling, no wrapper. `add` in Zig is `add` in the export table.

The signatures use only `i32` and `u32`/`u64`, which is deliberate. Those map
straight to wasm's numeric types, so there is no boundary marshalling to think
about. `fib` returns a `u64`, which a JavaScript host receives as a `BigInt`.

## Building the reactor

```bash
zig build-exe export-to-js.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall -fno-entry \
  --export=add --export=fib
```

`-fno-entry` says there is no `_start`; this is a reactor, not a command.
`--export=` names each function to expose. `export fn` marks them in the source,
but on a freestanding link the symbols are still garbage-collected unless
something roots them, and `--export` is that root. (Passing `-rdynamic` instead
exports every public symbol, including compiler internals like the stack
pointer; naming them keeps the module to what you meant to ship.)

The result is tiny. These two functions and the memory come to about 135 bytes.

## Calling it

```js
const bytes = await fetch("export-to-js.wasm").then((r) => r.arrayBuffer());
const { instance } = await WebAssembly.instantiate(bytes, {});

console.log(instance.exports.add(2, 3));    // 5
console.log(instance.exports.fib(10));      // 55n  (the u64 return is a BigInt)
```

The second argument to `instantiate` is the imports object. It is empty here
because this module imports nothing: it only computes. When a module does need
something from the host, that object is where you supply it, which the
[browser recipe](../browser-instantiate/) covers.

## Variations

- **Passing anything larger than a number:** strings, slices, and structs do not
  fit in a wasm value. They cross through linear memory as an offset and a
  length. The [next recipe](../linear-memory/) is that handshake.
- **Naming exports differently:** when the Zig name and the name the host should
  see differ, use `@export(&foo, .{ .name = "bar" })` instead of `export fn`, and
  `bar` is what lands in the export table.
- **Many instances:** each `WebAssembly.instantiate` gives a fresh instance with
  its own memory, so calling the same module from two workers keeps their state
  apart.
