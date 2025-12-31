const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Lua 5.4 String Library
/// Corresponds to Lua manual chapter "String Manipulation"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.4
fn formatNumber(allocator: std.mem.Allocator, n: f64) ![]const u8 {
    // Handle integers that fit in i64 range and have no fractional part
    if (n == @floor(n) and n >= std.math.minInt(i64) and n <= std.math.maxInt(i64)) {
        const int_val: i64 = @intFromFloat(n);
        return try std.fmt.allocPrint(allocator, "{d}", .{int_val});
    }
    // Handle floating point numbers
    return try std.fmt.allocPrint(allocator, "{}", .{n});
}

fn formatInteger(allocator: std.mem.Allocator, i: i64) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{d}", .{i});
}

pub fn nativeToString(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const arg = if (nargs > 0) &vm.stack[vm.base + func_reg + 1] else null;

    // Use arena allocator for string management
    // TODO: Replace with vm.gc.allocString() when GC is implemented
    const arena_allocator = vm.arena.allocator();

    const result = if (arg) |v| switch (v.*) {
        .number => |n| TValue{ .string = try formatNumber(arena_allocator, n) },
        .integer => |i| TValue{ .string = try formatInteger(arena_allocator, i) },
        .string => v.*,
        .nil => TValue{ .string = "nil" },
        .boolean => |b| TValue{ .string = if (b) "true" else "false" },
        .function => TValue{ .string = "<function>" },
        .table => TValue{ .string = "<table>" },
        .closure => TValue{ .string = "<function>" },
    } else TValue{ .string = "nil" };

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
}

/// string.len(s) - Returns the length of string s
pub fn nativeStringLen(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.len
    // Returns number of bytes in string (not UTF-8 characters)
}

/// string.sub(s, i [, j]) - Returns substring of s from i to j
pub fn nativeStringSub(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.sub
    // Negative indices count from end of string
}

/// string.upper(s) - Returns copy of s with all lowercase letters changed to uppercase
pub fn nativeStringUpper(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.upper
}

/// string.lower(s) - Returns copy of s with all uppercase letters changed to lowercase
pub fn nativeStringLower(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.lower
}

/// string.byte(s [, i [, j]]) - Returns internal numeric codes of characters in string
pub fn nativeStringByte(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.byte
    // Returns byte values at positions i to j (default i=1, j=i)
}

/// string.char(...) - Returns string with characters having given numeric codes
pub fn nativeStringChar(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.char
    // Takes numeric codes and returns corresponding string
}

/// string.rep(s, n [, sep]) - Returns string that is concatenation of n copies of s separated by sep
pub fn nativeStringRep(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.rep
}

/// string.reverse(s) - Returns string that is the reverse of s
pub fn nativeStringReverse(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.reverse
}

/// string.find(s, pattern [, init [, plain]]) - Looks for first match of pattern in string s
pub fn nativeStringFind(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.find
    // Returns start/end indices or nil if not found
}

/// string.match(s, pattern [, init]) - Looks for first match of pattern in string s
pub fn nativeStringMatch(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.match
    // Returns captured strings or whole match
}

/// string.gmatch(s, pattern) - Returns iterator for all matches of pattern in string s
pub fn nativeStringGmatch(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.gmatch
    // Returns iterator function for use in for loops
}

/// string.gsub(s, pattern, repl [, n]) - Returns copy of s with all/first n occurrences of pattern replaced by repl
pub fn nativeStringGsub(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.gsub
    // Returns new string and number of substitutions made
}

/// string.format(formatstring, ...) - Returns formatted version of its variable number of arguments
pub fn nativeStringFormat(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.format
    // Similar to sprintf with %d, %s, %f, etc.
}

/// string.pack(fmt, v1, v2, ...) - Returns binary string containing values v1, v2, etc. packed according to format fmt
pub fn nativeStringPack(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.pack
    // Binary packing with format specifiers
}

/// string.unpack(fmt, s [, pos]) - Returns values packed in string s according to format fmt
pub fn nativeStringUnpack(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.unpack
    // Binary unpacking with format specifiers
}

/// string.packsize(fmt) - Returns size of a string resulting from string.pack with given format
pub fn nativeStringPacksize(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.packsize
}
