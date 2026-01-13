const std = @import("std");
const Table = @import("../runtime/table.zig").Table;
const Function = @import("../runtime/function.zig").Function;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const TValue = @import("../runtime/value.zig").TValue;
const GC = @import("../runtime/gc/gc.zig").GC;

// Builtin library modules - organized by Lua manual chapters
const string = @import("string.zig");
const io = @import("io.zig");
const global = @import("global.zig");
const error_handling = @import("error.zig");
const math = @import("math.zig");
const table = @import("table.zig");
const os = @import("os.zig");
const debug = @import("debug.zig");
const utf8 = @import("utf8.zig");
const coroutine = @import("coroutine.zig");
const modules = @import("modules.zig");

/// Initialize the global environment with all Lua standard libraries
/// Organized by Lua manual chapters for maintainability
pub fn initGlobalEnvironment(globals: *Table, gc: *GC) !void {
    const allocator = gc.allocator;

    // Global Functions (Chapter 6.1)
    try initGlobalFunctions(globals);

    // Module System (Chapter 6.3) - skeleton
    try initModuleSystem(globals, gc);

    // String Library (Chapter 6.4) - skeleton
    try initStringLibrary(globals, allocator);

    // IO Library (Chapter 6.8)
    try initIOLibrary(globals, allocator);

    // Math Library (Chapter 6.7) - skeleton
    try initMathLibrary(globals, allocator);

    // Table Library (Chapter 6.6) - skeleton
    try initTableLibrary(globals, allocator);

    // OS Library (Chapter 6.9) - skeleton
    try initOSLibrary(globals, allocator);

    // Debug Library (Chapter 6.10) - skeleton
    try initDebugLibrary(globals, allocator);

    // UTF-8 Support (Chapter 6.5) - skeleton
    try initUtf8Library(globals, gc);

    // Coroutine Library (Chapter 2.6) - skeleton
    try initCoroutineLibrary(globals, allocator);
}

/// Global Functions: print, assert, error, type, tostring, collectgarbage, etc.
fn initGlobalFunctions(globals: *Table) !void {
    // Core functions (implemented)
    const print_fn = Function{ .native = .{ .id = NativeFnId.print } };
    try globals.set("print", .{ .function = print_fn });

    const tostring_fn = Function{ .native = .{ .id = NativeFnId.tostring } };
    try globals.set("tostring", .{ .function = tostring_fn });

    const assert_fn = Function{ .native = .{ .id = NativeFnId.assert } };
    try globals.set("assert", .{ .function = assert_fn });

    const error_fn = Function{ .native = .{ .id = NativeFnId.lua_error } };
    try globals.set("error", .{ .function = error_fn });

    const collectgarbage_fn = Function{ .native = .{ .id = NativeFnId.collectgarbage } };
    try globals.set("collectgarbage", .{ .function = collectgarbage_fn });

    // Additional global functions (skeleton implementations)
    const type_fn = Function{ .native = .{ .id = NativeFnId.lua_type } };
    try globals.set("type", .{ .function = type_fn });

    const pcall_fn = Function{ .native = .{ .id = NativeFnId.pcall } };
    try globals.set("pcall", .{ .function = pcall_fn });

    const xpcall_fn = Function{ .native = .{ .id = NativeFnId.xpcall } };
    try globals.set("xpcall", .{ .function = xpcall_fn });

    const next_fn = Function{ .native = .{ .id = NativeFnId.next } };
    try globals.set("next", .{ .function = next_fn });

    const pairs_fn = Function{ .native = .{ .id = NativeFnId.pairs } };
    try globals.set("pairs", .{ .function = pairs_fn });

    const ipairs_fn = Function{ .native = .{ .id = NativeFnId.ipairs } };
    try globals.set("ipairs", .{ .function = ipairs_fn });

    const getmetatable_fn = Function{ .native = .{ .id = NativeFnId.getmetatable } };
    try globals.set("getmetatable", .{ .function = getmetatable_fn });

    const setmetatable_fn = Function{ .native = .{ .id = NativeFnId.setmetatable } };
    try globals.set("setmetatable", .{ .function = setmetatable_fn });

    const rawget_fn = Function{ .native = .{ .id = NativeFnId.rawget } };
    try globals.set("rawget", .{ .function = rawget_fn });

    const rawset_fn = Function{ .native = .{ .id = NativeFnId.rawset } };
    try globals.set("rawset", .{ .function = rawset_fn });

    const rawlen_fn = Function{ .native = .{ .id = NativeFnId.rawlen } };
    try globals.set("rawlen", .{ .function = rawlen_fn });

    const rawequal_fn = Function{ .native = .{ .id = NativeFnId.rawequal } };
    try globals.set("rawequal", .{ .function = rawequal_fn });

    const select_fn = Function{ .native = .{ .id = NativeFnId.select } };
    try globals.set("select", .{ .function = select_fn });

    const tonumber_fn = Function{ .native = .{ .id = NativeFnId.tonumber } };
    try globals.set("tonumber", .{ .function = tonumber_fn });

    const load_fn = Function{ .native = .{ .id = NativeFnId.load } };
    try globals.set("load", .{ .function = load_fn });

    const loadfile_fn = Function{ .native = .{ .id = NativeFnId.loadfile } };
    try globals.set("loadfile", .{ .function = loadfile_fn });

    const dofile_fn = Function{ .native = .{ .id = NativeFnId.dofile } };
    try globals.set("dofile", .{ .function = dofile_fn });

    const warn_fn = Function{ .native = .{ .id = NativeFnId.warn } };
    try globals.set("warn", .{ .function = warn_fn });

    // Note: _G and _VERSION are typically set to globals itself and a version string
    // They could be implemented as values rather than functions, but we keep them as
    // functions for consistency with the enum system
    const g_fn = Function{ .native = .{ .id = NativeFnId.lua_G } };
    try globals.set("_G", .{ .function = g_fn });

    const version_fn = Function{ .native = .{ .id = NativeFnId.lua_VERSION } };
    try globals.set("_VERSION", .{ .function = version_fn });
}

