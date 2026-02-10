const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Lua 5.4 UTF-8 Library
/// Corresponds to Lua manual chapter "UTF-8 Support"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.5
/// utf8.char(...) - Returns a string with UTF-8 encoding of given codepoints
/// Each argument is converted to an integer and encoded as UTF-8
pub fn nativeUtf8Char(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs == 0) {
        const empty = try vm.gc.allocString("");
        vm.stack[vm.base + func_reg] = TValue.fromString(empty);
        return;
    }

    // Build UTF-8 string from codepoints
    var buf: [256]u8 = undefined;
    var pos: usize = 0;

    var i: u32 = 0;
    while (i < nargs) : (i += 1) {
        const arg = vm.stack[vm.base + func_reg + 1 + i];
        const codepoint_i64 = arg.toInteger() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };

        // Validate codepoint range (0 to 0x10FFFF)
        if (codepoint_i64 < 0 or codepoint_i64 > 0x10FFFF) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        const codepoint: u21 = @intCast(codepoint_i64);

        // Encode to UTF-8
        const len = std.unicode.utf8CodepointSequenceLength(codepoint) catch {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };

        if (pos + len > buf.len) {
            // Buffer overflow - need larger buffer for many codepoints
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        _ = std.unicode.utf8Encode(codepoint, buf[pos..]) catch {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        pos += len;
    }

    const result = try vm.gc.allocString(buf[0..pos]);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}

/// utf8.codes(s) - Returns iterator for UTF-8 codepoints in string
/// Returns: iterator function, string s, 0
/// Iterator returns: byte_position, codepoint (or nil when done)
pub fn nativeUtf8Codes(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const str_arg = vm.stack[vm.base + func_reg + 1];
    if (str_arg.asString() == null) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Return iterator function
    const iter_nc = try vm.gc.allocNativeClosure(.{ .id = .utf8_codes_iterator });
    vm.stack[vm.base + func_reg] = TValue.fromNativeClosure(iter_nc);

    // Return the string
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = str_arg;
    }

    // Return 0 as initial byte position
    if (nresults > 2) {
        vm.stack[vm.base + func_reg + 2] = .{ .integer = 0 };
    }
}

/// Iterator function for utf8.codes
/// Takes (s, pos) where pos is byte position (0-based internally)
/// Returns (new_pos, codepoint) or nil when done
pub fn nativeUtf8CodesIterator(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 2) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const str_arg = vm.stack[vm.base + func_reg + 1];
    const pos_arg = vm.stack[vm.base + func_reg + 2];

    const str_obj = str_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();

    const pos_i64 = pos_arg.toInteger() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    if (pos_i64 < 0) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const pos: usize = @intCast(pos_i64);

    // Check if we're at the end
    if (pos >= str.len) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Decode the codepoint at current position
    const byte = str[pos];
    const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
        // Invalid UTF-8 - error
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    if (pos + seq_len > str.len) {
        // Incomplete sequence
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const codepoint = std.unicode.utf8Decode(str[pos..][0..seq_len]) catch {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Return (position+1 for 1-based Lua index, codepoint)
    vm.stack[vm.base + func_reg] = .{ .integer = @as(i64, @intCast(pos + 1)) };
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = .{ .integer = @intCast(codepoint) };
    }
}

/// utf8.codepoint(s [, i [, j]]) - Returns codepoints in given range
/// i and j are byte positions (1-based), returns codepoints as integers
pub fn nativeUtf8Codepoint(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const str_arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = str_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();

    if (str.len == 0) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get start byte position (1-based, default 1)
    var start: usize = 0;
    if (nargs >= 2) {
        const i_arg = vm.stack[vm.base + func_reg + 2];
        if (i_arg.toInteger()) |i| {
            if (i < 1) {
                start = 0;
            } else {
                start = @intCast(i - 1);
            }
        }
    }

    // Get end byte position (1-based, default i)
    var end: usize = start + 1;
    if (nargs >= 3) {
        const j_arg = vm.stack[vm.base + func_reg + 3];
        if (j_arg.toInteger()) |j| {
            if (j < 0) {
                const abs_j: usize = @intCast(-j);
                if (abs_j > str.len) {
                    end = 0;
                } else {
                    end = str.len - abs_j + 1;
                }
            } else {
                end = @intCast(j);
            }
        }
    } else {
        // Default: j = i (return single codepoint starting at position i)
        end = str.len; // Will read one codepoint from start
    }

    if (start >= str.len) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Decode and return codepoints
    var pos: usize = start;
    var result_idx: u32 = 0;

    while (pos < str.len and pos < end and result_idx < nresults) {
        const byte = str[pos];
        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };

        if (pos + seq_len > str.len) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        const codepoint = std.unicode.utf8Decode(str[pos..][0..seq_len]) catch {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };

        vm.stack[vm.base + func_reg + result_idx] = .{ .integer = @intCast(codepoint) };
        result_idx += 1;
        pos += seq_len;

        // If j was not specified, return only one codepoint
        if (nargs < 3) break;
    }

    // Fill remaining results with nil if needed
    while (result_idx < nresults) : (result_idx += 1) {
        vm.stack[vm.base + func_reg + result_idx] = .nil;
    }
}

