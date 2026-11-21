# Parse Strings at Compile Time

> Parse a route pattern during compilation, and make a struct type for its parameters.

A string that the compiler knows is data that comptime code can read. A comptime function can split it, check it and change it into a type.

This chapter parses a web route such as `/users/:user/posts/:post`. A segment that starts with `:` is a parameter. The result of the parse is two things:

- A `Params` struct with one field for each parameter.
- A `match` function that reads a path and fills a `Params`.

All of the parse happens during compilation. At runtime, only the match remains.

```zig
const std = @import("std");

fn segmentCount(comptime pattern: []const u8) usize {
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

// "/users/:user" becomes .{ "users", ":user" }.
fn segments(comptime pattern: []const u8) [segmentCount(pattern)][]const u8 {
    var result: [segmentCount(pattern)][]const u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    for (&result) |*segment| segment.* = it.next().?;
    return result;
}

fn paramCount(comptime pattern: []const u8) usize {
    var n: usize = 0;
    for (segments(pattern)) |segment| {
        if (segment[0] == ':') n += 1;
    }
    return n;
}

// The names after each ':', in order. A name that occurs two times
// stops the build.
fn paramNames(comptime pattern: []const u8) [paramCount(pattern)][]const u8 {
    var names: [paramCount(pattern)][]const u8 = undefined;
    var i: usize = 0;
    for (segments(pattern)) |segment| {
        if (segment[0] != ':') continue;
        const name = segment[1..];
        for (names[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, name)) {
                @compileError("route " ++ pattern ++ ": parameter '" ++ name ++ "' occurs two times");
            }
        }
        names[i] = name;
        i += 1;
    }
    return names;
}

fn Route(comptime pattern: []const u8) type {
    const parts = segments(pattern);
    const names = paramNames(pattern);
    return struct {
        // One `[]const u8` field for each parameter in the pattern.
        pub const Params = @Struct(.auto, null, &names, &@splat([]const u8), &@splat(.{}));

        pub fn match(path: []const u8) ?Params {
            var it = std.mem.tokenizeScalar(u8, path, '/');
            var params: Params = undefined;
            // One copy of the body for each segment of the pattern.
            inline for (parts) |part| {
                const got = it.next() orelse return null;
                if (part[0] == ':') {
                    @field(params, part[1..]) = got;
                } else if (!std.mem.eql(u8, got, part)) {
                    return null;
                }
            }
            if (it.next() != null) return null;
            return params;
        }
    };
}

const UserPost = Route("/users/:user/posts/:post");
const Health = Route("/health");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const fields = @typeInfo(UserPost.Params).@"struct".field_names;
    try out.print("UserPost.Params has {d} fields:", .{fields.len});
    inline for (fields) |name| try out.print(" {s}", .{name});
    try out.print("\n", .{});

    const paths = [_][]const u8{
        "/users/42/posts/7",
        "/users/tejas/posts/hello-world",
        "/users/42/posts",
        "/users/42/comments/7",
        "/users/42/posts/7/edit",
    };
    for (paths) |path| {
        if (UserPost.match(path)) |p| {
            // `p.user` and `p.post` are real fields. A wrong field name is a
            // compile error. A map gives `null` at runtime for a wrong key.
            try out.print("{s}: user={s} post={s}\n", .{ path, p.user, p.post });
        } else {
            try out.print("{s}: no match\n", .{path});
        }
    }

    try out.print("/health: {s}\n", .{if (Health.match("/health") != null) "match" else "no match"});
    try out.print("Health.Params has {d} fields\n", .{@typeInfo(Health.Params).@"struct".field_names.len});
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`25-comptime.parse-strings`)*

## Split the pattern

```zig
fn segments(comptime pattern: []const u8) [segmentCount(pattern)][]const u8 {
    var result: [segmentCount(pattern)][]const u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    for (&result) |*segment| segment.* = it.next().?;
    return result;
}
```

`std.mem.tokenizeScalar` is the same function that a program uses at runtime. Comptime code can call it because it does not allocate memory and does not do I/O.

Comptime code has no allocator, thus the function cannot return a list that grows. It returns an array, and the array needs a length in its type. `segmentCount` calculates that length: it runs the same tokenizer and counts the segments. The pattern is comptime-known, thus the count is comptime-known too.

`paramCount` and `paramNames` use the same method. They count the segments that start with `:`, then they copy the names.

## Make the type

```zig
pub const Params = @Struct(.auto, null, &names, &@splat([]const u8), &@splat(.{}));
```

Each parameter becomes a field of type `[]const u8`. `@splat` makes an array with the same value in each item, with the length that `@Struct` needs. [Make a Type](https://www.ziglang.in/learn/metaprogramming/make-a-type/) explains the five arguments of `@Struct`.

The output shows the fields of the new type:

```
UserPost.Params has 2 fields: user post
```

A route with no parameters gets a struct with no fields:

```
Health.Params has 0 fields
```

## Match a path

```zig
pub fn match(path: []const u8) ?Params {
    var it = std.mem.tokenizeScalar(u8, path, '/');
    var params: Params = undefined;
    inline for (parts) |part| {
        const got = it.next() orelse return null;
        if (part[0] == ':') {
            @field(params, part[1..]) = got;
        } else if (!std.mem.eql(u8, got, part)) {
            return null;
        }
    }
    if (it.next() != null) return null;
    return params;
}
```

`path` is a runtime value. `parts` is comptime-known. The `inline for` makes one copy of the body for each segment of the pattern. In each copy, the test `part[0] == ':'` is comptime-known. Thus each copy contains only one of the two branches: a store into a field, or a compare with fixed text.

For `/users/:user/posts/:post`, the result is the same as this function written by hand:

1. Compare the first segment with `users`.
2. Store the second segment in `params.user`.
3. Compare the third segment with `posts`.
4. Store the fourth segment in `params.post`.
5. Return `null` if there is a fifth segment.

The output shows a path that matches, and three paths that do not:

```
/users/42/posts/7: user=42 post=7
/users/tejas/posts/hello-world: user=tejas post=hello-world
/users/42/posts: no match
/users/42/comments/7: no match
/users/42/posts/7/edit: no match
```

## Typed fields, not a map

Many web frameworks return route parameters in a map from string to string. With a map, a misspelled key such as `params.get("usr")` returns `null` at runtime.

Here, `p.user` is a struct field. If you write `p.usr`, the build stops, because `Params` has no field with that name. If the pattern changes, each use of an old parameter name stops the build.

## Reject a bad pattern

A pattern can use one name two times, for example `/users/:id/friends/:id`. Then one field would hide the other. `paramNames` compares each name with the earlier names and stops the build:

```zig
const std = @import("std");

