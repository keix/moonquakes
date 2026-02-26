const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

const LuaRng = struct {
    state: [4]u64,

    fn rotl(x: u64, k: u7) u64 {
        const kk: u6 = @intCast(k);
        if (kk == 0) return x;
        const rshift: u6 = @intCast(@as(u7, 64) - k);
        return (x << kk) | (x >> rshift);
    }

    fn next(self: *LuaRng) u64 {
        const s0 = self.state[0];
        const s1 = self.state[1];
        const s2 = self.state[2];
        const s3 = self.state[3];

        const result = rotl(s1 *% 5, 7) *% 9;
        const t = s1 << 17;

        self.state[2] = s2 ^ s0;
        self.state[3] = s3 ^ s1;
        self.state[1] = s1 ^ self.state[2];
        self.state[0] = s0 ^ self.state[3];
        self.state[2] ^= t;
        self.state[3] = rotl(self.state[3], 45);

        return result;
    }

    fn seed(self: *LuaRng, seed1: u64, seed2: u64) void {
        self.state = .{ seed1, 0xff, seed2, 0 };
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            _ = self.next();
        }
    }
};

/// Global random state for math.random/randomseed (Lua 5.4 xoshiro256**)
var global_rng: LuaRng = .{ .state = .{ 0, 0, 0, 0 } };
var rng_seed1: u64 = 0;
var rng_seed2: u64 = 0;
var rng_initialized: bool = false;

fn setRngSeeds(seed1: u64, seed2: u64) void {
    rng_seed1 = seed1;
    rng_seed2 = seed2;
    global_rng.seed(seed1, seed2);
    rng_initialized = true;
}

fn ensureRng() void {
    if (!rng_initialized) {
        setRngSeeds(0, 0);
    }
}

fn nextRand() u64 {
    ensureRng();
    return global_rng.next();
}

fn seedFromArg(arg: TValue) ?u64 {
    if (arg.toInteger()) |i| return @bitCast(i);
    if (arg.toNumber()) |n| {
        if (floatToIntExact(n)) |i| return @bitCast(i);
    }
    return null;
}

fn randFloat() f64 {
    const floatbits: u7 = std.math.floatMantissaBits(f64) + 1;
    const r = nextRand();
    const shift: u7 = @as(u7, 64) - floatbits;
    const top = r >> @intCast(shift);
    const denom = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(floatbits)));
    return @as(f64, @floatFromInt(top)) / denom;
}

fn randRawInt() i64 {
    const intbits: u7 = @bitSizeOf(i64);
    const r = nextRand();
    if (intbits >= 64) {
        return @bitCast(r);
    }
    const mask: u64 = (@as(u64, 1) << @intCast(intbits)) - 1;
    return @as(i64, @intCast(r & mask));
}

fn randUniform(range: u64) u64 {
    if (range == std.math.maxInt(u64)) {
        return nextRand();
    }
    const limit = std.math.maxInt(u64) - (std.math.maxInt(u64) % (range + 1));
    while (true) {
        const r = nextRand();
        if (r < limit) return r % (range + 1);
    }
}

fn randRange(min: i64, max: i64) i64 {
    if (min == max) return min;
    const range_u128: u128 = @intCast(@as(i128, max) - @as(i128, min));
    const range: u64 = @intCast(range_u128);
    const offset = randUniform(range);
    const res: i128 = @as(i128, min) + @as(i128, offset);
    return @intCast(res);
}

fn intFitsFloat(i: i64) bool {
    const max_exact: i64 = @as(i64, 1) << 53;
    return i >= -max_exact and i <= max_exact;
}

fn floatToIntChecked(f: f64) ?i64 {
    if (!std.math.isFinite(f)) return null;
    const max_i = std.math.maxInt(i64);
    const min_i = std.math.minInt(i64);
    const max_f = @as(f64, @floatFromInt(max_i));
    const min_f = @as(f64, @floatFromInt(min_i));
    if (f < min_f or f > max_f) return null;
    if (!intFitsFloat(max_i) and f >= max_f) return null;
    return @as(i64, @intFromFloat(f));
}

