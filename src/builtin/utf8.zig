const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");

const Decoded = struct {
    codepoint: u32,
    len: usize,
};

fn isContinuationByte(byte: u8) bool {
    return (byte & 0xC0) == 0x80;
}

fn relativeBytePos(pos: i64, len: usize) i64 {
    if (pos >= 0) return pos;
    return @as(i64, @intCast(len)) + pos + 1;
}

fn decodeAt(str: []const u8, pos: usize, lax: bool) !Decoded {
    const b0 = str[pos];
    var seq_len: usize = 0;
    var codepoint: u32 = 0;

    if (b0 <= 0x7F) {
        return .{ .codepoint = b0, .len = 1 };
    } else if (b0 >= 0xC2 and b0 <= 0xDF) {
        seq_len = 2;
        codepoint = b0 & 0x1F;
    } else if (b0 >= 0xE0 and b0 <= 0xEF) {
        seq_len = 3;
        codepoint = b0 & 0x0F;
    } else if (b0 >= 0xF0 and b0 <= 0xF7) {
        seq_len = 4;
        codepoint = b0 & 0x07;
    } else if (b0 >= 0xF8 and b0 <= 0xFB) {
        seq_len = 5;
        codepoint = b0 & 0x03;
    } else if (b0 >= 0xFC and b0 <= 0xFD) {
        seq_len = 6;
        codepoint = b0 & 0x01;
    } else {
        return error.InvalidUtf8;
    }

    if (pos + seq_len > str.len) return error.InvalidUtf8;

    var i: usize = 1;
    while (i < seq_len) : (i += 1) {
        const bx = str[pos + i];
        if (!isContinuationByte(bx)) return error.InvalidUtf8;
        codepoint = (codepoint << 6) | (bx & 0x3F);
    }

    const min_cp: u32 = switch (seq_len) {
        1 => 0,
        2 => 0x80,
        3 => 0x800,
        4 => 0x10000,
        5 => 0x200000,
        else => 0x4000000,
    };
    if (codepoint < min_cp) return error.InvalidUtf8;

    if (!lax) {
        if (codepoint > 0x10FFFF) return error.InvalidUtf8;
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return error.InvalidUtf8;
    }

    return .{ .codepoint = codepoint, .len = seq_len };
}

fn appendLuaUtf8(buf: []u8, pos: *usize, cp: i64) !void {
    if (cp < 0 or cp > 0x7FFFFFFF) {
        return error.OutOfRange;
    }

    const ucp: u32 = @intCast(cp);
    const len: usize = if (ucp <= 0x7F)
        1
    else if (ucp <= 0x7FF)
        2
    else if (ucp <= 0xFFFF)
        3
    else if (ucp <= 0x1FFFFF)
        4
    else if (ucp <= 0x3FFFFFF)
        5
    else
        6;

    if (pos.* + len > buf.len) return error.NoSpaceLeft;

    switch (len) {
        1 => {
            buf[pos.*] = @intCast(ucp);
        },
        2 => {
            buf[pos.*] = 0xC0 | @as(u8, @intCast((ucp >> 6) & 0x1F));
            buf[pos.* + 1] = 0x80 | @as(u8, @intCast(ucp & 0x3F));
        },
        3 => {
            buf[pos.*] = 0xE0 | @as(u8, @intCast((ucp >> 12) & 0x0F));
            buf[pos.* + 1] = 0x80 | @as(u8, @intCast((ucp >> 6) & 0x3F));
            buf[pos.* + 2] = 0x80 | @as(u8, @intCast(ucp & 0x3F));
        },
        4 => {
            buf[pos.*] = 0xF0 | @as(u8, @intCast((ucp >> 18) & 0x07));
            buf[pos.* + 1] = 0x80 | @as(u8, @intCast((ucp >> 12) & 0x3F));
            buf[pos.* + 2] = 0x80 | @as(u8, @intCast((ucp >> 6) & 0x3F));
            buf[pos.* + 3] = 0x80 | @as(u8, @intCast(ucp & 0x3F));
        },
        5 => {
            buf[pos.*] = 0xF8 | @as(u8, @intCast((ucp >> 24) & 0x03));
            buf[pos.* + 1] = 0x80 | @as(u8, @intCast((ucp >> 18) & 0x3F));
            buf[pos.* + 2] = 0x80 | @as(u8, @intCast((ucp >> 12) & 0x3F));
            buf[pos.* + 3] = 0x80 | @as(u8, @intCast((ucp >> 6) & 0x3F));
            buf[pos.* + 4] = 0x80 | @as(u8, @intCast(ucp & 0x3F));
        },
        else => {
            buf[pos.*] = 0xFC | @as(u8, @intCast((ucp >> 30) & 0x01));
            buf[pos.* + 1] = 0x80 | @as(u8, @intCast((ucp >> 24) & 0x3F));
            buf[pos.* + 2] = 0x80 | @as(u8, @intCast((ucp >> 18) & 0x3F));
            buf[pos.* + 3] = 0x80 | @as(u8, @intCast((ucp >> 12) & 0x3F));
            buf[pos.* + 4] = 0x80 | @as(u8, @intCast((ucp >> 6) & 0x3F));
            buf[pos.* + 5] = 0x80 | @as(u8, @intCast(ucp & 0x3F));
        },
    }
    pos.* += len;
}

