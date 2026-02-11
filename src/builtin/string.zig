const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const call = @import("../vm/call.zig");

/// Lua 5.4 String Library
/// Corresponds to Lua manual chapter "String Manipulation"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.4
/// Format number to string using stack buffer (no allocation)
fn formatNumber(buf: []u8, n: f64) []const u8 {
    // Handle integers that fit in i64 range and have no fractional part
    const min_i64: f64 = @floatFromInt(std.math.minInt(i64));
    const max_i64: f64 = @floatFromInt(std.math.maxInt(i64));
    if (n == @floor(n) and n >= min_i64 and n <= max_i64) {
        const int_val: i64 = @intFromFloat(n);
        return std.fmt.bufPrint(buf, "{d}", .{int_val}) catch buf[0..0];
    }
    // Handle floating point numbers
    return std.fmt.bufPrint(buf, "{}", .{n}) catch buf[0..0];
}

/// Format integer to string using stack buffer (no allocation)
fn formatInteger(buf: []u8, i: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{i}) catch buf[0..0];
}

pub fn nativeToString(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const arg = if (nargs > 0) &vm.stack[vm.base + func_reg + 1] else null;

    // Stack buffer for number formatting (64 bytes covers i64 range and f64)
    var buf: [64]u8 = undefined;

    const result = if (arg) |v| blk: {
        break :blk switch (v.*) {
            .number => |n| ret: {
                const formatted = formatNumber(&buf, n);
                break :ret TValue.fromString(try vm.gc.allocString(formatted));
            },
            .integer => |i| ret: {
                const formatted = formatInteger(&buf, i);
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
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    if (arg.asString()) |s| {
        vm.stack[vm.base + func_reg] = .{ .integer = @intCast(s.asSlice().len) };
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// string.sub(s, i [, j]) - Returns substring of s from i to j
pub fn nativeStringSub(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 2) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get string
    const str_arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = str_arg.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();
    const len: i64 = @intCast(str.len);

    // Get i (1-based, can be negative)
    const i_arg = vm.stack[vm.base + func_reg + 2];
    var i: i64 = i_arg.toInteger() orelse 1;

    // Get j (optional, defaults to -1 meaning end of string)
    var j: i64 = -1;
    if (nargs > 2) {
        const j_arg = vm.stack[vm.base + func_reg + 3];
        j = j_arg.toInteger() orelse -1;
    }

    // Handle negative indices (count from end)
    if (i < 0) i = len + i + 1;
    if (j < 0) j = len + j + 1;

    // Clamp to valid range
    if (i < 1) i = 1;
    if (j > len) j = len;

    // Return empty string if range is invalid
    if (i > j) {
        const empty_str = try vm.gc.allocString("");
        vm.stack[vm.base + func_reg] = TValue.fromString(empty_str);
        return;
    }

    // Convert to 0-based indices
    const start: usize = @intCast(i - 1);
    const end: usize = @intCast(j);

    // Create substring
    const result = try vm.gc.allocString(str[start..end]);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}

/// string.upper(s) - Returns copy of s with all lowercase letters changed to uppercase
pub fn nativeStringUpper(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();

    // Allocate buffer for uppercase string
    const buf = try vm.allocator.alloc(u8, str.len);
    defer vm.allocator.free(buf);

    for (str, 0..) |c, i| {
        buf[i] = std.ascii.toUpper(c);
    }

    const result = try vm.gc.allocString(buf);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}

/// string.lower(s) - Returns copy of s with all uppercase letters changed to lowercase
pub fn nativeStringLower(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();

    // Allocate buffer for lowercase string
    const buf = try vm.allocator.alloc(u8, str.len);
    defer vm.allocator.free(buf);

    for (str, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }

    const result = try vm.gc.allocString(buf);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}

/// string.byte(s [, i [, j]]) - Returns internal numeric codes of characters in string
pub fn nativeStringByte(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    const str_arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = str_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();
    const len: i64 = @intCast(str.len);

    if (len == 0) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get i (1-based, default 1)
    var i: i64 = 1;
    if (nargs > 1) {
        const i_arg = vm.stack[vm.base + func_reg + 2];
        i = i_arg.toInteger() orelse 1;
    }

    // Get j (default i)
    var j: i64 = i;
    if (nargs > 2) {
        const j_arg = vm.stack[vm.base + func_reg + 3];
        j = j_arg.toInteger() orelse i;
    }

    // Handle negative indices
    if (i < 0) i = len + i + 1;
    if (j < 0) j = len + j + 1;

    // Clamp to valid range
    if (i < 1) i = 1;
    if (j > len) j = len;

    if (i > j or i > len) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Return byte values
    const start: usize = @intCast(i - 1);
    const end: usize = @intCast(j);
    var result_count: u32 = 0;

    for (start..end) |idx| {
        if (result_count >= nresults) break;
        vm.stack[vm.base + func_reg + result_count] = .{ .integer = str[idx] };
        result_count += 1;
    }
}

/// string.char(...) - Returns string with characters having given numeric codes
pub fn nativeStringChar(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs == 0) {
        const result = try vm.gc.allocString("");
        vm.stack[vm.base + func_reg] = TValue.fromString(result);
        return;
    }

    // Allocate buffer for characters
    const buf = try vm.allocator.alloc(u8, nargs);
    defer vm.allocator.free(buf);

    var i: u32 = 0;
    while (i < nargs) : (i += 1) {
        const arg = vm.stack[vm.base + func_reg + 1 + i];
        const code = arg.toInteger() orelse 0;
        if (code >= 0 and code <= 255) {
            buf[i] = @intCast(@as(u64, @bitCast(code)));
        } else {
            buf[i] = 0;
        }
    }

    const result = try vm.gc.allocString(buf);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}

/// string.rep(s, n [, sep]) - Returns string that is concatenation of n copies of s separated by sep
pub fn nativeStringRep(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 2) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const str_arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = str_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();

    const n_arg = vm.stack[vm.base + func_reg + 2];
    const n = n_arg.toInteger() orelse 0;

    if (n <= 0) {
        const result = try vm.gc.allocString("");
        vm.stack[vm.base + func_reg] = TValue.fromString(result);
        return;
    }

    // Get separator (optional, default empty)
    var sep: []const u8 = "";
    if (nargs > 2) {
        const sep_arg = vm.stack[vm.base + func_reg + 3];
        if (sep_arg.asString()) |s| {
            sep = s.asSlice();
        }
    }

    const count: usize = @intCast(n);

    // Calculate result size
    const result_len = str.len * count + sep.len * (count - 1);

    // Allocate buffer
    const buf = try vm.allocator.alloc(u8, result_len);
    defer vm.allocator.free(buf);

    // Build result
    var pos: usize = 0;
    for (0..count) |i| {
        if (i > 0 and sep.len > 0) {
            @memcpy(buf[pos..][0..sep.len], sep);
            pos += sep.len;
        }
        @memcpy(buf[pos..][0..str.len], str);
        pos += str.len;
    }

    const result = try vm.gc.allocString(buf);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}

/// string.reverse(s) - Returns string that is the reverse of s
pub fn nativeStringReverse(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();

    if (str.len == 0) {
        const result = try vm.gc.allocString("");
        vm.stack[vm.base + func_reg] = TValue.fromString(result);
        return;
    }

    // Allocate buffer for reversed string
    const buf = try vm.allocator.alloc(u8, str.len);
    defer vm.allocator.free(buf);

    for (str, 0..) |c, i| {
        buf[str.len - 1 - i] = c;
    }

    const result = try vm.gc.allocString(buf);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}

/// string.find(s, pattern [, init [, plain]]) - Looks for first match of pattern in string s
/// Returns start and end indices (1-based) or nil if not found
/// Currently only supports plain text search (no pattern matching)
pub fn nativeStringFind(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 2) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get string
    const str_arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = str_arg.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();

    // Get pattern
    const pattern_arg = vm.stack[vm.base + func_reg + 2];
    const pattern_obj = pattern_arg.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const pattern = pattern_obj.asSlice();

    // Get optional init position (default 1)
    var init: usize = 0;
    if (nargs >= 3) {
        const init_arg = vm.stack[vm.base + func_reg + 3];
        const i = init_arg.toInteger() orelse 1;
        if (i < 0) {
            // Negative index: count from end
            const abs_i: usize = @intCast(-i);
            if (abs_i <= str.len) {
                init = str.len - abs_i;
            }
        } else if (i > 0) {
            init = @intCast(i - 1); // Convert to 0-based
        }
    }

    // Clamp init to string length
    if (init > str.len) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Search for pattern (plain text search)
    if (std.mem.indexOf(u8, str[init..], pattern)) |pos| {
        const start: i64 = @intCast(init + pos + 1); // 1-based
        const end_pos: i64 = start + @as(i64, @intCast(pattern.len)) - 1;

        // Return start and end positions
        vm.stack[vm.base + func_reg] = .{ .integer = start };
        if (nresults > 1) {
            vm.stack[vm.base + func_reg + 1] = .{ .integer = end_pos };
        }
    } else {
        // Not found
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            vm.stack[vm.base + func_reg + 1] = .nil;
        }
    }
}