/// String Library: string.len, string.sub, etc. (skeleton implementations)
fn initStringLibrary(globals: *Table, allocator: std.mem.Allocator) !void {
    var string_table = try allocator.create(Table);
    string_table.* = Table.init(allocator);

    const len_fn = Function{ .native = .{ .id = NativeFnId.string_len } };
    try string_table.set("len", .{ .function = len_fn });

    const sub_fn = Function{ .native = .{ .id = NativeFnId.string_sub } };
    try string_table.set("sub", .{ .function = sub_fn });

    const upper_fn = Function{ .native = .{ .id = NativeFnId.string_upper } };
    try string_table.set("upper", .{ .function = upper_fn });

    const lower_fn = Function{ .native = .{ .id = NativeFnId.string_lower } };
    try string_table.set("lower", .{ .function = lower_fn });

    const byte_fn = Function{ .native = .{ .id = NativeFnId.string_byte } };
    try string_table.set("byte", .{ .function = byte_fn });

    const char_fn = Function{ .native = .{ .id = NativeFnId.string_char } };
    try string_table.set("char", .{ .function = char_fn });

    const rep_fn = Function{ .native = .{ .id = NativeFnId.string_rep } };
    try string_table.set("rep", .{ .function = rep_fn });

    const reverse_fn = Function{ .native = .{ .id = NativeFnId.string_reverse } };
    try string_table.set("reverse", .{ .function = reverse_fn });

    const find_fn = Function{ .native = .{ .id = NativeFnId.string_find } };
    try string_table.set("find", .{ .function = find_fn });

    const match_fn = Function{ .native = .{ .id = NativeFnId.string_match } };
    try string_table.set("match", .{ .function = match_fn });

    const gmatch_fn = Function{ .native = .{ .id = NativeFnId.string_gmatch } };
    try string_table.set("gmatch", .{ .function = gmatch_fn });

    const gsub_fn = Function{ .native = .{ .id = NativeFnId.string_gsub } };
    try string_table.set("gsub", .{ .function = gsub_fn });

    const format_fn = Function{ .native = .{ .id = NativeFnId.string_format } };
    try string_table.set("format", .{ .function = format_fn });

    const dump_fn = Function{ .native = .{ .id = NativeFnId.string_dump } };
    try string_table.set("dump", .{ .function = dump_fn });

    const pack_fn = Function{ .native = .{ .id = NativeFnId.string_pack } };
    try string_table.set("pack", .{ .function = pack_fn });

    const unpack_fn = Function{ .native = .{ .id = NativeFnId.string_unpack } };
    try string_table.set("unpack", .{ .function = unpack_fn });

    const packsize_fn = Function{ .native = .{ .id = NativeFnId.string_packsize } };
    try string_table.set("packsize", .{ .function = packsize_fn });

    try globals.set("string", .{ .table = string_table });
}

/// IO Library: io.write, io.open, etc. (skeleton implementations)
fn initIOLibrary(globals: *Table, allocator: std.mem.Allocator) !void {
    var io_table = try allocator.create(Table);
    io_table.* = Table.init(allocator);

    const write_fn = Function{ .native = .{ .id = NativeFnId.io_write } };
    try io_table.set("write", .{ .function = write_fn });

    const close_fn = Function{ .native = .{ .id = NativeFnId.io_close } };
    try io_table.set("close", .{ .function = close_fn });

    const flush_fn = Function{ .native = .{ .id = NativeFnId.io_flush } };
    try io_table.set("flush", .{ .function = flush_fn });

    const input_fn = Function{ .native = .{ .id = NativeFnId.io_input } };
    try io_table.set("input", .{ .function = input_fn });

    const lines_fn = Function{ .native = .{ .id = NativeFnId.io_lines } };
    try io_table.set("lines", .{ .function = lines_fn });

    const open_fn = Function{ .native = .{ .id = NativeFnId.io_open } };
    try io_table.set("open", .{ .function = open_fn });

    const output_fn = Function{ .native = .{ .id = NativeFnId.io_output } };
    try io_table.set("output", .{ .function = output_fn });

    const popen_fn = Function{ .native = .{ .id = NativeFnId.io_popen } };
    try io_table.set("popen", .{ .function = popen_fn });

    const read_fn = Function{ .native = .{ .id = NativeFnId.io_read } };
    try io_table.set("read", .{ .function = read_fn });

    const tmpfile_fn = Function{ .native = .{ .id = NativeFnId.io_tmpfile } };
    try io_table.set("tmpfile", .{ .function = tmpfile_fn });

    const type_fn = Function{ .native = .{ .id = NativeFnId.io_type } };
    try io_table.set("type", .{ .function = type_fn });

    try globals.set("io", .{ .table = io_table });
}