fn floatToIntFloor(f: f64) ?i64 {
    return floatToIntChecked(@floor(f));
}

fn floatToIntCeil(f: f64) ?i64 {
    return floatToIntChecked(@ceil(f));
}

fn floatToIntExact(n: f64) ?i64 {
    if (!std.math.isFinite(n)) return null;
    if (n != @floor(n)) return null;
    const max_i = std.math.maxInt(i64);
    const min_i = std.math.minInt(i64);
    const max_f = @as(f64, @floatFromInt(max_i));
    const min_f = @as(f64, @floatFromInt(min_i));
    if (n < min_f or n > max_f) return null;
    if (!intFitsFloat(max_i) and n >= max_f) return null;
    const i: i64 = @intFromFloat(n);
    if (@as(f64, @floatFromInt(i)) != n) return null;
    return i;
}

fn compareIntFloat(i: i64, f: f64, comptime le: bool) bool {
    if (std.math.isNan(f)) return false;
    if (intFitsFloat(i)) {
        const i_f = @as(f64, @floatFromInt(i));
        return if (le) i_f <= f else i_f < f;
    }
    if (le) {
        if (floatToIntFloor(f)) |fi| {
            return i <= fi;
        }
        return f > 0;
    }
    if (floatToIntCeil(f)) |fi| {
        return i < fi;
    }
    return f > 0;
}

fn compareFloatInt(f: f64, i: i64, comptime le: bool) bool {
    if (std.math.isNan(f)) return false;
    if (intFitsFloat(i)) {
        const i_f = @as(f64, @floatFromInt(i));
        return if (le) f <= i_f else f < i_f;
    }
    if (le) {
        if (floatToIntCeil(f)) |fi| {
            return fi <= i;
        }
        return f < 0;
    }
    if (floatToIntFloor(f)) |fi| {
        return fi < i;
    }
    return f < 0;
}

fn coerceToNumeric(arg: TValue) ?TValue {
    if (arg.isInteger() or arg.isNumber()) return arg;
    if (arg.toNumber()) |n| return TValue{ .number = n };
    return null;
}

fn numLess(a: TValue, b: TValue) bool {
    if (a.isInteger() and b.isInteger()) return a.integer < b.integer;
    if (a.isNumber() and b.isNumber()) return a.number < b.number;
    if (a.isInteger() and b.isNumber()) return compareIntFloat(a.integer, b.number, false);
    if (a.isNumber() and b.isInteger()) return compareFloatInt(a.number, b.integer, false);
    return false;
}

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
        vm.stack[vm.base + func_reg] = .{ .integer = if (i < 0) 0 -% i else i };
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
        if (floatToIntExact(result)) |i| {
            vm.stack[vm.base + func_reg] = .{ .integer = i };
        } else {
            vm.stack[vm.base + func_reg] = .{ .number = result };
        }
    } else {
        return vm.raiseString("number expected");
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
        if (floatToIntExact(result)) |i| {
            vm.stack[vm.base + func_reg] = .{ .integer = i };
        } else {
            vm.stack[vm.base + func_reg] = .{ .number = result };
        }
    } else {
        return vm.raiseString("number expected");
    }
}

/// math.max(x, ...) - Returns the maximum value among its arguments
pub fn nativeMathMax(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs == 0) {
        return vm.raiseString("value expected");
    }

    var max_val = coerceToNumeric(vm.stack[vm.base + func_reg + 1]) orelse return vm.raiseString("number expected");

    var i: u32 = 2;
    while (i <= nargs) : (i += 1) {
        const arg = coerceToNumeric(vm.stack[vm.base + func_reg + i]) orelse return vm.raiseString("number expected");
        if (numLess(max_val, arg)) {
            max_val = arg;
        }
    }

    vm.stack[vm.base + func_reg] = max_val;
}

