const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Lua 5.4 String Library
/// Corresponds to Lua manual chapter "String Manipulation"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.4
fn formatNumber(allocator: std.mem.Allocator, n: f64) ![]const u8 {
    // Handle integers that fit in i64 range and have no fractional part
    const min_i64: f64 = @floatFromInt(std.math.minInt(i64));
    const max_i64: f64 = @floatFromInt(std.math.maxInt(i64));
    if (n == @floor(n) and n >= min_i64 and n <= max_i64) {
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

    // Use GC for string allocation
    const allocator = vm.allocator;

    const result = if (arg) |v| blk: {
        break :blk switch (v.*) {
            .number => |n| ret: {
                const formatted = try formatNumber(allocator, n);
                defer allocator.free(formatted);
                break :ret TValue.fromString(try vm.gc.allocString(formatted));
            },
            .integer => |i| ret: {
                const formatted = try formatInteger(allocator, i);
                defer allocator.free(formatted);
                break :ret TValue.fromString(try vm.gc.allocString(formatted));
            },
            .nil => TValue.fromString(try vm.gc.allocString("nil")),
            .boolean => |b| TValue.fromString(try vm.gc.allocString(if (b) "true" else "false")),
            .object => |obj| switch (obj.type) {
                .string => v.*,
                .table => TValue.fromString(try vm.gc.allocString("<table>")),
                .closure, .native_closure => TValue.fromString(try vm.gc.allocString("<function>")),
                .upvalue => TValue.fromString(try vm.gc.allocString("<upvalue>")),
                .userdata => TValue.fromString(try vm.gc.allocString("<userdata>")),
            },
        };
    } else TValue.fromString(try vm.gc.allocString("nil"));

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
/// Supports: %s (string), %d/%i (integer), %f (float), %x/%X (hex), %o (octal), %c (char), %q (quoted), %% (literal %)
/// Also supports width and precision: %10s, %.2f, %08d, etc.
pub fn nativeStringFormat(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = .nil;
        }
        return;
    }

    // Get format string
    const fmt_arg = vm.stack[vm.base + func_reg + 1];
    const fmt_str = fmt_arg.asString() orelse {
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = .nil;
        }
        return;
    };
    const fmt = fmt_str.asSlice();

    // Build result string
    const allocator = vm.allocator;
    var result = try std.ArrayList(u8).initCapacity(allocator, fmt.len * 2);
    defer result.deinit(allocator);

    var arg_idx: u32 = 2; // Start after format string
    var i: usize = 0;

    while (i < fmt.len) {
        if (fmt[i] != '%') {
            try result.append(allocator, fmt[i]);
            i += 1;
            continue;
        }

        i += 1; // Skip '%'
        if (i >= fmt.len) break;

        // Handle %%
        if (fmt[i] == '%') {
            try result.append(allocator, '%');
            i += 1;
            continue;
        }

        // Parse flags: -, +, space, #, 0
        var left_justify = false;
        var show_sign = false;
        var space_sign = false;
        var alt_form = false;
        var zero_pad = false;

        while (i < fmt.len) {
            switch (fmt[i]) {
                '-' => left_justify = true,
                '+' => show_sign = true,
                ' ' => space_sign = true,
                '#' => alt_form = true,
                '0' => zero_pad = true,
                else => break,
            }
            i += 1;
        }

        // Parse width
        var width: usize = 0;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') {
            width = width * 10 + (fmt[i] - '0');
            i += 1;
        }

        // Parse precision
        var precision: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            precision = 0;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') {
                precision.? = precision.? * 10 + (fmt[i] - '0');
                i += 1;
            }
        }

        if (i >= fmt.len) break;

        const spec = fmt[i];
        i += 1;

        // Get next argument if needed
        const arg = if (arg_idx <= nargs) vm.stack[vm.base + func_reg + arg_idx] else TValue.nil;
        arg_idx += 1;

        // Format based on specifier
        switch (spec) {
            's' => {
                // String
                const str = if (arg.asString()) |s| s.asSlice() else "nil";
                const effective_str = if (precision) |p| str[0..@min(p, str.len)] else str;
                try padAndAppend(allocator, &result, effective_str, width, left_justify, ' ');
            },
            'd', 'i' => {
                // Integer
                const val = arg.toInteger() orelse 0;
                var buf: [32]u8 = undefined;
                const num_str = formatIntBuf(&buf, val, show_sign, space_sign);
                const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
                try padAndAppend(allocator, &result, num_str, width, left_justify, pad_char);
            },
            'u' => {
                // Unsigned integer
                const val = arg.toInteger() orelse 0;
                const uval: u64 = @bitCast(val);
                var buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&buf, "{d}", .{uval}) catch "0";
                const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
                try padAndAppend(allocator, &result, num_str, width, left_justify, pad_char);
            },
            'x', 'X' => {
                // Hexadecimal
                const val = arg.toInteger() orelse 0;
                const uval: u64 = @bitCast(val);
                var buf: [32]u8 = undefined;
                const num_str = if (spec == 'x')
                    std.fmt.bufPrint(&buf, "{x}", .{uval}) catch "0"
                else
                    std.fmt.bufPrint(&buf, "{X}", .{uval}) catch "0";
                if (alt_form and uval != 0) {
                    try result.appendSlice(allocator, if (spec == 'x') "0x" else "0X");
                }
                const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
                try padAndAppend(allocator, &result, num_str, width, left_justify, pad_char);
            },
            'o' => {
                // Octal
                const val = arg.toInteger() orelse 0;
                const uval: u64 = @bitCast(val);
                var buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&buf, "{o}", .{uval}) catch "0";
                if (alt_form and uval != 0) {
                    try result.append(allocator, '0');
                }
                const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
                try padAndAppend(allocator, &result, num_str, width, left_justify, pad_char);
            },
            'f', 'F' => {
                // Float
                const val = arg.toNumber() orelse 0.0;
                const prec = precision orelse 6;
                var buf: [64]u8 = undefined;
                const num_str = formatFloatBuf(&buf, val, prec, show_sign, space_sign);
                const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
                try padAndAppend(allocator, &result, num_str, width, left_justify, pad_char);
            },
            'e', 'E' => {
                // Scientific notation
                const val = arg.toNumber() orelse 0.0;
                const prec = precision orelse 6;
                var buf: [64]u8 = undefined;
                const num_str = if (spec == 'e')
                    std.fmt.bufPrint(&buf, "{e}", .{val}) catch "0"
                else
                    std.fmt.bufPrint(&buf, "{E}", .{val}) catch "0";
                _ = prec; // TODO: Apply precision
                const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
                try padAndAppend(allocator, &result, num_str, width, left_justify, pad_char);
            },
            'g', 'G' => {
                // General (shortest of %e or %f)
                const val = arg.toNumber() orelse 0.0;
                var buf: [64]u8 = undefined;
                const num_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "0";
                const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
                try padAndAppend(allocator, &result, num_str, width, left_justify, pad_char);
            },
            'c' => {
                // Character
                const val = arg.toInteger() orelse 0;
                if (val >= 0 and val <= 255) {
                    try result.append(allocator, @intCast(@as(u64, @bitCast(val))));
                }
            },
            'q' => {
                // Quoted string
                const str = if (arg.asString()) |s| s.asSlice() else "nil";
                try result.append(allocator, '"');
                for (str) |c| {
                    switch (c) {
                        '"' => try result.appendSlice(allocator, "\\\""),
                        '\\' => try result.appendSlice(allocator, "\\\\"),
                        '\n' => try result.appendSlice(allocator, "\\n"),
                        '\r' => try result.appendSlice(allocator, "\\r"),
                        '\t' => try result.appendSlice(allocator, "\\t"),
                        else => try result.append(allocator, c),
                    }
                }
                try result.append(allocator, '"');
            },
            else => {
                // Unknown specifier, output as-is
                try result.append(allocator, '%');
                try result.append(allocator, spec);
            },
        }
    }

    // Allocate result string via GC
    const result_str = try vm.gc.allocString(result.items);

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromString(result_str);
    }
}