/// Math Library: math.abs, math.ceil, etc. (skeleton implementations)
fn initMathLibrary(globals: *Table, allocator: std.mem.Allocator) !void {
    var math_table = try allocator.create(Table);
    math_table.* = Table.init(allocator);

    // Math constants
    try math_table.set("pi", .{ .number = math.MATH_PI });
    try math_table.set("huge", .{ .number = math.MATH_HUGE });
    try math_table.set("maxinteger", .{ .integer = math.MATH_MAXINTEGER });
    try math_table.set("mininteger", .{ .integer = math.MATH_MININTEGER });

    // Math functions (skeleton implementations)
    const abs_fn = Function{ .native = .{ .id = NativeFnId.math_abs } };
    try math_table.set("abs", .{ .function = abs_fn });

    const acos_fn = Function{ .native = .{ .id = NativeFnId.math_acos } };
    try math_table.set("acos", .{ .function = acos_fn });

    const asin_fn = Function{ .native = .{ .id = NativeFnId.math_asin } };
    try math_table.set("asin", .{ .function = asin_fn });

    const atan_fn = Function{ .native = .{ .id = NativeFnId.math_atan } };
    try math_table.set("atan", .{ .function = atan_fn });

    const ceil_fn = Function{ .native = .{ .id = NativeFnId.math_ceil } };
    try math_table.set("ceil", .{ .function = ceil_fn });

    const cos_fn = Function{ .native = .{ .id = NativeFnId.math_cos } };
    try math_table.set("cos", .{ .function = cos_fn });

    const deg_fn = Function{ .native = .{ .id = NativeFnId.math_deg } };
    try math_table.set("deg", .{ .function = deg_fn });

    const exp_fn = Function{ .native = .{ .id = NativeFnId.math_exp } };
    try math_table.set("exp", .{ .function = exp_fn });

    const floor_fn = Function{ .native = .{ .id = NativeFnId.math_floor } };
    try math_table.set("floor", .{ .function = floor_fn });

    const fmod_fn = Function{ .native = .{ .id = NativeFnId.math_fmod } };
    try math_table.set("fmod", .{ .function = fmod_fn });

    const log_fn = Function{ .native = .{ .id = NativeFnId.math_log } };
    try math_table.set("log", .{ .function = log_fn });

    const max_fn = Function{ .native = .{ .id = NativeFnId.math_max } };
    try math_table.set("max", .{ .function = max_fn });

    const min_fn = Function{ .native = .{ .id = NativeFnId.math_min } };
    try math_table.set("min", .{ .function = min_fn });

    const modf_fn = Function{ .native = .{ .id = NativeFnId.math_modf } };
    try math_table.set("modf", .{ .function = modf_fn });

    const rad_fn = Function{ .native = .{ .id = NativeFnId.math_rad } };
    try math_table.set("rad", .{ .function = rad_fn });

    const random_fn = Function{ .native = .{ .id = NativeFnId.math_random } };
    try math_table.set("random", .{ .function = random_fn });

    const randomseed_fn = Function{ .native = .{ .id = NativeFnId.math_randomseed } };
    try math_table.set("randomseed", .{ .function = randomseed_fn });

    const sin_fn = Function{ .native = .{ .id = NativeFnId.math_sin } };
    try math_table.set("sin", .{ .function = sin_fn });

    const sqrt_fn = Function{ .native = .{ .id = NativeFnId.math_sqrt } };
    try math_table.set("sqrt", .{ .function = sqrt_fn });

    const tan_fn = Function{ .native = .{ .id = NativeFnId.math_tan } };
    try math_table.set("tan", .{ .function = tan_fn });

    const tointeger_fn = Function{ .native = .{ .id = NativeFnId.math_tointeger } };
    try math_table.set("tointeger", .{ .function = tointeger_fn });

    const type_fn = Function{ .native = .{ .id = NativeFnId.math_type } };
    try math_table.set("type", .{ .function = type_fn });

    const ult_fn = Function{ .native = .{ .id = NativeFnId.math_ult } };
    try math_table.set("ult", .{ .function = ult_fn });

    try globals.set("math", .{ .table = math_table });
}

