//! A helper module imported by `imports.zig`. The leading underscore keeps
//! the build from treating it as a snippet of its own.

/// Only `pub` declarations are visible to importers.
pub const pi = 3.1415926535;

pub const Circle = struct {
    radius: f64,

    pub fn area(self: Circle) f64 {
        return pi * self.radius * self.radius;
    }
};

/// Not `pub`: invisible outside this file.
const secret = 42;

pub fn double(n: i32) i32 {
    return n * 2 + secret - secret;
}