/// Helper: Format integer to buffer with optional sign
fn formatIntBuf(buf: []u8, val: i64, show_sign: bool, space_sign: bool) []const u8 {
    if (val >= 0) {
        if (show_sign) {
            return std.fmt.bufPrint(buf, "+{d}", .{val}) catch "0";
        } else if (space_sign) {
            return std.fmt.bufPrint(buf, " {d}", .{val}) catch "0";
        } else {
            return std.fmt.bufPrint(buf, "{d}", .{val}) catch "0";
        }
    } else {
        return std.fmt.bufPrint(buf, "{d}", .{val}) catch "0";
    }
}

/// Helper: Format float to buffer with precision
fn formatFloatBuf(buf: []u8, val: f64, precision: usize, show_sign: bool, space_sign: bool) []const u8 {
    // Build format result manually
    var writer = std.io.fixedBufferStream(buf);
    const w = writer.writer();

    if (val >= 0) {
        if (show_sign) {
            w.writeByte('+') catch {};
        } else if (space_sign) {
            w.writeByte(' ') catch {};
        }
    }

    // Format with precision
    std.fmt.format(w, "{d:.[1]}", .{ val, precision }) catch {};

    return writer.getWritten();
}

/// Helper: Pad string to width and append to result
fn padAndAppend(allocator: std.mem.Allocator, result: *std.ArrayList(u8), str: []const u8, width: usize, left_justify: bool, pad_char: u8) !void {
    if (str.len >= width) {
        try result.appendSlice(allocator, str);
        return;
    }

    const padding = width - str.len;

    if (left_justify) {
        try result.appendSlice(allocator, str);
        try result.appendNTimes(allocator, pad_char, padding);
    } else {
        try result.appendNTimes(allocator, pad_char, padding);
        try result.appendSlice(allocator, str);
    }
}

/// string.dump(function [, strip]) - Returns binary representation of function
pub fn nativeStringDump(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement string.dump
    // Returns binary chunk (bytecode) that can be loaded back with load()
    // Requires access to bytecode generation/serialization
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