/// string.match(s, pattern [, init]) - Looks for first match of pattern in string s
/// Returns captured strings or whole match if no captures
/// Supports: literal chars, [set], [^set], ., %a, %d, %s, %w, *, +, ?, -, (), ^, $
pub fn nativeStringMatch(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 2) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get string
    const str_arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = str_arg.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();

    // Get pattern
    const pat_arg = vm.stack[vm.base + func_reg + 2];
    const pat_obj = pat_arg.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const pattern = pat_obj.asSlice();

    // Get init position (optional, 1-based)
    var init: usize = 0;
    if (nargs > 2) {
        const init_arg = vm.stack[vm.base + func_reg + 3];
        if (init_arg.toInteger()) |i| {
            if (i > 0) init = @intCast(i - 1);
        }
    }

    // Create pattern matcher
    var matcher = PatternMatcher.init(pattern, str, init);

    // Try to match at each position
    var match_start: usize = init;
    while (match_start <= str.len) : (match_start += 1) {
        matcher.reset(match_start);
        if (matcher.match()) {
            // Match found - return captures or whole match
            if (matcher.capture_count > 0) {
                // Return all captures (Lua returns all captures as multiple values)
                // Note: Multiple return values may not be fully supported by parser/VM yet
                var i: u32 = 0;
                while (i < matcher.capture_count) : (i += 1) {
                    const cap = matcher.captures[i];
                    const cap_str = try vm.gc.allocString(str[cap.start..cap.end]);
                    vm.stack[vm.base + func_reg + i] = TValue.fromString(cap_str);
                }
                return;
            } else {
                // Return whole match
                if (nresults > 0) {
                    const match_str = try vm.gc.allocString(str[matcher.match_start..matcher.match_end]);
                    vm.stack[vm.base + func_reg] = TValue.fromString(match_str);
                }
                return;
            }
        }

        // If pattern starts with ^, only try at start
        if (pattern.len > 0 and pattern[0] == '^') break;
    }

    // No match found
    if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
}