/// Table Library: table.insert, table.remove, etc. (skeleton implementations)
fn initTableLibrary(globals: *Table, allocator: std.mem.Allocator) !void {
    var table_table = try allocator.create(Table);
    table_table.* = Table.init(allocator);

    const insert_fn = Function{ .native = .{ .id = NativeFnId.table_insert } };
    try table_table.set("insert", .{ .function = insert_fn });

    const remove_fn = Function{ .native = .{ .id = NativeFnId.table_remove } };
    try table_table.set("remove", .{ .function = remove_fn });

    const sort_fn = Function{ .native = .{ .id = NativeFnId.table_sort } };
    try table_table.set("sort", .{ .function = sort_fn });

    const concat_fn = Function{ .native = .{ .id = NativeFnId.table_concat } };
    try table_table.set("concat", .{ .function = concat_fn });

    const move_fn = Function{ .native = .{ .id = NativeFnId.table_move } };
    try table_table.set("move", .{ .function = move_fn });

    const pack_fn = Function{ .native = .{ .id = NativeFnId.table_pack } };
    try table_table.set("pack", .{ .function = pack_fn });

    const unpack_fn = Function{ .native = .{ .id = NativeFnId.table_unpack } };
    try table_table.set("unpack", .{ .function = unpack_fn });

    try globals.set("table", .{ .table = table_table });
}

/// OS Library: os.clock, os.date, etc. (skeleton implementations)
fn initOSLibrary(globals: *Table, allocator: std.mem.Allocator) !void {
    var os_table = try allocator.create(Table);
    os_table.* = Table.init(allocator);

    const clock_fn = Function{ .native = .{ .id = NativeFnId.os_clock } };
    try os_table.set("clock", .{ .function = clock_fn });

    const date_fn = Function{ .native = .{ .id = NativeFnId.os_date } };
    try os_table.set("date", .{ .function = date_fn });

    const difftime_fn = Function{ .native = .{ .id = NativeFnId.os_difftime } };
    try os_table.set("difftime", .{ .function = difftime_fn });

    const execute_fn = Function{ .native = .{ .id = NativeFnId.os_execute } };
    try os_table.set("execute", .{ .function = execute_fn });

    const exit_fn = Function{ .native = .{ .id = NativeFnId.os_exit } };
    try os_table.set("exit", .{ .function = exit_fn });

    const getenv_fn = Function{ .native = .{ .id = NativeFnId.os_getenv } };
    try os_table.set("getenv", .{ .function = getenv_fn });

    const remove_fn = Function{ .native = .{ .id = NativeFnId.os_remove } };
    try os_table.set("remove", .{ .function = remove_fn });

    const rename_fn = Function{ .native = .{ .id = NativeFnId.os_rename } };
    try os_table.set("rename", .{ .function = rename_fn });

    const setlocale_fn = Function{ .native = .{ .id = NativeFnId.os_setlocale } };
    try os_table.set("setlocale", .{ .function = setlocale_fn });

    const time_fn = Function{ .native = .{ .id = NativeFnId.os_time } };
    try os_table.set("time", .{ .function = time_fn });

    const tmpname_fn = Function{ .native = .{ .id = NativeFnId.os_tmpname } };
    try os_table.set("tmpname", .{ .function = tmpname_fn });

    try globals.set("os", .{ .table = os_table });
}