/// Lua 5.4 UTF-8 Library
/// Corresponds to Lua manual chapter "UTF-8 Support"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.5
/// utf8.char(...) - Returns a string with UTF-8 encoding of given codepoints
/// Each argument is converted to an integer and encoded as UTF-8
pub fn nativeUtf8Char(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs == 0) {
        const empty = try vm.gc().allocString("");
        vm.stack[vm.base + func_reg] = TValue.fromString(empty);
        return;
    }

    const max_out_len = std.math.mul(usize, 6, nargs) catch {
        return vm.raiseString("UTF-8 string too large");
    };
    const buf = try vm.gc().allocator.alloc(u8, max_out_len);
    defer vm.gc().allocator.free(buf);
    var pos: usize = 0;

    var i: u32 = 0;
    while (i < nargs) : (i += 1) {
        const arg = vm.stack[vm.base + func_reg + 1 + i];
        const codepoint_i64 = arg.toInteger() orelse {
            if (arg.toNumber() != null) return vm.raiseString("number has no integer representation");
            return vm.raiseString("number expected");
        };

        appendLuaUtf8(buf, &pos, codepoint_i64) catch |err| switch (err) {
            error.OutOfRange => return vm.raiseString("value out of range"),
            else => return vm.raiseString("UTF-8 string too large"),
        };
    }

    const result = try vm.gc().allocString(buf[0..pos]);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}

/// utf8.codes(s) - Returns iterator for UTF-8 codepoints in string
/// Returns: iterator function, string s, 0
/// Iterator returns: byte_position, codepoint (or nil when done)
pub fn nativeUtf8Codes(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        return vm.raiseString("string expected");
    }

    const str_arg = vm.stack[vm.base + func_reg + 1];
    if (str_arg.asString() == null) {
        return vm.raiseString("string expected");
    }

    const lax = if (nargs >= 2) vm.stack[vm.base + func_reg + 2].toBoolean() else false;

    // Return iterator function
    const iter_nc = try vm.gc().allocNativeClosure(.{ .id = .utf8_codes_iterator });
    vm.stack[vm.base + func_reg] = TValue.fromNativeClosure(iter_nc);

    // In lax mode pass iterator state table { s = string, lax = true }.
    if (nresults > 1) {
        if (lax) {
            const state = try vm.gc().allocTable();
            const key_s = try vm.gc().allocString("s");
            const key_lax = try vm.gc().allocString("lax");
            try object.tableSetWithBarrier(vm.gc(), state, TValue.fromString(key_s), str_arg);
            try object.tableSetWithBarrier(vm.gc(), state, TValue.fromString(key_lax), .{ .boolean = true });
            vm.stack[vm.base + func_reg + 1] = TValue.fromTable(state);
        } else {
            vm.stack[vm.base + func_reg + 1] = str_arg;
        }
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
        return vm.raiseString("string expected");
    }

    const state_arg = vm.stack[vm.base + func_reg + 1];
    const pos_arg = vm.stack[vm.base + func_reg + 2];

    var lax = false;
    var str_obj: ?*object.StringObject = state_arg.asString();
    if (str_obj == null) {
        if (state_arg.asTable()) |state_tbl| {
            const key_s = try vm.gc().allocString("s");
            const key_lax = try vm.gc().allocString("lax");
            if (state_tbl.get(TValue.fromString(key_s))) |s_val| {
                str_obj = s_val.asString();
            }
            if (state_tbl.get(TValue.fromString(key_lax))) |lax_val| {
                lax = lax_val.toBoolean();
            }
        }
    }
    const str_ref = str_obj orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const str = str_ref.asSlice();

    const pos_i64 = pos_arg.toInteger() orelse {
        if (pos_arg.toNumber() != null) return vm.raiseString("number has no integer representation");
        return vm.raiseString("number expected");
    };

    if (pos_i64 < 0) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const pos: usize = @intCast(pos_i64);
    var next_pos: usize = 0;
    if (pos == 0) {
        next_pos = 0;
    } else {
        const prev_start = pos - 1;
        if (prev_start >= str.len) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }
        const prev_decoded = decodeAt(str, prev_start, lax) catch {
            return vm.raiseString("invalid UTF-8 code");
        };
        next_pos = prev_start + prev_decoded.len;
    }

    if (next_pos >= str.len) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const decoded = decodeAt(str, next_pos, lax) catch {
        return vm.raiseString("invalid UTF-8 code");
    };

    vm.stack[vm.base + func_reg] = .{ .integer = @as(i64, @intCast(next_pos + 1)) };
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = .{ .integer = @intCast(decoded.codepoint) };
    }
}

