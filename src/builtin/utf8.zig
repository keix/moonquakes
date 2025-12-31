const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Lua 5.4 UTF-8 Library
/// Corresponds to Lua manual chapter "UTF-8 Support"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.5
/// utf8.char(...) - Returns a string with UTF-8 encoding of given codepoints
pub fn nativeUtf8Char(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement utf8.char
}

/// utf8.codes(s) - Returns iterator for UTF-8 codepoints in string
pub fn nativeUtf8Codes(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement utf8.codes
}

/// utf8.codepoint(s [, i [, j]]) - Returns codepoints in given range
pub fn nativeUtf8Codepoint(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement utf8.codepoint
}

/// utf8.len(s [, i [, j]]) - Returns number of UTF-8 characters in string
pub fn nativeUtf8Len(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement utf8.len
}

/// utf8.offset(s, n [, i]) - Returns byte offset of n-th character
pub fn nativeUtf8Offset(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement utf8.offset
}

/// utf8.charpattern - Pattern that matches exactly one UTF-8 character
pub const UTF8_CHARPATTERN: []const u8 = "[\x00-\x7F\xC2-\xF4][\x80-\xBF]*";