/// utf8.len(s [, i [, j]]) - Returns number of UTF-8 characters in string
/// Returns nil and position of invalid byte if string is not valid UTF-8
pub fn nativeUtf8Len(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const str_arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = str_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_obj.asSlice();

    // Get optional start position (1-based, default 1)
    var start: usize = 0;
    if (nargs >= 2) {
        const i_arg = vm.stack[vm.base + func_reg + 2];
        if (i_arg.toInteger()) |i| {
            if (i < 1) {
                start = 0;
            } else {
                start = @intCast(i - 1);
            }
        }
    }

    // Get optional end position (1-based, default #s)
    var end: usize = str.len;
    if (nargs >= 3) {
        const j_arg = vm.stack[vm.base + func_reg + 3];
        if (j_arg.toInteger()) |j| {
            if (j < 0) {
                // Negative index from end
                const abs_j: usize = @intCast(-j);
                if (abs_j > str.len) {
                    end = 0;
                } else {
                    end = str.len - abs_j + 1;
                }
            } else {
                end = @min(@as(usize, @intCast(j)), str.len);
            }
        }
    }

    if (start >= str.len or start >= end) {
        vm.stack[vm.base + func_reg] = .{ .integer = 0 };
        return;
    }

    // Count UTF-8 characters
    const slice = str[start..end];
    var count: i64 = 0;
    var pos: usize = 0;

    while (pos < slice.len) {
        const byte = slice[pos];
        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            // Invalid UTF-8 - return nil and position of bad byte
            vm.stack[vm.base + func_reg] = .nil;
            if (nresults >= 2) {
                vm.stack[vm.base + func_reg + 1] = .{ .integer = @as(i64, @intCast(start + pos + 1)) };
            }
            return;
        };

        if (pos + seq_len > slice.len) {
            // Incomplete sequence at end
            vm.stack[vm.base + func_reg] = .nil;
            if (nresults >= 2) {
                vm.stack[vm.base + func_reg + 1] = .{ .integer = @as(i64, @intCast(start + pos + 1)) };
            }
            return;
        }

        // Validate the full sequence
        _ = std.unicode.utf8Decode(slice[pos..][0..seq_len]) catch {
            vm.stack[vm.base + func_reg] = .nil;
            if (nresults >= 2) {
                vm.stack[vm.base + func_reg + 1] = .{ .integer = @as(i64, @intCast(start + pos + 1)) };
            }
            return;
        };

        count += 1;
        pos += seq_len;
    }

    vm.stack[vm.base + func_reg] = .{ .integer = count };
}

/// utf8.offset(s, n [, i]) - Returns byte position of n-th character
/// n=0 returns position of start of character containing byte i
/// n>0 returns position of n-th character counting from position i
/// n<0 returns position of |n|-th character before position i
pub fn nativeUtf8Offset(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
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
    const n = n_arg.toInteger() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Get starting position (1-based, default 1 for n>=0, #s+1 for n<0)
    var start_1based: i64 = if (n >= 0) 1 else @as(i64, @intCast(str.len)) + 1;
    if (nargs >= 3) {
        const i_arg = vm.stack[vm.base + func_reg + 3];
        if (i_arg.toInteger()) |i| {
            start_1based = i;
        }
    }

    // Handle negative start position (from end)
    var pos: usize = undefined;
    if (start_1based < 0) {
        const abs_i: usize = @intCast(-start_1based);
        if (abs_i > str.len) {
            pos = 0;
        } else {
            pos = str.len - abs_i;
        }
    } else if (start_1based == 0) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    } else {
        pos = @intCast(start_1based - 1);
    }

    if (n == 0) {
        // Find start of character containing byte at position i
        if (pos >= str.len) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        // Move back to start of UTF-8 sequence
        while (pos > 0 and (str[pos] & 0xC0) == 0x80) {
            pos -= 1;
        }

        vm.stack[vm.base + func_reg] = .{ .integer = @as(i64, @intCast(pos + 1)) };
        return;
    }

    if (n > 0) {
        // n-th character counting from position i
        // n=1 means the first character at or after position i
        if (pos >= str.len) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        // First, find the start of the character at position pos
        while (pos > 0 and (str[pos] & 0xC0) == 0x80) {
            pos -= 1;
        }

        // Now move forward n-1 characters (since we're already at the 1st)
        var count: i64 = n - 1;
        while (count > 0) {
            // Move to next character
            const byte = str[pos];
            const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            };
            pos += seq_len;
            if (pos >= str.len) {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            }
            count -= 1;
        }

        vm.stack[vm.base + func_reg] = .{ .integer = @as(i64, @intCast(pos + 1)) };
    } else {
        // n < 0: Move backward |n| characters from position i
        var count: i64 = -n;

        while (count > 0) {
            if (pos == 0) {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            }
            pos -= 1;
            // Skip continuation bytes
            while (pos > 0 and (str[pos] & 0xC0) == 0x80) {
                pos -= 1;
            }
            // Handle case where we're at position 0 but it's a continuation byte
            if (pos == 0 and (str[pos] & 0xC0) == 0x80) {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            }
            count -= 1;
        }

        vm.stack[vm.base + func_reg] = .{ .integer = @as(i64, @intCast(pos + 1)) };
    }
}

/// utf8.charpattern - Pattern that matches exactly one UTF-8 character
pub const UTF8_CHARPATTERN: []const u8 = "[\x00-\x7F\xC2-\xF4][\x80-\xBF]*";
