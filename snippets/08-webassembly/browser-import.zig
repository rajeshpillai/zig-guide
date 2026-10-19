//! title: Import a Host Function
//! norun
//! A module can call back into its host. An `extern` declaration with no body
//! becomes a wasm *import*. The engine resolves it at instantiation. The WASI
//! of Node does not supply this `env.log`. Thus this page shows the code and
//! does not run it. The browser recipe connects the import and runs the code.

const std = @import("std");

// The host (JavaScript) supplies this function at instantiation. The imports
// object of the host must match the module name "env" and the symbol "log".
extern "env" fn log(ptr: [*]const u8, len: usize) void;

fn hostPrint(msg: []const u8) void {
    log(msg.ptr, msg.len);
}

// The host calls this function. It then calls back to the host through
// the import.
export fn greet() void {
    hostPrint("hello from wasm");
}
