//! title: Importing a Host Function
//! norun
//! A module can call back into its host. An `extern` declaration with no body
//! becomes a wasm *import*, resolved at instantiation. Node's WASI does not
//! supply this `env.log`, so this page shows the code without running it; the
//! browser recipe wires the import up and presses go.

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
