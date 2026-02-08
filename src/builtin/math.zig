const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Global random state for math.random/randomseed
var global_prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0);

/// Lua 5.4 Math Library
/// Corresponds to Lua manual chapter "Mathematical Functions"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.7
/// math.abs(x) - Returns the absolute value of x
pub fn nativeMathAbs(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];

    // Try integer first to preserve integer type
    if (arg.toInteger()) |i| {
        vm.stack[vm.base + func_reg] = .{ .integer = if (i < 0) -i else i };
        return;
    }

    if (arg.toNumber()) |n| {
        vm.stack[vm.base + func_reg] = .{ .number = @abs(n) };
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.ceil(x) - Returns the smallest integral value >= x
pub fn nativeMathCeil(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];

    // Integer is already integral
    if (arg == .integer) {
        vm.stack[vm.base + func_reg] = arg;
        return;
    }

    if (arg.toNumber()) |n| {
        const result = @ceil(n);
        // Return as integer if it fits
        if (result >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
            result <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
        {
            vm.stack[vm.base + func_reg] = .{ .integer = @intFromFloat(result) };
        } else {
            vm.stack[vm.base + func_reg] = .{ .number = result };
        }
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.floor(x) - Returns the largest integral value <= x
pub fn nativeMathFloor(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];

    // Integer is already integral
    if (arg == .integer) {
        vm.stack[vm.base + func_reg] = arg;
        return;
    }

    if (arg.toNumber()) |n| {
        const result = @floor(n);
        // Return as integer if it fits
        if (result >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
            result <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
        {
            vm.stack[vm.base + func_reg] = .{ .integer = @intFromFloat(result) };
        } else {
            vm.stack[vm.base + func_reg] = .{ .number = result };
        }
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.max(x, ...) - Returns the maximum value among its arguments
pub fn nativeMathMax(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs == 0) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    var max_val = vm.stack[vm.base + func_reg + 1];
    var max_num = max_val.toNumber() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    var i: u32 = 2;
    while (i <= nargs) : (i += 1) {
        const arg = vm.stack[vm.base + func_reg + i];
        const n = arg.toNumber() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        if (n > max_num) {
            max_num = n;
            max_val = arg;
        }
    }

    vm.stack[vm.base + func_reg] = max_val;
}

/// math.min(x, ...) - Returns the minimum value among its arguments
pub fn nativeMathMin(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs == 0) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    var min_val = vm.stack[vm.base + func_reg + 1];
    var min_num = min_val.toNumber() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    var i: u32 = 2;
    while (i <= nargs) : (i += 1) {
        const arg = vm.stack[vm.base + func_reg + i];
        const n = arg.toNumber() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        if (n < min_num) {
            min_num = n;
            min_val = arg;
        }
    }

    vm.stack[vm.base + func_reg] = min_val;
}

/// math.sqrt(x) - Returns the square root of x
pub fn nativeMathSqrt(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    if (arg.toNumber()) |n| {
        vm.stack[vm.base + func_reg] = .{ .number = @sqrt(n) };
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.acos(x) - Returns the arc cosine of x (in radians)
pub fn nativeMathAcos(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    if (arg.toNumber()) |n| {
        vm.stack[vm.base + func_reg] = .{ .number = std.math.acos(n) };
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.asin(x) - Returns the arc sine of x (in radians)
pub fn nativeMathAsin(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    if (arg.toNumber()) |n| {
        vm.stack[vm.base + func_reg] = .{ .number = std.math.asin(n) };
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.atan(y [, x]) - Returns the arc tangent of y/x (in radians)
pub fn nativeMathAtan(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    const y_arg = vm.stack[vm.base + func_reg + 1];
    const y = y_arg.toNumber() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    if (nargs >= 2) {
        // atan2(y, x)
        const x_arg = vm.stack[vm.base + func_reg + 2];
        const x = x_arg.toNumber() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        vm.stack[vm.base + func_reg] = .{ .number = std.math.atan2(y, x) };
    } else {
        // atan(y)
        vm.stack[vm.base + func_reg] = .{ .number = std.math.atan(y) };
    }
}

/// math.cos(x) - Returns the cosine of x (x is in radians)
pub fn nativeMathCos(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    if (arg.toNumber()) |n| {
        vm.stack[vm.base + func_reg] = .{ .number = @cos(n) };
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.deg(x) - Converts angle x from radians to degrees
pub fn nativeMathDeg(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    if (arg.toNumber()) |n| {
        vm.stack[vm.base + func_reg] = .{ .number = std.math.radiansToDegrees(n) };
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.exp(x) - Returns the value e^x
pub fn nativeMathExp(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    if (arg.toNumber()) |n| {
        vm.stack[vm.base + func_reg] = .{ .number = @exp(n) };
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.fmod(x, y) - Returns the remainder of the division of x by y
pub fn nativeMathFmod(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const x_arg = vm.stack[vm.base + func_reg + 1];
    const y_arg = vm.stack[vm.base + func_reg + 2];

    const x = x_arg.toNumber() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const y = y_arg.toNumber() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // fmod: remainder with quotient truncated toward zero
    vm.stack[vm.base + func_reg] = .{ .number = @rem(x, y) };
}

/// math.log(x [, base]) - Returns the logarithm of x in the given base
pub fn nativeMathLog(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    const x_arg = vm.stack[vm.base + func_reg + 1];
    const x = x_arg.toNumber() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    if (nargs >= 2) {
        // log_base(x) = ln(x) / ln(base)
        const base_arg = vm.stack[vm.base + func_reg + 2];
        const base = base_arg.toNumber() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        vm.stack[vm.base + func_reg] = .{ .number = @log(x) / @log(base) };
    } else {
        // Natural logarithm
        vm.stack[vm.base + func_reg] = .{ .number = @log(x) };
    }
}

/// math.modf(x) - Returns the integral and fractional parts of x
pub fn nativeMathModf(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    const x = arg.toNumber() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) vm.stack[vm.base + func_reg + 1] = .nil;
        return;
    };

    const integral = @trunc(x);
    const fractional = x - integral;

    // First result: integral part (as integer if it fits)
    if (integral >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
        integral <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
    {
        vm.stack[vm.base + func_reg] = .{ .integer = @intFromFloat(integral) };
    } else {
        vm.stack[vm.base + func_reg] = .{ .number = integral };
    }

    // Second result: fractional part
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = .{ .number = fractional };
    }
}

/// math.rad(x) - Converts angle x from degrees to radians
pub fn nativeMathRad(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    if (arg.toNumber()) |n| {
        vm.stack[vm.base + func_reg] = .{ .number = std.math.degreesToRadians(n) };
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.random([m [, n]]) - Returns a pseudo-random number
pub fn nativeMathRandom(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    var random = global_prng.random();

    if (nargs == 0) {
        // No args: return [0, 1)
        vm.stack[vm.base + func_reg] = .{ .number = random.float(f64) };
    } else if (nargs == 1) {
        // One arg: return [1, m]
        const m_arg = vm.stack[vm.base + func_reg + 1];
        const m = m_arg.toInteger() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        if (m < 1) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }
        const result = random.intRangeAtMost(i64, 1, m);
        vm.stack[vm.base + func_reg] = .{ .integer = result };
    } else {
        // Two args: return [m, n]
        const m_arg = vm.stack[vm.base + func_reg + 1];
        const n_arg = vm.stack[vm.base + func_reg + 2];
        const m = m_arg.toInteger() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        const n = n_arg.toInteger() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        if (m > n) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }
        const result = random.intRangeAtMost(i64, m, n);
        vm.stack[vm.base + func_reg] = .{ .integer = result };
    }
}

/// math.randomseed([x [, y]]) - Sets x and y as the seed for the pseudo-random generator
pub fn nativeMathRandomseed(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    var seed: u64 = 0;

    if (nargs >= 1) {
        const x_arg = vm.stack[vm.base + func_reg + 1];
        if (x_arg.toInteger()) |x| {
            seed = @bitCast(x);
        } else if (x_arg.toNumber()) |x| {
            seed = @bitCast(@as(i64, @intFromFloat(x)));
        }
    }

    if (nargs >= 2) {
        const y_arg = vm.stack[vm.base + func_reg + 2];
        if (y_arg.toInteger()) |y| {
            seed ^= @bitCast(y);
        } else if (y_arg.toNumber()) |y| {
            seed ^= @bitCast(@as(i64, @intFromFloat(y)));
        }
    }

    global_prng = std.Random.DefaultPrng.init(seed);
}

/// math.sin(x) - Returns the sine of x (x is in radians)
pub fn nativeMathSin(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    if (arg.toNumber()) |n| {
        vm.stack[vm.base + func_reg] = .{ .number = @sin(n) };
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.tan(x) - Returns the tangent of x (x is in radians)
pub fn nativeMathTan(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    if (arg.toNumber()) |n| {
        vm.stack[vm.base + func_reg] = .{ .number = @tan(n) };
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.tointeger(x) - Converts x to an integer if possible
pub fn nativeMathTointeger(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];

    // If already an integer, return it
    if (arg == .integer) {
        vm.stack[vm.base + func_reg] = arg;
        return;
    }

    // Try to convert number to integer (only if it's an exact integer)
    if (arg == .number) {
        const n = arg.number;
        const truncated = @trunc(n);
        if (n == truncated and
            truncated >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
            truncated <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
        {
            vm.stack[vm.base + func_reg] = .{ .integer = @intFromFloat(truncated) };
            return;
        }
    }

    // Try string conversion
    if (arg.asString()) |s| {
        const slice = s.asSlice();
        if (std.fmt.parseInt(i64, slice, 10)) |i| {
            vm.stack[vm.base + func_reg] = .{ .integer = i };
            return;
        } else |_| {}
    }

    vm.stack[vm.base + func_reg] = .nil;
}

/// math.type(x) - Returns "integer" if x is an integer, "float" if it's a float, or nil
pub fn nativeMathType(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];

    if (arg == .integer) {
        const str = try vm.gc.allocString("integer");
        vm.stack[vm.base + func_reg] = TValue.fromString(str);
    } else if (arg == .number) {
        const str = try vm.gc.allocString("float");
        vm.stack[vm.base + func_reg] = TValue.fromString(str);
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// math.ult(m, n) - Returns true if integer m is below integer n when compared as unsigned integers
pub fn nativeMathUlt(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const m_arg = vm.stack[vm.base + func_reg + 1];
    const n_arg = vm.stack[vm.base + func_reg + 2];

    const m = m_arg.toInteger() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const n = n_arg.toInteger() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Compare as unsigned
    const um: u64 = @bitCast(m);
    const un: u64 = @bitCast(n);
    vm.stack[vm.base + func_reg] = .{ .boolean = um < un };
}

/// math.pi - The value of π
pub const MATH_PI: f64 = std.math.pi;

/// math.huge - A value larger than any other numeric value
pub const MATH_HUGE: f64 = std.math.inf(f64);

/// math.maxinteger - An integer with the maximum value for an integer
pub const MATH_MAXINTEGER: i64 = std.math.maxInt(i64);

/// math.mininteger - An integer with the minimum value for an integer
pub const MATH_MININTEGER: i64 = std.math.minInt(i64);