/// Lua pattern matcher
const PatternMatcher = struct {
    pattern: []const u8,
    str: []const u8,
    pat_pos: usize,
    str_pos: usize,
    match_start: usize,
    match_end: usize,
    captures: [32]Capture,
    capture_count: u32,
    capture_stack: [32]usize, // For tracking open captures
    capture_stack_top: u32,

    const Capture = struct {
        start: usize,
        end: usize,
    };

    fn init(pattern: []const u8, str: []const u8, start: usize) PatternMatcher {
        return .{
            .pattern = pattern,
            .str = str,
            .pat_pos = 0,
            .str_pos = start,
            .match_start = start,
            .match_end = start,
            .captures = undefined,
            .capture_count = 0,
            .capture_stack = undefined,
            .capture_stack_top = 0,
        };
    }

    fn reset(self: *PatternMatcher, start: usize) void {
        self.pat_pos = 0;
        self.str_pos = start;
        self.match_start = start;
        self.match_end = start;
        self.capture_count = 0;
        self.capture_stack_top = 0;
    }

    fn match(self: *PatternMatcher) bool {
        // Skip ^ anchor if present
        if (self.pat_pos < self.pattern.len and self.pattern[self.pat_pos] == '^') {
            self.pat_pos += 1;
        }

        return self.matchPattern();
    }

    fn matchPattern(self: *PatternMatcher) bool {
        while (self.pat_pos < self.pattern.len) {
            const c = self.pattern[self.pat_pos];

            // End anchor
            if (c == '$' and self.pat_pos + 1 == self.pattern.len) {
                self.match_end = self.str_pos;
                return self.str_pos == self.str.len;
            }

            // Capture start
            if (c == '(') {
                self.pat_pos += 1;
                if (self.capture_stack_top < 32) {
                    self.capture_stack[self.capture_stack_top] = self.str_pos;
                    self.capture_stack_top += 1;
                }
                continue;
            }

            // Capture end
            if (c == ')') {
                self.pat_pos += 1;
                if (self.capture_stack_top > 0 and self.capture_count < 32) {
                    self.capture_stack_top -= 1;
                    self.captures[self.capture_count] = .{
                        .start = self.capture_stack[self.capture_stack_top],
                        .end = self.str_pos,
                    };
                    self.capture_count += 1;
                }
                continue;
            }

            // Get pattern item (char class + optional quantifier)
            const item = self.getPatternItem();
            const quantifier = self.getQuantifier();

            // Match based on quantifier
            switch (quantifier) {
                .none => {
                    if (!self.matchItem(item)) return false;
                },
                .star => {
                    // Greedy: match as many as possible
                    const saved_str_pos = self.str_pos;
                    var count: usize = 0;
                    while (self.matchItem(item)) : (count += 1) {}
                    // Backtrack until rest of pattern matches
                    while (count > 0) : (count -= 1) {
                        const saved_pat = self.pat_pos;
                        if (self.matchPattern()) return true;
                        self.pat_pos = saved_pat;
                        self.str_pos -= 1;
                    }
                    self.str_pos = saved_str_pos;
                    // Try with zero matches
                    if (self.matchPattern()) return true;
                    return false;
                },
                .plus => {
                    // At least one match required
                    if (!self.matchItem(item)) return false;
                    // Then greedy like star
                    var count: usize = 1;
                    while (self.matchItem(item)) : (count += 1) {}
                    // Backtrack
                    while (count > 1) : (count -= 1) {
                        const saved_pat = self.pat_pos;
                        if (self.matchPattern()) return true;
                        self.pat_pos = saved_pat;
                        self.str_pos -= 1;
                    }
                    return self.matchPattern();
                },
                .question => {
                    // Try with one match first
                    if (self.matchItem(item)) {
                        const saved_pat = self.pat_pos;
                        const saved_str = self.str_pos;
                        if (self.matchPattern()) return true;
                        self.pat_pos = saved_pat;
                        self.str_pos = saved_str - 1;
                    }
                    return self.matchPattern();
                },
                .minus => {
                    // Non-greedy: try zero matches first
                    const saved_pat = self.pat_pos;
                    const saved_str = self.str_pos;
                    if (self.matchPattern()) return true;
                    self.pat_pos = saved_pat;
                    self.str_pos = saved_str;
                    // Then try one match and recurse
                    while (self.matchItem(item)) {
                        const sp = self.pat_pos;
                        if (self.matchPattern()) return true;
                        self.pat_pos = sp;
                    }
                    return false;
                },
            }
        }

        self.match_end = self.str_pos;
        return true;
    }

    const PatternItem = union(enum) {
        literal: u8,
        any, // .
        char_class: struct { pattern: []const u8, negated: bool },
        lua_class: u8, // %a, %d, etc.
        lua_class_neg: u8, // %A, %D, etc.
    };

    const Quantifier = enum { none, star, plus, question, minus };

    fn getPatternItem(self: *PatternMatcher) PatternItem {
        const c = self.pattern[self.pat_pos];
        self.pat_pos += 1;

        if (c == '.') {
            return .any;
        }

        if (c == '%' and self.pat_pos < self.pattern.len) {
            const next = self.pattern[self.pat_pos];
            self.pat_pos += 1;
            if (next >= 'A' and next <= 'Z') {
                return .{ .lua_class_neg = next };
            } else if (next >= 'a' and next <= 'z') {
                return .{ .lua_class = next };
            } else {
                // Escaped literal
                return .{ .literal = next };
            }
        }

        if (c == '[') {
            const start = self.pat_pos;
            var negated = false;
            if (self.pat_pos < self.pattern.len and self.pattern[self.pat_pos] == '^') {
                negated = true;
                self.pat_pos += 1;
            }
            // Find closing ]
            while (self.pat_pos < self.pattern.len and self.pattern[self.pat_pos] != ']') {
                if (self.pattern[self.pat_pos] == '%' and self.pat_pos + 1 < self.pattern.len) {
                    self.pat_pos += 2;
                } else {
                    self.pat_pos += 1;
                }
            }
            const class_end = self.pat_pos;
            if (self.pat_pos < self.pattern.len) self.pat_pos += 1; // Skip ]
            return .{ .char_class = .{
                .pattern = self.pattern[start..class_end],
                .negated = negated,
            } };
        }

        return .{ .literal = c };
    }

    fn getQuantifier(self: *PatternMatcher) Quantifier {
        if (self.pat_pos >= self.pattern.len) return .none;
        const c = self.pattern[self.pat_pos];
        switch (c) {
            '*' => {
                self.pat_pos += 1;
                return .star;
            },
            '+' => {
                self.pat_pos += 1;
                return .plus;
            },
            '?' => {
                self.pat_pos += 1;
                return .question;
            },
            '-' => {
                self.pat_pos += 1;
                return .minus;
            },
            else => return .none,
        }
    }

    fn matchItem(self: *PatternMatcher, item: PatternItem) bool {
        if (self.str_pos >= self.str.len) return false;
        const c = self.str[self.str_pos];

        const matches = switch (item) {
            .literal => |lit| c == lit,
            .any => true,
            .lua_class => |class| matchLuaClass(c, class),
            .lua_class_neg => |class| !matchLuaClass(c, std.ascii.toLower(class)),
            .char_class => |cc| blk: {
                const in_class = matchCharClass(c, cc.pattern);
                break :blk if (cc.negated) !in_class else in_class;
            },
        };

        if (matches) {
            self.str_pos += 1;
            return true;
        }
        return false;
    }

    fn matchLuaClass(c: u8, class: u8) bool {
        return switch (class) {
            'a' => std.ascii.isAlphabetic(c),
            'd' => std.ascii.isDigit(c),
            's' => std.ascii.isWhitespace(c),
            'w' => std.ascii.isAlphanumeric(c),
            'l' => std.ascii.isLower(c),
            'u' => std.ascii.isUpper(c),
            'p' => isPunctuation(c),
            'c' => std.ascii.isControl(c),
            'x' => std.ascii.isHex(c),
            'z' => c == 0,
            else => c == class, // Escaped literal
        };
    }

    fn isPunctuation(c: u8) bool {
        return (c >= '!' and c <= '/') or
            (c >= ':' and c <= '@') or
            (c >= '[' and c <= '`') or
            (c >= '{' and c <= '~');
    }

    fn matchCharClass(c: u8, pattern: []const u8) bool {
        var i: usize = 0;
        // Skip ^ if present (handled by caller)
        if (i < pattern.len and pattern[i] == '^') i += 1;

        while (i < pattern.len) {
            if (pattern[i] == '%' and i + 1 < pattern.len) {
                // Lua class in character class
                const class = pattern[i + 1];
                if (class >= 'a' and class <= 'z') {
                    if (matchLuaClass(c, class)) return true;
                } else if (class >= 'A' and class <= 'Z') {
                    if (!matchLuaClass(c, std.ascii.toLower(class))) return true;
                } else {
                    // Escaped literal
                    if (c == class) return true;
                }
                i += 2;
            } else if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                // Range: a-z
                if (c >= pattern[i] and c <= pattern[i + 2]) return true;
                i += 3;
            } else {
                // Literal
                if (c == pattern[i]) return true;
                i += 1;
            }
        }
        return false;
    }
};