/// Debug Library: debug.debug, debug.getinfo, etc. (skeleton implementations)
fn initDebugLibrary(globals: *Table, allocator: std.mem.Allocator) !void {
    var debug_table = try allocator.create(Table);
    debug_table.* = Table.init(allocator);

    const debug_fn = Function{ .native = .{ .id = NativeFnId.debug_debug } };
    try debug_table.set("debug", .{ .function = debug_fn });

    const gethook_fn = Function{ .native = .{ .id = NativeFnId.debug_gethook } };
    try debug_table.set("gethook", .{ .function = gethook_fn });

    const getinfo_fn = Function{ .native = .{ .id = NativeFnId.debug_getinfo } };
    try debug_table.set("getinfo", .{ .function = getinfo_fn });

    const getlocal_fn = Function{ .native = .{ .id = NativeFnId.debug_getlocal } };
    try debug_table.set("getlocal", .{ .function = getlocal_fn });

    const getmetatable_fn = Function{ .native = .{ .id = NativeFnId.debug_getmetatable } };
    try debug_table.set("getmetatable", .{ .function = getmetatable_fn });

    const getregistry_fn = Function{ .native = .{ .id = NativeFnId.debug_getregistry } };
    try debug_table.set("getregistry", .{ .function = getregistry_fn });

    const getupvalue_fn = Function{ .native = .{ .id = NativeFnId.debug_getupvalue } };
    try debug_table.set("getupvalue", .{ .function = getupvalue_fn });

    const getuservalue_fn = Function{ .native = .{ .id = NativeFnId.debug_getuservalue } };
    try debug_table.set("getuservalue", .{ .function = getuservalue_fn });

    const sethook_fn = Function{ .native = .{ .id = NativeFnId.debug_sethook } };
    try debug_table.set("sethook", .{ .function = sethook_fn });

    const setlocal_fn = Function{ .native = .{ .id = NativeFnId.debug_setlocal } };
    try debug_table.set("setlocal", .{ .function = setlocal_fn });

    const setmetatable_fn = Function{ .native = .{ .id = NativeFnId.debug_setmetatable } };
    try debug_table.set("setmetatable", .{ .function = setmetatable_fn });

    const setupvalue_fn = Function{ .native = .{ .id = NativeFnId.debug_setupvalue } };
    try debug_table.set("setupvalue", .{ .function = setupvalue_fn });

    const setuservalue_fn = Function{ .native = .{ .id = NativeFnId.debug_setuservalue } };
    try debug_table.set("setuservalue", .{ .function = setuservalue_fn });

    const traceback_fn = Function{ .native = .{ .id = NativeFnId.debug_traceback } };
    try debug_table.set("traceback", .{ .function = traceback_fn });

    const upvalueid_fn = Function{ .native = .{ .id = NativeFnId.debug_upvalueid } };
    try debug_table.set("upvalueid", .{ .function = upvalueid_fn });

    const upvaluejoin_fn = Function{ .native = .{ .id = NativeFnId.debug_upvaluejoin } };
    try debug_table.set("upvaluejoin", .{ .function = upvaluejoin_fn });

    try globals.set("debug", .{ .table = debug_table });
}

/// UTF-8 Library: utf8.char, utf8.len, etc. (skeleton implementations)
fn initUtf8Library(globals: *Table, gc: *GC) !void {
    const allocator = gc.allocator;
    var utf8_table = try allocator.create(Table);
    utf8_table.* = Table.init(allocator);

    // UTF-8 pattern constant
    const charpattern_str = try gc.allocString(utf8.UTF8_CHARPATTERN);
    try utf8_table.set("charpattern", .{ .string = charpattern_str });

    const char_fn = Function{ .native = .{ .id = NativeFnId.utf8_char } };
    try utf8_table.set("char", .{ .function = char_fn });

    const codes_fn = Function{ .native = .{ .id = NativeFnId.utf8_codes } };
    try utf8_table.set("codes", .{ .function = codes_fn });

    const codepoint_fn = Function{ .native = .{ .id = NativeFnId.utf8_codepoint } };
    try utf8_table.set("codepoint", .{ .function = codepoint_fn });

    const len_fn = Function{ .native = .{ .id = NativeFnId.utf8_len } };
    try utf8_table.set("len", .{ .function = len_fn });

    const offset_fn = Function{ .native = .{ .id = NativeFnId.utf8_offset } };
    try utf8_table.set("offset", .{ .function = offset_fn });

    try globals.set("utf8", .{ .table = utf8_table });
}

/// Coroutine Library: coroutine.create, coroutine.resume, etc. (skeleton implementations)
fn initCoroutineLibrary(globals: *Table, allocator: std.mem.Allocator) !void {
    var coroutine_table = try allocator.create(Table);
    coroutine_table.* = Table.init(allocator);

    const create_fn = Function{ .native = .{ .id = NativeFnId.coroutine_create } };
    try coroutine_table.set("create", .{ .function = create_fn });

    const resume_fn = Function{ .native = .{ .id = NativeFnId.coroutine_resume } };
    try coroutine_table.set("resume", .{ .function = resume_fn });

    const running_fn = Function{ .native = .{ .id = NativeFnId.coroutine_running } };
    try coroutine_table.set("running", .{ .function = running_fn });

    const status_fn = Function{ .native = .{ .id = NativeFnId.coroutine_status } };
    try coroutine_table.set("status", .{ .function = status_fn });

    const wrap_fn = Function{ .native = .{ .id = NativeFnId.coroutine_wrap } };
    try coroutine_table.set("wrap", .{ .function = wrap_fn });

    const yield_fn = Function{ .native = .{ .id = NativeFnId.coroutine_yield } };
    try coroutine_table.set("yield", .{ .function = yield_fn });

    const isyieldable_fn = Function{ .native = .{ .id = NativeFnId.coroutine_isyieldable } };
    try coroutine_table.set("isyieldable", .{ .function = isyieldable_fn });

    const close_fn = Function{ .native = .{ .id = NativeFnId.coroutine_close } };
    try coroutine_table.set("close", .{ .function = close_fn });

    try globals.set("coroutine", .{ .table = coroutine_table });
}

