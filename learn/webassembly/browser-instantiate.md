# Recipe: Loading wasm in the Browser

> Fetch, instantiate, wire up imports and exports, and let a module call back into JavaScript.

## The problem

You have a reactor module and a web page. You want the page to load the `.wasm`,
call its functions, and let the module call back into JavaScript when it needs
to. This is what this very site does on every Run button, and the moving parts
are worth seeing whole.

## The plan

1. `fetch` the `.wasm` and hand the stream to `instantiateStreaming`.
2. Pass an **imports** object supplying every function the module imports.
3. Call the module's **exports**, and let it call your imports back.

```zig
const std = @import("std");

// Provided by the host (JavaScript) when the module is instantiated. The module
// name "env" and the symbol "log" are what the host's imports object must match.
extern "env" fn log(ptr: [*]const u8, len: usize) void;

fn hostPrint(msg: []const u8) void {
    log(msg.ptr, msg.len);
}

// The host calls this; it in turn calls back out through the import.
export fn greet() void {
    hostPrint("hello from wasm");
}
```

*Imports a host `log` function that Node's WASI does not provide, so it is compiled but not run here. The JavaScript below is what runs it in a browser. (`08-webassembly.browser-import`)*

This module both imports and exports. It exports `greet`, which the page calls.
`greet` calls back out through `log`, which the module *imports*: an `extern`
declaration with no body. The host must supply `log`, or instantiation fails.
That is why the guide cannot run this snippet through its WASI shim, and why the
page above shows it without a Run button.

## Fetch and instantiate

`WebAssembly.instantiateStreaming` compiles the module as it downloads, which is
faster than buffering the whole file first:

```js
const decoder = new TextDecoder();
let memory;   // filled in once the instance exists

const imports = {
  env: {
    // The module's `extern "env" fn log(ptr, len)` resolves to this.
    log(ptr, len) {
      const bytes = new Uint8Array(memory.buffer, ptr, len);
      console.log(decoder.decode(bytes));
    },
  },
};

const { instance } = await WebAssembly.instantiateStreaming(
  fetch("browser-import.wasm"),
  imports,
);
memory = instance.exports.memory;

instance.exports.greet();   // logs "hello from wasm"
```

## Imports resolve by name

The module declared `extern "env" fn log(...)`. Those two names are the contract:
the module name `env` and the field `log`. The imports object must have exactly
`imports.env.log`, or instantiation throws a `LinkError` naming what was missing.
Rename either side and it stops resolving. This is a hard interface, checked at
instantiation, not a loose convention.

Notice `log` reads the string out of `memory` using the offset and length the
module passed. The module put "hello from wasm" in its linear memory and passed
where it lives; the host decodes it there. It is the [boundary
protocol](../linear-memory/) again, this time with the module as the caller.

## Order of operations

There is a small chicken-and-egg here. The import `log` needs `memory` to read
the string, but `memory` only exists after the instance is created, and creating
the instance needs the imports object. It works because `log` is not *called*
during instantiation, only *defined*. By the time `greet` runs and calls `log`,
`memory` has been assigned. Capturing it in a closure that reads it lazily, as
above, is the usual way to tie the knot.

## A note on `instantiateStreaming`

It needs the server to send the file with `Content-Type: application/wasm`. If
your host serves the wrong type the call rejects, and the fix is either the
server config or the buffered fallback:

```js
const bytes = await fetch(url).then((r) => r.arrayBuffer());
const { instance } = await WebAssembly.instantiate(bytes, imports);
```

That is the same path the [JavaScript recipe](../export-to-js/) used, and it is
what this site's runner does, since it already has the bytes in hand.

## Variations

- **Many imports:** group them by module name. `imports.env` for your own hooks,
  and a WASI shim would add its own namespace alongside.
- **Passing rich data back:** `log` here takes an offset and a length. Anything
  structured (a JSON string, a packed struct) crosses the same way, decoded on
  the host from `memory`.
- **This site, exactly:** the playground fetches the verified `.wasm`, builds a
  WASI import object instead of a single `log`, and calls `_start`. Different
  imports, identical mechanism.