/// string.gmatch(s, pattern) - Returns iterator for all matches of pattern in string s
/// Returns: iterator function, state table {s=string, p=pattern, pos=0}, nil
/// State table stores position internally, updated by iterator
pub fn nativeStringGmatch(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 2) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get string argument
    const str_arg = vm.stack[vm.base + func_reg + 1];
    if (str_arg.asString() == null) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get pattern argument
    const pat_arg = vm.stack[vm.base + func_reg + 2];
    if (pat_arg.asString() == null) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Create state table with string, pattern, and position
    const state_table = try vm.gc.allocTable();
    const key_s = try vm.gc.allocString("s");
    const key_p = try vm.gc.allocString("p");
    const key_pos = try vm.gc.allocString("pos");
    try state_table.set(key_s, str_arg);
    try state_table.set(key_p, pat_arg);
    try state_table.set(key_pos, .{ .integer = 0 });

    // Return iterator function
    const iter_nc = try vm.gc.allocNativeClosure(.{ .id = .string_gmatch_iterator });
    vm.stack[vm.base + func_reg] = TValue.fromNativeClosure(iter_nc);

    // Return state table (for-in will pass this to iterator)
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = TValue.fromTable(state_table);
    }

    // Return nil as initial control variable (we track position in state table)
    if (nresults > 2) {
        vm.stack[vm.base + func_reg + 2] = .nil;
    }
}

