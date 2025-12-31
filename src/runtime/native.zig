const std = @import("std");

pub const NativeFnId = enum(u8) {
    // Global Functions (builtin/global.zig)
    print, // Keep first for parser compatibility
    tostring,
    assert,
    collectgarbage,
    lua_error, // 'error' is reserved keyword, use lua_error

    // IO Library (builtin/io.zig)
    io_write,

    // Math Library (builtin/math.zig) - skeleton functions
    math_abs,
    math_ceil,
    math_floor,
    math_max,
    math_min,
    math_sqrt,

    // Table Library (builtin/table.zig) - skeleton functions
    table_insert,
    table_remove,
    table_sort,
    table_concat,
    table_move,
    table_pack,
    table_unpack,

    // UTF8 Library (builtin/utf8.zig) - skeleton functions
    utf8_char,
    utf8_codes,
    utf8_codepoint,
    utf8_len,
    utf8_offset,
};

pub const NativeFn = struct {
    id: NativeFnId,

    pub fn init(id: NativeFnId) NativeFn {
        return NativeFn{ .id = id };
    }
};