/// Module System: require, package.loadlib, package.searchpath (skeleton implementations)
fn initModuleSystem(globals: *Table, gc: *GC) !void {
    const allocator = gc.allocator;

    // Global require function
    const require_fn = Function{ .native = .{ .id = NativeFnId.require } };
    try globals.set("require", .{ .function = require_fn });

    // Package table for module system
    var package_table = try allocator.create(Table);
    package_table.* = Table.init(allocator);

    // Package functions
    const loadlib_fn = Function{ .native = .{ .id = NativeFnId.package_loadlib } };
    try package_table.set("loadlib", .{ .function = loadlib_fn });

    const searchpath_fn = Function{ .native = .{ .id = NativeFnId.package_searchpath } };
    try package_table.set("searchpath", .{ .function = searchpath_fn });

    // Package configuration and paths (platform-specific in real implementation)
    const config_str = try gc.allocString("/\n;\n?\n!\n-");
    try package_table.set("config", .{ .string = config_str }); // Unix-style config

    const path_str = try gc.allocString("./?.lua;/usr/local/share/lua/5.4/?.lua");
    try package_table.set("path", .{ .string = path_str }); // Default Lua path

    const cpath_str = try gc.allocString("./?.so;/usr/local/lib/lua/5.4/?.so");
    try package_table.set("cpath", .{ .string = cpath_str }); // Default C path

    // Package tables for loaded modules and searchers
    const loaded_table = try allocator.create(Table);
    loaded_table.* = Table.init(allocator);
    try package_table.set("loaded", .{ .table = loaded_table });

    const preload_table = try allocator.create(Table);
    preload_table.* = Table.init(allocator);
    try package_table.set("preload", .{ .table = preload_table });

    const searchers_table = try allocator.create(Table);
    searchers_table.* = Table.init(allocator);
    try package_table.set("searchers", .{ .table = searchers_table });

    try globals.set("package", .{ .table = package_table });
}