/// Iterator function for string.gmatch
/// Takes (state_table, _) where state_table has {s=string, p=pattern, pos=position}
/// Returns captures or whole match, then updates state_table.pos
/// Returns nil when no more matches
pub fn nativeStringGmatchIterator(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get state table
    const state_arg = vm.stack[vm.base + func_reg + 1];
    const state_table = state_arg.asTable() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Get string from state table
    const key_s = try vm.gc.allocString("s");
    const str_val = state_table.get(key_s) orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str_obj = str_val.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();

    // Get pattern from state table
    const key_p = try vm.gc.allocString("p");
    const pat_val = state_table.get(key_p) orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const pat_obj = pat_val.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const pattern = pat_obj.asSlice();

    // Get current position from state table
    const key_pos = try vm.gc.allocString("pos");
    const pos_val = state_table.get(key_pos) orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const pos_i64 = pos_val.toInteger() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    if (pos_i64 < 0) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }
    const start_pos: usize = @intCast(pos_i64);

    // Check if we're past the end
    if (start_pos > str.len) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Create pattern matcher and find next match
    var matcher = PatternMatcher.init(pattern, str, start_pos);

    var match_start: usize = start_pos;
    while (match_start <= str.len) : (match_start += 1) {
        matcher.reset(match_start);
        if (matcher.match()) {
            // Match found - calculate next position
            // For empty matches, advance by 1 to avoid infinite loop
            var next_pos = matcher.match_end;
            if (next_pos == match_start) {
                next_pos += 1;
            }

            // Update position in state table for next iteration
            try state_table.set(key_pos, .{ .integer = @as(i64, @intCast(next_pos)) });

            // Return captures or whole match
            if (matcher.capture_count > 0) {
                var i: u32 = 0;
                while (i < matcher.capture_count and i < nresults) : (i += 1) {
                    const cap = matcher.captures[i];
                    const cap_str = try vm.gc.allocString(str[cap.start..cap.end]);
                    vm.stack[vm.base + func_reg + i] = TValue.fromString(cap_str);
                }
            } else {
                // Return whole match
                const match_str = try vm.gc.allocString(str[matcher.match_start..matcher.match_end]);
                vm.stack[vm.base + func_reg] = TValue.fromString(match_str);
            }
            return;
        }

        // If pattern starts with ^, only try at start
        if (pattern.len > 0 and pattern[0] == '^') break;
    }

    // No more matches
    vm.stack[vm.base + func_reg] = .nil;
}