fn segmentCount(comptime pattern: []const u8) usize {
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

// "/users/:user" becomes .{ "users", ":user" }.
fn segments(comptime pattern: []const u8) [segmentCount(pattern)][]const u8 {
    var result: [segmentCount(pattern)][]const u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, pattern, '/');
    for (&result) |*segment| segment.* = it.next().?;
    return result;
}

fn paramCount(comptime pattern: []const u8) usize {
    var n: usize = 0;
    for (segments(pattern)) |segment| {
        if (segment[0] == ':') n += 1;
    }
    return n;
}

// The names after each ':', in order. A name that occurs two times
// stops the build.
fn paramNames(comptime pattern: []const u8) [paramCount(pattern)][]const u8 {
    var names: [paramCount(pattern)][]const u8 = undefined;
    var i: usize = 0;
    for (segments(pattern)) |segment| {
        if (segment[0] != ':') continue;
        const name = segment[1..];
        for (names[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, name)) {
                @compileError("route " ++ pattern ++ ": parameter '" ++ name ++ "' occurs two times");
            }
        }
        names[i] = name;
        i += 1;
    }
    return names;
}

fn Route(comptime pattern: []const u8) type {
    const parts = segments(pattern);
    const names = paramNames(pattern);
    return struct {
        // One `[]const u8` field for each parameter in the pattern.
        pub const Params = @Struct(.auto, null, &names, &@splat([]const u8), &@splat(.{}));

        pub fn match(path: []const u8) ?Params {
            var it = std.mem.tokenizeScalar(u8, path, '/');
            var params: Params = undefined;
            // One copy of the body for each segment of the pattern.
            inline for (parts) |part| {
                const got = it.next() orelse return null;
                if (part[0] == ':') {
                    @field(params, part[1..]) = got;
                } else if (!std.mem.eql(u8, got, part)) {
                    return null;
                }
            }
            if (it.next() != null) return null;
            return params;
        }
    };
}

const Friend = Route("/users/:id/friends/:id");

pub fn main() void {
    if (Friend.match("/users/1/friends/2")) |p| std.debug.print("{s}\n", .{p.id});
}
```

The compiler says:

```
error: route /users/:id/friends/:id: parameter 'id' occurs two times
```

*Compiled by CI, but not runnable in the browser sandbox. (`25-comptime.route-duplicate`)*

The error occurs when the compiler evaluates `Route(...)`, not when a request arrives. A bad route that the program uses stops the build, even if no test sends a path to that route.

The compiler evaluates only the code that the program uses. If no code refers to a `Route` constant, the compiler does not evaluate it, and a bad pattern in it gives no error.

## The same method in `std`

`std.Io.Writer.print` parses its format string during compilation. That is why `print("{d}", .{"text"})` is a compile error, not a runtime error. `std.StaticStringMap(V).initComptime` takes a list of key and value pairs and builds a lookup structure during compilation. [Know the Limits](https://www.ziglang.in/learn/metaprogramming/limits/) uses it on a file that the compiler reads.

## Check yourself

`Route("/files/:name")` matches `/files/report.pdf`. Does it match `/files/2026/report.pdf`?

No. The pattern has two segments, and the path has three. The `inline for` handles the two segments of the pattern. Then `it.next()` finds a third segment, and `match` returns `null`.