/// utf8.codepoint(s [, i [, j]]) - Returns codepoints in given range
/// i and j are byte positions (1-based), returns codepoints as integers
pub fn nativeUtf8Codepoint(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        return vm.raiseString("string expected");
    }

    const str_arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = str_arg.asString() orelse {
        return vm.raiseString("string expected");
    };
    const str = str_obj.asSlice();
    const lax = if (nargs >= 4) vm.stack[vm.base + func_reg + 4].toBoolean() else false;

    const len = str.len;
    const i_raw = if (nargs >= 2) blk: {
        const i_arg = vm.stack[vm.base + func_reg + 2];
        break :blk i_arg.toInteger() orelse {
            if (i_arg.toNumber() != null) return vm.raiseString("number has no integer representation");
            return vm.raiseString("number expected");
        };
    } else 1;

    const j_raw = if (nargs >= 3) blk: {
        const j_arg = vm.stack[vm.base + func_reg + 3];
        break :blk j_arg.toInteger() orelse {
            if (j_arg.toNumber() != null) return vm.raiseString("number has no integer representation");
            return vm.raiseString("number expected");
        };
    } else i_raw;

    const i_abs = relativeBytePos(i_raw, len);
    if (i_abs < 1) return vm.raiseString("out of bounds");
    const j_abs = relativeBytePos(j_raw, len);
    if (i_abs > @as(i64, @intCast(len + 1)) or j_abs < 0 or j_abs > @as(i64, @intCast(len))) {
        return vm.raiseString("out of bounds");
    }

    if (j_abs < i_abs) {
        vm.top = vm.base + func_reg;
        return;
    }

    if (i_abs > @as(i64, @intCast(len))) {
        return vm.raiseString("out of bounds");
    }

    var pos: usize = @intCast(i_abs - 1);
    const end_pos: usize = @intCast(j_abs - 1);
    var written: u32 = 0;
    const result_cap: u32 = if (nresults == 0) std.math.maxInt(u32) else nresults;

    while (pos <= end_pos) {
        const decoded = decodeAt(str, pos, lax) catch {
            return vm.raiseString("invalid UTF-8 code");
        };
        if (written < result_cap and (vm.base + func_reg + written) < vm.stack.len) {
            vm.stack[vm.base + func_reg + written] = .{ .integer = @intCast(decoded.codepoint) };
            written += 1;
        }
        pos += decoded.len;
    }

    if (nresults > 0) {
        while (written < nresults) : (written += 1) {
            vm.stack[vm.base + func_reg + written] = .nil;
        }
    }
    vm.top = vm.base + func_reg + written;
}

