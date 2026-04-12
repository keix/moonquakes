const std = @import("std");

pub const NativeCallMultret = enum(u8) {
    fixed_default_one,
    fixed_exact_two,
    top_defined,
};

pub const NativeMetamethodMultret = enum(u8) {
    fixed_default_one,
    top_defined,
    capped_to_stack,
};

pub const NativeResultAbi = struct {
    call_multret: NativeCallMultret = .fixed_default_one,
    metamethod_multret: NativeMetamethodMultret = .fixed_default_one,
};

pub const NativeFnId = enum(u8) {
    // Global Functions (builtin/global.zig)
    print, // Keep first for parser compatibility
    tostring,
    assert,
    collectgarbage,
    lua_error, // 'error' is reserved keyword, use lua_error

    // Additional Global Functions (builtin/global.zig) - skeleton functions
    lua_type, // 'type' is reserved keyword, use lua_type
    pcall,
    xpcall,
    next,
    pairs,
    ipairs,
    ipairs_iterator,
    getmetatable,
    setmetatable,
    rawget,
    rawset,
    rawlen,
    rawequal,
    select,
    tonumber,
    load,
    loadfile,
    dofile,
    warn,
    lua_G, // '_G' starts with underscore, use lua_G
    lua_VERSION, // '_VERSION' starts with underscore, use lua_VERSION

    // Coroutine Library (builtin/coroutine.zig) - skeleton functions
    coroutine_create,
    coroutine_resume,
    coroutine_running,
    coroutine_status,
    coroutine_wrap,
    coroutine_wrap_call, // Internal: __call handler for wrapped coroutine
    coroutine_yield,
    coroutine_isyieldable,
    coroutine_close,

    // Module System (builtin/modules.zig) - skeleton functions
    require,
    package_loadlib,
    package_searchpath,

    // String Library (builtin/string.zig) - skeleton functions
    string_len,
    string_sub,
    string_upper,
    string_lower,
    string_byte,
    string_char,
    string_rep,
    string_reverse,
    string_find,
    string_match,
    string_gmatch,
    string_gmatch_iterator,
    string_gsub,
    string_format,
    string_dump,
    string_pack,
    string_unpack,
    string_packsize,

    // UTF8 Library (builtin/utf8.zig)
    utf8_char,
    utf8_codes,
    utf8_codes_iterator,
    utf8_codepoint,
    utf8_len,
    utf8_offset,

    // Table Library (builtin/table.zig) - skeleton functions
    table_insert,
    table_remove,
    table_sort,
    table_concat,
    table_move,
    table_pack,
    table_unpack,

    // Math Library (builtin/math.zig) - skeleton functions
    math_abs,
    math_acos,
    math_asin,
    math_atan,
    math_ceil,
    math_cos,
    math_deg,
    math_exp,
    math_floor,
    math_fmod,
    math_log,
    math_max,
    math_min,
    math_modf,
    math_rad,
    math_random,
    math_randomseed,
    math_sin,
    math_sqrt,
    math_tan,
    math_tointeger,
    math_type,
    math_ult,

    // IO Library (builtin/io.zig) - skeleton functions
    io_write,
    io_close,
    io_flush,
    io_input,
    io_lines,
    io_lines_iterator,
    io_lines_unreadable_iterator,
    io_open,
    io_output,
    io_popen,
    io_read,
    io_tmpfile,
    io_type,

    // File handle methods (future userdata implementation)
    file_close,
    file_flush,
    file_lines,
    file_read,
    file_seek,
    file_setvbuf,
    file_write,

    // OS Library (builtin/os.zig) - skeleton functions
    os_clock,
    os_date,
    os_difftime,
    os_execute,
    os_exit,
    os_getenv,
    os_remove,
    os_rename,
    os_setlocale,
    os_time,
    os_tmpname,

    // Debug Library (builtin/debug.zig) - skeleton functions
    debug_debug,
    debug_gethook,
    debug_getinfo,
    debug_getlocal,
    debug_getmetatable,
    debug_getregistry,
    debug_getupvalue,
    debug_getuservalue,
    debug_newuserdata,
    debug_sethook,
    debug_setlocal,
    debug_setmetatable,
    debug_setupvalue,
    debug_setuservalue,
    debug_traceback,
    debug_upvalueid,
    debug_upvaluejoin,

    pub fn resultAbi(self: NativeFnId) NativeResultAbi {
        return switch (self) {
            .table_unpack,
            .string_byte,
            .string_match,
            .utf8_codepoint,
            .select,
            .debug_getlocal,
            .debug_getupvalue,
            .debug_gethook,
            .pcall,
            .xpcall,
            .coroutine_yield,
            .coroutine_resume,
            => .{ .call_multret = .top_defined },

            .string_gsub,
            .require,
            .next,
            .load,
            .loadfile,
            => .{ .call_multret = .fixed_exact_two },

            .coroutine_wrap_call => .{ .metamethod_multret = .top_defined },
            .io_lines_iterator => .{ .metamethod_multret = .capped_to_stack },

            else => .{},
        };
    }

    pub fn desiredResultsForCall(self: NativeFnId, c: u8) u32 {
        if (c > 0) return c - 1;

        return switch (self.resultAbi().call_multret) {
            .fixed_default_one => 1,
            .fixed_exact_two => 2,
            .top_defined => 0,
        };
    }

    pub fn desiredResultsForMetamethod(self: NativeFnId, nresults: i16, stack_room: u32) u32 {
        if (nresults >= 0) return @intCast(nresults);

        return switch (self.resultAbi().metamethod_multret) {
            .fixed_default_one => 1,
            .top_defined => 0,
            .capped_to_stack => @min(@as(u32, 256), stack_room),
        };
    }

    pub fn keepsTopForMetamethod(self: NativeFnId, nresults: i16) bool {
        return nresults < 0 and self.resultAbi().metamethod_multret == .top_defined;
    }
};

pub const NativeFn = struct {
    id: NativeFnId,

    pub fn init(id: NativeFnId) NativeFn {
        return NativeFn{ .id = id };
    }
};