/// string.gsub(s, pattern, repl [, n]) - Returns copy of s with all/first n occurrences of pattern replaced by repl
/// repl can be: string (with %0-%9 for captures), table (lookup), or function (called with captures)
/// Returns: new string, number of substitutions made
pub fn nativeStringGsub(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 3) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get string
    const str_arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = str_arg.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();

    // Get pattern
    const pat_arg = vm.stack[vm.base + func_reg + 2];
    const pat_obj = pat_arg.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const pattern = pat_obj.asSlice();

    // Get replacement (string, table, or function)
    const repl_arg = vm.stack[vm.base + func_reg + 3];

    // Get max replacements (optional, default unlimited)
    var max_replacements: usize = std.math.maxInt(usize);
    if (nargs > 3) {
        const n_arg = vm.stack[vm.base + func_reg + 4];
        if (n_arg.toInteger()) |n| {
            if (n >= 0) max_replacements = @intCast(n);
        }
    }

    // Build result string
    const allocator = vm.allocator;
    var result = try std.ArrayList(u8).initCapacity(allocator, str.len);
    defer result.deinit(allocator);

    var pos: usize = 0;
    var replacement_count: i64 = 0;
    var matcher = PatternMatcher.init(pattern, str, 0);

    while (pos <= str.len and replacement_count < max_replacements) {
        matcher.reset(pos);

        if (matcher.match()) {
            // Append text before match
            try result.appendSlice(allocator, str[pos..matcher.match_start]);

            // Get replacement string based on repl type
            const replacement = try getGsubReplacement(
                vm,
                repl_arg,
                str,
                &matcher,
            );

            if (replacement) |repl_str| {
                try result.appendSlice(allocator, repl_str);
            } else {
                // If replacement is nil/false, keep original match
                try result.appendSlice(allocator, str[matcher.match_start..matcher.match_end]);
            }

            replacement_count += 1;

            // Move position forward
            if (matcher.match_end > pos) {
                pos = matcher.match_end;
            } else {
                // Empty match - advance by 1 to avoid infinite loop
                if (pos < str.len) {
                    try result.append(allocator, str[pos]);
                }
                pos += 1;
            }
        } else {
            // No match at this position
            if (pattern.len > 0 and pattern[0] == '^') {
                // Anchored pattern - no more matches possible
                break;
            }
            // Append current character and move forward
            if (pos < str.len) {
                try result.append(allocator, str[pos]);
            }
            pos += 1;
        }
    }

    // Append remaining text after last match
    if (pos < str.len) {
        try result.appendSlice(allocator, str[pos..]);
    }

    // Return result string
    const result_str = try vm.gc.allocString(result.items);
    vm.stack[vm.base + func_reg] = TValue.fromString(result_str);

    // Return replacement count as second value
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = .{ .integer = replacement_count };
    }
}