/// utf8.len(s [, i [, j]]) - Returns number of UTF-8 characters in string
/// Returns nil and position of invalid byte if string is not valid UTF-8
pub fn nativeUtf8Len(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        return vm.raiseString("string expected");
    }

    const str_arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = str_arg.asString() orelse {
        return vm.raiseString("string expected");
    };
    const str = str_obj.asSlice();
    const len = str.len;
    const lax = if (nargs >= 4) vm.stack[vm.base + func_reg + 4].toBoolean() else false;

    const i_raw = if (nargs >= 2) blk: {
        const i_arg = vm.stack[vm.base + func_reg + 2];
        break :blk i_arg.toInteger() orelse {
            if (i_arg.toNumber() != null) return vm.raiseString("number has no integer representation");
            return vm.raiseString("number expected");
        };
    } else 1;
    const j_raw = if (nargs >= 3) blk: {
        const j_arg = vm.stack[vm.base + func_reg + 3];
        break :blk j_arg.toInteger() orelse {
            if (j_arg.toNumber() != null) return vm.raiseString("number has no integer representation");
            return vm.raiseString("number expected");
        };
    } else -1;

    const i_abs = relativeBytePos(i_raw, len);
    if (i_abs < 1 or i_abs > @as(i64, @intCast(len + 1))) {
        return vm.raiseString("out of bounds");
    }

    const j_abs = relativeBytePos(j_raw, len);
    if (j_abs < 0 or j_abs > @as(i64, @intCast(len))) {
        return vm.raiseString("out of bounds");
    }

    if (i_abs > j_abs) {
        vm.stack[vm.base + func_reg] = .{ .integer = 0 };
        return;
    }

    var pos: usize = @intCast(i_abs - 1);
    const end_byte_1based: i64 = j_abs;

    if (pos < len and isContinuationByte(str[pos])) {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) vm.stack[vm.base + func_reg + 1] = .{ .integer = @as(i64, @intCast(pos + 1)) };
        return;
    }

    var count: i64 = 0;
    while (pos < len and @as(i64, @intCast(pos + 1)) <= end_byte_1based) {
        const decoded = decodeAt(str, pos, lax) catch {
            vm.stack[vm.base + func_reg] = .nil;
            if (nresults >= 2) vm.stack[vm.base + func_reg + 1] = .{ .integer = @as(i64, @intCast(pos + 1)) };
            return;
        };
        count += 1;
        pos += decoded.len;
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
        return vm.raiseString("string expected");
    }

    const str_arg = vm.stack[vm.base + func_reg + 1];
    const str_obj = str_arg.asString() orelse {
        return vm.raiseString("string expected");
    };
    const str = str_obj.asSlice();
    const len = str.len;

    const n_arg = vm.stack[vm.base + func_reg + 2];
    const n = n_arg.toInteger() orelse {
        if (n_arg.toNumber() != null) return vm.raiseString("number has no integer representation");
        return vm.raiseString("number expected");
    };

    var i_abs: i64 = if (n >= 0) 1 else @as(i64, @intCast(len)) + 1;
    if (nargs >= 3) {
        const i_arg = vm.stack[vm.base + func_reg + 3];
        const i_raw = i_arg.toInteger() orelse {
            if (i_arg.toNumber() != null) return vm.raiseString("number has no integer representation");
            return vm.raiseString("number expected");
        };
        i_abs = relativeBytePos(i_raw, len);
    }

    if (i_abs < 1 or i_abs > @as(i64, @intCast(len + 1))) {
        return vm.raiseString("position out of bounds");
    }

    var pos: usize = @intCast(i_abs - 1);

    if (n == 0) {
        while (pos > 0 and pos < len and isContinuationByte(str[pos])) {
            pos -= 1;
        }
        vm.stack[vm.base + func_reg] = .{ .integer = @as(i64, @intCast(pos + 1)) };
        return;
    }

    if (pos < len and isContinuationByte(str[pos])) {
        return vm.raiseString("initial position is a continuation byte");
    }

    if (n < 0) {
        var rem = -n;
        while (rem > 0) {
            if (pos == 0) {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            }
            pos -= 1;
            while (pos > 0 and isContinuationByte(str[pos])) {
                pos -= 1;
            }
            rem -= 1;
        }
        vm.stack[vm.base + func_reg] = .{ .integer = @as(i64, @intCast(pos + 1)) };
        return;
    }

    var rem = n - 1;
    while (rem > 0) {
        if (pos >= len) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }
        pos += 1;
        while (pos < len and isContinuationByte(str[pos])) {
            pos += 1;
        }
        rem -= 1;
    }
    vm.stack[vm.base + func_reg] = .{ .integer = @as(i64, @intCast(pos + 1)) };
}

/// utf8.charpattern - Pattern that matches exactly one UTF-8 character
pub const UTF8_CHARPATTERN: []const u8 = "[\x00-\x7F\xC2-\xFD][\x80-\xBF]*";
