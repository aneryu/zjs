pub const PI = std.math.pi;
pub const E = std.math.e;

pub fn abs(value: f64) f64 {
    return @abs(value);
}

pub fn max(a: f64, b: f64) f64 {
    return if (a > b) a else b;
}

const std = @import("std");