/// Get replacement string for gsub based on repl type
fn getGsubReplacement(
    vm: anytype,
    repl_arg: TValue,
    str: []const u8,
    matcher: *PatternMatcher,
) !?[]const u8 {
    // String replacement
    if (repl_arg.asString()) |repl_obj| {
        const repl = repl_obj.asSlice();
        return try expandGsubCaptures(vm, repl, str, matcher);
    }

    // Table replacement
    if (repl_arg.asTable()) |repl_table| {
        // Use first capture or whole match as key
        const key_str = if (matcher.capture_count > 0)
            str[matcher.captures[0].start..matcher.captures[0].end]
        else
            str[matcher.match_start..matcher.match_end];

        const key = try vm.gc.allocString(key_str);
        if (repl_table.get(key)) |val| {
            if (val.asString()) |s| {
                return s.asSlice();
            }
            // Convert to string if not nil/false
            if (!val.isNil() and !(val.isBoolean() and !val.boolean)) {
                // For simplicity, only handle string values
                // Full implementation would call tostring
                return null;
            }
        }
        return null;
    }

    // Function replacement
    if (repl_arg.asClosure() != null or repl_arg.asNativeClosure() != null) {
        // Build arguments: captures or whole match
        var args_buf: [32]TValue = undefined;
        var arg_count: usize = 0;

        if (matcher.capture_count > 0) {
            // Pass captures as arguments
            var i: u32 = 0;
            while (i < matcher.capture_count and i < 32) : (i += 1) {
                const cap = matcher.captures[i];
                const cap_str = try vm.gc.allocString(str[cap.start..cap.end]);
                args_buf[arg_count] = TValue.fromString(cap_str);
                arg_count += 1;
            }
        } else {
            // Pass whole match as argument
            const match_str = try vm.gc.allocString(str[matcher.match_start..matcher.match_end]);
            args_buf[0] = TValue.fromString(match_str);
            arg_count = 1;
        }

        // Call the function
        const result = call.callValue(vm, repl_arg, args_buf[0..arg_count]) catch |err| {
            // If not callable, treat as nil replacement (keep original)
            if (err == call.CallError.NotCallable) return null;
            return err;
        };

        // Process result according to Lua 5.4 semantics:
        // - nil/false: keep original match
        // - string: use as replacement
        // - number: convert to string
        if (result.isNil()) return null;
        if (result.isBoolean() and !result.boolean) return null;

        if (result.asString()) |s| {
            return s.asSlice();
        }

        // Convert number to string
        if (result.toNumber()) |num| {
            var buf: [64]u8 = undefined;
            const num_str = if (result.isInteger())
                std.fmt.bufPrint(&buf, "{d}", .{result.integer}) catch return null
            else
                std.fmt.bufPrint(&buf, "{d}", .{num}) catch return null;
            const str_obj = try vm.gc.allocString(num_str);
            return str_obj.asSlice();
        }

        // Other types: error (for now, return nil to keep original)
        return null;
    }

    return null;
}

