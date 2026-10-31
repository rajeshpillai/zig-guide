# Dependencies

> How to declare, fetch and connect a package with build.zig.zon.

The Zig build system includes a package manager. There is no separate tool, and there is no central registry. A dependency is a URL and a hash. Zig fetches the dependency into a global cache and verifies the hash when the files arrive.

Two files work together:

- `build.zig.zon` declares the packages that you depend on.
- `build.zig` gets each package and connects its modules to your artifacts.

## The path of a dependency

```
 build.zig.zon
      │
      │ declares
      ▼
  Dependency
      │
      │ downloaded, hash checked
      ▼
Global Zig cache
      │
      │ requested by
      ▼
   build.zig
      │
      ▼
executable / module
```

The two files answer two different questions:

- `build.zig.zon` answers **what do I depend on?**
- `build.zig` answers **where must the build use that dependency?**

The two files are separate. Thus, on each computer, a checkout and `zig build` give the same set of dependencies. The manifest records what you depend on. The build script connects each dependency to your code.

You cannot edit one file into a state where the other file disagrees and nothing tells you. If `build.zig` uses a name that the manifest does not declare, the result is an error, not an empty module.

## `build.zig.zon`

The manifest is a ZON literal. ZON is Zig Object Notation, and it has the same syntax as a Zig struct literal. A minimal manifest:

```zig
.{
    .name = .myproject,
    .version = "0.1.0",
    .fingerprint = 0x1234567890abcdef, // generated once by `zig init`
    .dependencies = .{
        .mecha = .{
            .url = "https://github.com/Hejsil/mecha/archive/<commit>.tar.gz",
            .hash = "mecha-0.9.0-...",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

You rarely write the `.url` and `.hash` pair manually. Run this command:

```bash
zig fetch --save https://github.com/Hejsil/mecha/archive/<commit>.tar.gz
```

`zig fetch` downloads the archive, calculates its hash, and writes the `.dependencies` entry for you.

The hash is content-addressed. The same bytes always give the same hash. If the hash is different on a later fetch, the result is a hard error. Thus a dependency cannot change after you add it.

## Connect the dependency in `build.zig`

A declared dependency does nothing until `build.zig` asks for it. Do these steps:

1. Get the dependency with `b.dependency`.
2. Get a named module from the dependency with `.module`.
3. Add that module to the module that imports it.

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The name matches the key in build.zig.zon's .dependencies.
    const mecha = b.dependency("mecha", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "myproject",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                // "mecha" is the name `@import` will use in your source;
                // `mecha.module("mecha")` is the module the dependency exposes.
                .{ .name = "mecha", .module = mecha.module("mecha") },
            },
        }),
    });
    b.installArtifact(exe);
}
```

`build.zig` gives `target` and `optimize` to `b.dependency`. Thus the dependency builds for the same target and mode as the code that uses it. Almost always, that is the correct result.

## Use the dependency in code

When the build imports a module under a name, `@import` gets the module in the same way as a module of the standard library:

```zig
const mecha = @import("mecha");
```

If you import a name that `build.zig` does not declare, the result is a compile error. The error gives the name of the module that is not declared. It is not a runtime failure that is difficult to understand.

The same mechanism connects your own internal modules. Thus you import a dependency and a local module in the same way.

## Where the files are

Zig puts fetched packages in a global cache. On Linux, the cache is under `~/.cache/zig`. All projects share the cache, and the hash is the key for each package.

Your repository contains only `build.zig.zon`, the small manifest. You do not commit a `vendor/` directory. You do not run a separate install step such as `npm install`.
