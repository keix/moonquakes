const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Lua 5.4 Math Library
/// Corresponds to Lua manual chapter "Mathematical Functions"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.7
/// math.abs(x) - Returns the absolute value of x
pub fn nativeMathAbs(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement math.abs
}

/// math.ceil(x) - Returns the smallest integral value >= x
pub fn nativeMathCeil(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement math.ceil
}

/// math.floor(x) - Returns the largest integral value <= x
pub fn nativeMathFloor(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement math.floor
}

/// math.max(x, ...) - Returns the maximum value among its arguments
pub fn nativeMathMax(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement math.max
}

/// math.min(x, ...) - Returns the minimum value among its arguments
pub fn nativeMathMin(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement math.min
}

/// math.sqrt(x) - Returns the square root of x
pub fn nativeMathSqrt(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement math.sqrt
}

/// math.pi - The value of π
pub const MATH_PI: f64 = std.math.pi;

/// math.huge - A value larger than any other numeric value
pub const MATH_HUGE: f64 = std.math.inf(f64);