/// math.min(x, ...) - Returns the minimum value among its arguments
pub fn nativeMathMin(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs == 0) {
        return vm.raiseString("value expected");
    }

    var min_val = coerceToNumeric(vm.stack[vm.base + func_reg + 1]) orelse return vm.raiseString("number expected");

    var i: u32 = 2;
    while (i <= nargs) : (i += 1) {
        const arg = coerceToNumeric(vm.stack[vm.base + func_reg + i]) orelse return vm.raiseString("number expected");
        if (numLess(arg, min_val)) {
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

    if (x_arg.isInteger() and y_arg.isInteger()) {
        const x = x_arg.integer;
        const y = y_arg.integer;
        if (y == 0) return vm.raiseString("divide by zero");
        if (y == -1) {
            vm.stack[vm.base + func_reg] = .{ .integer = 0 };
            return;
        }
        vm.stack[vm.base + func_reg] = .{ .integer = @rem(x, y) };
        return;
    }

    const x = x_arg.toNumber() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const y = y_arg.toNumber() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    if (y == 0.0) return vm.raiseString("divide by zero");

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
    const fractional = if (std.math.isInf(x)) 0.0 else x - integral;

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
    if (nargs > 2) return vm.raiseString("wrong number of arguments");

    if (nargs == 0) {
        // No args: return [0, 1)
        vm.stack[vm.base + func_reg] = .{ .number = randFloat() };
    } else if (nargs == 1) {
        // One arg: return [1, m] (or raw int if m == 0)
        const m_arg = vm.stack[vm.base + func_reg + 1];
        const m = m_arg.toInteger() orelse return vm.raiseString("number expected");
        if (m == 0) {
            vm.stack[vm.base + func_reg] = .{ .integer = randRawInt() };
            return;
        }
        if (m < 1) return vm.raiseString("interval is empty");
        vm.stack[vm.base + func_reg] = .{ .integer = randRange(1, m) };
    } else {
        // Two args: return [m, n]
        const m_arg = vm.stack[vm.base + func_reg + 1];
        const n_arg = vm.stack[vm.base + func_reg + 2];
        const m = m_arg.toInteger() orelse return vm.raiseString("number expected");
        const n = n_arg.toInteger() orelse return vm.raiseString("number expected");
        if (m > n) return vm.raiseString("interval is empty");
        vm.stack[vm.base + func_reg] = .{ .integer = randRange(m, n) };
    }
}

/// math.randomseed([x [, y]]) - Sets x and y as the seed for the pseudo-random generator
pub fn nativeMathRandomseed(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    var seed1 = rng_seed1;
    var seed2 = rng_seed2;

    if (nargs >= 1) {
        const x_arg = vm.stack[vm.base + func_reg + 1];
        seed1 = seedFromArg(x_arg) orelse return vm.raiseString("number expected");
    }

    if (nargs >= 2) {
        const y_arg = vm.stack[vm.base + func_reg + 2];
        seed2 = seedFromArg(y_arg) orelse return vm.raiseString("number expected");
    }

    if (nargs == 0 and !rng_initialized) {
        setRngSeeds(0, 0);
    } else {
        setRngSeeds(seed1, seed2);
    }

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = .{ .integer = @bitCast(rng_seed1) };
    }
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = .{ .integer = @bitCast(rng_seed2) };
    }
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
        if (floatToIntExact(arg.number)) |i| {
            vm.stack[vm.base + func_reg] = .{ .integer = i };
            return;
        }
    }

    // Try string conversion
    if (arg.asString()) |s| {
        const slice = std.mem.trim(u8, s.asSlice(), " \t\n\r");
        if (std.fmt.parseInt(i64, slice, 10)) |i| {
            vm.stack[vm.base + func_reg] = .{ .integer = i };
            return;
        } else |_| {}
        if (std.fmt.parseFloat(f64, slice)) |n| {
            if (floatToIntExact(n)) |i| {
                vm.stack[vm.base + func_reg] = .{ .integer = i };
                return;
            }
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
        const str = try vm.gc().allocString("integer");
        vm.stack[vm.base + func_reg] = TValue.fromString(str);
    } else if (arg == .number) {
        const str = try vm.gc().allocString("float");
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