/// Dispatch native function calls to appropriate implementations
/// Organized by library for maintainability
pub fn invoke(id: NativeFnId, vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    switch (id) {
        // Global Functions (Core implementations)
        .print => try global.nativePrint(vm, func_reg, nargs, nresults),
        .tostring => try string.nativeToString(vm, func_reg, nargs, nresults),
        .assert => try error_handling.nativeAssert(vm, func_reg, nargs, nresults),
        .lua_error => try error_handling.nativeError(vm, func_reg, nargs, nresults),
        .collectgarbage => try error_handling.nativeCollectGarbage(vm, func_reg, nargs, nresults),

        // Additional Global Functions (Skeleton implementations)
        .lua_type => try global.nativeType(vm, func_reg, nargs, nresults),
        .pcall => try global.nativePcall(vm, func_reg, nargs, nresults),
        .xpcall => try global.nativeXpcall(vm, func_reg, nargs, nresults),
        .next => try global.nativeNext(vm, func_reg, nargs, nresults),
        .pairs => try global.nativePairs(vm, func_reg, nargs, nresults),
        .ipairs => try global.nativeIpairs(vm, func_reg, nargs, nresults),
        .getmetatable => try global.nativeGetmetatable(vm, func_reg, nargs, nresults),
        .setmetatable => try global.nativeSetmetatable(vm, func_reg, nargs, nresults),
        .rawget => try global.nativeRawget(vm, func_reg, nargs, nresults),
        .rawset => try global.nativeRawset(vm, func_reg, nargs, nresults),
        .rawlen => try global.nativeRawlen(vm, func_reg, nargs, nresults),
        .rawequal => try global.nativeRawequal(vm, func_reg, nargs, nresults),
        .select => try global.nativeSelect(vm, func_reg, nargs, nresults),
        .tonumber => try global.nativeTonumber(vm, func_reg, nargs, nresults),
        .load => try global.nativeLoad(vm, func_reg, nargs, nresults),
        .loadfile => try global.nativeLoadfile(vm, func_reg, nargs, nresults),
        .dofile => try global.nativeDofile(vm, func_reg, nargs, nresults),
        .warn => try global.nativeWarn(vm, func_reg, nargs, nresults),
        .lua_G => try global.nativeG(vm, func_reg, nargs, nresults),
        .lua_VERSION => try global.nativeVersion(vm, func_reg, nargs, nresults),

        // String Library (Skeleton implementations)
        .string_len => try string.nativeStringLen(vm, func_reg, nargs, nresults),
        .string_sub => try string.nativeStringSub(vm, func_reg, nargs, nresults),
        .string_upper => try string.nativeStringUpper(vm, func_reg, nargs, nresults),
        .string_lower => try string.nativeStringLower(vm, func_reg, nargs, nresults),
        .string_byte => try string.nativeStringByte(vm, func_reg, nargs, nresults),
        .string_char => try string.nativeStringChar(vm, func_reg, nargs, nresults),
        .string_rep => try string.nativeStringRep(vm, func_reg, nargs, nresults),
        .string_reverse => try string.nativeStringReverse(vm, func_reg, nargs, nresults),
        .string_find => try string.nativeStringFind(vm, func_reg, nargs, nresults),
        .string_match => try string.nativeStringMatch(vm, func_reg, nargs, nresults),
        .string_gmatch => try string.nativeStringGmatch(vm, func_reg, nargs, nresults),
        .string_gsub => try string.nativeStringGsub(vm, func_reg, nargs, nresults),
        .string_format => try string.nativeStringFormat(vm, func_reg, nargs, nresults),
        .string_dump => try string.nativeStringDump(vm, func_reg, nargs, nresults),
        .string_pack => try string.nativeStringPack(vm, func_reg, nargs, nresults),
        .string_unpack => try string.nativeStringUnpack(vm, func_reg, nargs, nresults),
        .string_packsize => try string.nativeStringPacksize(vm, func_reg, nargs, nresults),

        // IO Library (Skeleton implementations)
        .io_write => try io.nativeIoWrite(vm, func_reg, nargs, nresults),
        .io_close => try io.nativeIoClose(vm, func_reg, nargs, nresults),
        .io_flush => try io.nativeIoFlush(vm, func_reg, nargs, nresults),
        .io_input => try io.nativeIoInput(vm, func_reg, nargs, nresults),
        .io_lines => try io.nativeIoLines(vm, func_reg, nargs, nresults),
        .io_open => try io.nativeIoOpen(vm, func_reg, nargs, nresults),
        .io_output => try io.nativeIoOutput(vm, func_reg, nargs, nresults),
        .io_popen => try io.nativeIoPopen(vm, func_reg, nargs, nresults),
        .io_read => try io.nativeIoRead(vm, func_reg, nargs, nresults),
        .io_tmpfile => try io.nativeIoTmpfile(vm, func_reg, nargs, nresults),
        .io_type => try io.nativeIoType(vm, func_reg, nargs, nresults),

        // File handle methods (Future userdata implementation)
        .file_close => try io.nativeFileClose(vm, func_reg, nargs, nresults),
        .file_flush => try io.nativeFileFlush(vm, func_reg, nargs, nresults),
        .file_lines => try io.nativeFileLines(vm, func_reg, nargs, nresults),
        .file_read => try io.nativeFileRead(vm, func_reg, nargs, nresults),
        .file_seek => try io.nativeFileSeek(vm, func_reg, nargs, nresults),
        .file_setvbuf => try io.nativeFileSetvbuf(vm, func_reg, nargs, nresults),
        .file_write => try io.nativeFileWrite(vm, func_reg, nargs, nresults),

        // Math Library (skeleton implementations)
        .math_abs => try math.nativeMathAbs(vm, func_reg, nargs, nresults),
        .math_acos => try math.nativeMathAcos(vm, func_reg, nargs, nresults),
        .math_asin => try math.nativeMathAsin(vm, func_reg, nargs, nresults),
        .math_atan => try math.nativeMathAtan(vm, func_reg, nargs, nresults),
        .math_ceil => try math.nativeMathCeil(vm, func_reg, nargs, nresults),
        .math_cos => try math.nativeMathCos(vm, func_reg, nargs, nresults),
        .math_deg => try math.nativeMathDeg(vm, func_reg, nargs, nresults),
        .math_exp => try math.nativeMathExp(vm, func_reg, nargs, nresults),
        .math_floor => try math.nativeMathFloor(vm, func_reg, nargs, nresults),
        .math_fmod => try math.nativeMathFmod(vm, func_reg, nargs, nresults),
        .math_log => try math.nativeMathLog(vm, func_reg, nargs, nresults),
        .math_max => try math.nativeMathMax(vm, func_reg, nargs, nresults),
        .math_min => try math.nativeMathMin(vm, func_reg, nargs, nresults),
        .math_modf => try math.nativeMathModf(vm, func_reg, nargs, nresults),
        .math_rad => try math.nativeMathRad(vm, func_reg, nargs, nresults),
        .math_random => try math.nativeMathRandom(vm, func_reg, nargs, nresults),
        .math_randomseed => try math.nativeMathRandomseed(vm, func_reg, nargs, nresults),
        .math_sin => try math.nativeMathSin(vm, func_reg, nargs, nresults),
        .math_sqrt => try math.nativeMathSqrt(vm, func_reg, nargs, nresults),
        .math_tan => try math.nativeMathTan(vm, func_reg, nargs, nresults),
        .math_tointeger => try math.nativeMathTointeger(vm, func_reg, nargs, nresults),
        .math_type => try math.nativeMathType(vm, func_reg, nargs, nresults),
        .math_ult => try math.nativeMathUlt(vm, func_reg, nargs, nresults),

        // Table Library (skeleton implementations)
        .table_insert => try table.nativeTableInsert(vm, func_reg, nargs, nresults),
        .table_remove => try table.nativeTableRemove(vm, func_reg, nargs, nresults),
        .table_sort => try table.nativeTableSort(vm, func_reg, nargs, nresults),
        .table_concat => try table.nativeTableConcat(vm, func_reg, nargs, nresults),
        .table_move => try table.nativeTableMove(vm, func_reg, nargs, nresults),
        .table_pack => try table.nativeTablePack(vm, func_reg, nargs, nresults),
        .table_unpack => try table.nativeTableUnpack(vm, func_reg, nargs, nresults),

        // OS Library (skeleton implementations)
        .os_clock => try os.nativeOsClock(vm, func_reg, nargs, nresults),
        .os_date => try os.nativeOsDate(vm, func_reg, nargs, nresults),
        .os_difftime => try os.nativeOsDifftime(vm, func_reg, nargs, nresults),
        .os_execute => try os.nativeOsExecute(vm, func_reg, nargs, nresults),
        .os_exit => try os.nativeOsExit(vm, func_reg, nargs, nresults),
        .os_getenv => try os.nativeOsGetenv(vm, func_reg, nargs, nresults),
        .os_remove => try os.nativeOsRemove(vm, func_reg, nargs, nresults),
        .os_rename => try os.nativeOsRename(vm, func_reg, nargs, nresults),
        .os_setlocale => try os.nativeOsSetlocale(vm, func_reg, nargs, nresults),
        .os_time => try os.nativeOsTime(vm, func_reg, nargs, nresults),
        .os_tmpname => try os.nativeOsTmpname(vm, func_reg, nargs, nresults),

        // Debug Library (skeleton implementations)
        .debug_debug => try debug.nativeDebugDebug(vm, func_reg, nargs, nresults),
        .debug_gethook => try debug.nativeDebugGethook(vm, func_reg, nargs, nresults),
        .debug_getinfo => try debug.nativeDebugGetinfo(vm, func_reg, nargs, nresults),
        .debug_getlocal => try debug.nativeDebugGetlocal(vm, func_reg, nargs, nresults),
        .debug_getmetatable => try debug.nativeDebugGetmetatable(vm, func_reg, nargs, nresults),
        .debug_getregistry => try debug.nativeDebugGetregistry(vm, func_reg, nargs, nresults),
        .debug_getupvalue => try debug.nativeDebugGetupvalue(vm, func_reg, nargs, nresults),
        .debug_getuservalue => try debug.nativeDebugGetuservalue(vm, func_reg, nargs, nresults),
        .debug_sethook => try debug.nativeDebugSethook(vm, func_reg, nargs, nresults),
        .debug_setlocal => try debug.nativeDebugSetlocal(vm, func_reg, nargs, nresults),
        .debug_setmetatable => try debug.nativeDebugSetmetatable(vm, func_reg, nargs, nresults),
        .debug_setupvalue => try debug.nativeDebugSetupvalue(vm, func_reg, nargs, nresults),
        .debug_setuservalue => try debug.nativeDebugSetuservalue(vm, func_reg, nargs, nresults),
        .debug_traceback => try debug.nativeDebugTraceback(vm, func_reg, nargs, nresults),
        .debug_upvalueid => try debug.nativeDebugUpvalueid(vm, func_reg, nargs, nresults),
        .debug_upvaluejoin => try debug.nativeDebugUpvaluejoin(vm, func_reg, nargs, nresults),

        // UTF-8 Library (skeleton implementations)
        .utf8_char => try utf8.nativeUtf8Char(vm, func_reg, nargs, nresults),
        .utf8_codes => try utf8.nativeUtf8Codes(vm, func_reg, nargs, nresults),
        .utf8_codepoint => try utf8.nativeUtf8Codepoint(vm, func_reg, nargs, nresults),
        .utf8_len => try utf8.nativeUtf8Len(vm, func_reg, nargs, nresults),
        .utf8_offset => try utf8.nativeUtf8Offset(vm, func_reg, nargs, nresults),

        // Coroutine Library (skeleton implementations)
        .coroutine_create => try coroutine.nativeCoroutineCreate(vm, func_reg, nargs, nresults),
        .coroutine_resume => try coroutine.nativeCoroutineResume(vm, func_reg, nargs, nresults),
        .coroutine_running => try coroutine.nativeCoroutineRunning(vm, func_reg, nargs, nresults),
        .coroutine_status => try coroutine.nativeCoroutineStatus(vm, func_reg, nargs, nresults),
        .coroutine_wrap => try coroutine.nativeCoroutineWrap(vm, func_reg, nargs, nresults),
        .coroutine_yield => try coroutine.nativeCoroutineYield(vm, func_reg, nargs, nresults),
        .coroutine_isyieldable => try coroutine.nativeCoroutineIsYieldable(vm, func_reg, nargs, nresults),
        .coroutine_close => try coroutine.nativeCoroutineClose(vm, func_reg, nargs, nresults),

        // Module System (skeleton implementations)
        .require => try modules.nativeRequire(vm, func_reg, nargs, nresults),
        .package_loadlib => try modules.nativePackageLoadlib(vm, func_reg, nargs, nresults),
        .package_searchpath => try modules.nativePackageSearchpath(vm, func_reg, nargs, nresults),
    }
}