/// Expand %0-%9 capture references in replacement string
fn expandGsubCaptures(
    vm: anytype,
    repl: []const u8,
    str: []const u8,
    matcher: *PatternMatcher,
) ![]const u8 {
    // Check if there are any % escapes
    var has_escapes = false;
    for (repl) |c| {
        if (c == '%') {
            has_escapes = true;
            break;
        }
    }
    if (!has_escapes) return repl;

    // Expand escapes
    const allocator = vm.allocator;
    var result = try std.ArrayList(u8).initCapacity(allocator, repl.len);
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < repl.len) {
        if (repl[i] == '%' and i + 1 < repl.len) {
            const next = repl[i + 1];
            if (next == '%') {
                // %% -> literal %
                try result.append(allocator, '%');
                i += 2;
            } else if (next >= '0' and next <= '9') {
                // %0-%9 -> capture reference
                const cap_idx = next - '0';
                if (cap_idx == 0) {
                    // %0 = whole match
                    try result.appendSlice(allocator, str[matcher.match_start..matcher.match_end]);
                } else if (cap_idx <= matcher.capture_count) {
                    // %1-%9 = capture
                    const cap = matcher.captures[cap_idx - 1];
                    try result.appendSlice(allocator, str[cap.start..cap.end]);
                }
                i += 2;
            } else {
                // Invalid escape - keep as is
                try result.append(allocator, repl[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, repl[i]);
            i += 1;
        }
    }

    // Allocate result as GC string and return slice
    const result_obj = try vm.gc.allocString(result.items);
    return result_obj.asSlice();
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
