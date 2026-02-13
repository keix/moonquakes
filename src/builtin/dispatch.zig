const std = @import("std");
const object = @import("../runtime/gc/object.zig");
const TableObject = object.TableObject;
const NativeClosureObject = object.NativeClosureObject;
const NativeFn = @import("../runtime/native.zig").NativeFn;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const TValue = @import("../runtime/value.zig").TValue;
const GC = @import("../runtime/gc/gc.zig").GC;
const ver = @import("../version.zig");

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

/// Set a table entry with a GC-allocated key string
/// This ensures the key is properly managed by GC and can be marked during collection
fn setStringKey(tbl: *TableObject, gc: *GC, name: []const u8, value: TValue) !void {
    const key_str = try gc.allocString(name);
    try tbl.set(key_str, value);
}

/// Register a native function in a table using NativeClosureObject
/// Keys are GC-allocated strings to ensure proper marking during GC
fn registerNative(tbl: *TableObject, gc: *GC, name: []const u8, id: NativeFnId) !void {
    const nc = try gc.allocNativeClosure(.{ .id = id });
    try setStringKey(tbl, gc, name, TValue.fromNativeClosure(nc));
}

/// Initialize the global environment with all Lua standard libraries
/// Organized by Lua manual chapters for maintainability
pub fn initGlobalEnvironment(globals: *TableObject, gc: *GC) !void {
    // Global Functions (Chapter 6.1)
    try initGlobalFunctions(globals, gc);

    // Module System (Chapter 6.3) - skeleton
    try initModuleSystem(globals, gc);

    // String Library (Chapter 6.4) - skeleton
    try initStringLibrary(globals, gc);

    // IO Library (Chapter 6.8)
    try initIOLibrary(globals, gc);

    // Math Library (Chapter 6.7) - skeleton
    try initMathLibrary(globals, gc);

    // Table Library (Chapter 6.6) - skeleton
    try initTableLibrary(globals, gc);

    // OS Library (Chapter 6.9) - skeleton
    try initOSLibrary(globals, gc);

    // Debug Library (Chapter 6.10) - skeleton
    try initDebugLibrary(globals, gc);

    // UTF-8 Support (Chapter 6.5) - skeleton
    try initUtf8Library(globals, gc);

    // Coroutine Library (Chapter 2.6) - skeleton
    try initCoroutineLibrary(globals, gc);
}

/// Global Functions: print, assert, error, type, tostring, collectgarbage, etc.
fn initGlobalFunctions(globals: *TableObject, gc: *GC) !void {
    // Core functions (implemented)
    try registerNative(globals, gc, "print", .print);
    try registerNative(globals, gc, "tostring", .tostring);
    try registerNative(globals, gc, "assert", .assert);
    try registerNative(globals, gc, "error", .lua_error);
    try registerNative(globals, gc, "collectgarbage", .collectgarbage);

    // Additional global functions (skeleton implementations)
    try registerNative(globals, gc, "type", .lua_type);
    try registerNative(globals, gc, "pcall", .pcall);
    try registerNative(globals, gc, "xpcall", .xpcall);
    try registerNative(globals, gc, "next", .next);
    try registerNative(globals, gc, "pairs", .pairs);
    try registerNative(globals, gc, "ipairs", .ipairs);
    try registerNative(globals, gc, "getmetatable", .getmetatable);
    try registerNative(globals, gc, "setmetatable", .setmetatable);
    try registerNative(globals, gc, "rawget", .rawget);
    try registerNative(globals, gc, "rawset", .rawset);
    try registerNative(globals, gc, "rawlen", .rawlen);
    try registerNative(globals, gc, "rawequal", .rawequal);
    try registerNative(globals, gc, "select", .select);
    try registerNative(globals, gc, "tonumber", .tonumber);
    try registerNative(globals, gc, "load", .load);
    try registerNative(globals, gc, "loadfile", .loadfile);
    try registerNative(globals, gc, "dofile", .dofile);
    try registerNative(globals, gc, "warn", .warn);

    // _G and _ENV are self-references to the globals table itself
    try setStringKey(globals, gc, "_G", TValue.fromTable(globals));
    try setStringKey(globals, gc, "_ENV", TValue.fromTable(globals));
    // _VERSION is a version string constant
    const version_str = try gc.allocString(ver.version_string);
    try setStringKey(globals, gc, "_VERSION", TValue.fromString(version_str));
}

/// String Library: string.len, string.sub, etc. (skeleton implementations)
fn initStringLibrary(globals: *TableObject, gc: *GC) !void {
    const string_table = try gc.allocTable();

    try registerNative(string_table, gc, "len", .string_len);
    try registerNative(string_table, gc, "sub", .string_sub);
    try registerNative(string_table, gc, "upper", .string_upper);
    try registerNative(string_table, gc, "lower", .string_lower);
    try registerNative(string_table, gc, "byte", .string_byte);
    try registerNative(string_table, gc, "char", .string_char);
    try registerNative(string_table, gc, "rep", .string_rep);
    try registerNative(string_table, gc, "reverse", .string_reverse);
    try registerNative(string_table, gc, "find", .string_find);
    try registerNative(string_table, gc, "match", .string_match);
    try registerNative(string_table, gc, "gmatch", .string_gmatch);
    try registerNative(string_table, gc, "gsub", .string_gsub);
    try registerNative(string_table, gc, "format", .string_format);
    try registerNative(string_table, gc, "dump", .string_dump);
    try registerNative(string_table, gc, "pack", .string_pack);
    try registerNative(string_table, gc, "unpack", .string_unpack);
    try registerNative(string_table, gc, "packsize", .string_packsize);

    try setStringKey(globals, gc, "string", TValue.fromTable(string_table));
}

/// IO Library: io.write, io.open, etc. (skeleton implementations)
fn initIOLibrary(globals: *TableObject, gc: *GC) !void {
    const io_table = try gc.allocTable();

    try registerNative(io_table, gc, "write", .io_write);
    try registerNative(io_table, gc, "close", .io_close);
    try registerNative(io_table, gc, "flush", .io_flush);
    try registerNative(io_table, gc, "input", .io_input);
    try registerNative(io_table, gc, "lines", .io_lines);
    try registerNative(io_table, gc, "open", .io_open);
    try registerNative(io_table, gc, "output", .io_output);
    try registerNative(io_table, gc, "popen", .io_popen);
    try registerNative(io_table, gc, "read", .io_read);
    try registerNative(io_table, gc, "tmpfile", .io_tmpfile);
    try registerNative(io_table, gc, "type", .io_type);

    try setStringKey(globals, gc, "io", TValue.fromTable(io_table));
}

/// Math Library: math.abs, math.ceil, etc. (skeleton implementations)
fn initMathLibrary(globals: *TableObject, gc: *GC) !void {
    const math_table = try gc.allocTable();

    // Math constants
    try setStringKey(math_table, gc, "pi", .{ .number = math.MATH_PI });
    try setStringKey(math_table, gc, "huge", .{ .number = math.MATH_HUGE });
    try setStringKey(math_table, gc, "maxinteger", .{ .integer = math.MATH_MAXINTEGER });
    try setStringKey(math_table, gc, "mininteger", .{ .integer = math.MATH_MININTEGER });

    // Math functions
    try registerNative(math_table, gc, "abs", .math_abs);
    try registerNative(math_table, gc, "acos", .math_acos);
    try registerNative(math_table, gc, "asin", .math_asin);
    try registerNative(math_table, gc, "atan", .math_atan);
    try registerNative(math_table, gc, "ceil", .math_ceil);
    try registerNative(math_table, gc, "cos", .math_cos);
    try registerNative(math_table, gc, "deg", .math_deg);
    try registerNative(math_table, gc, "exp", .math_exp);
    try registerNative(math_table, gc, "floor", .math_floor);
    try registerNative(math_table, gc, "fmod", .math_fmod);
    try registerNative(math_table, gc, "log", .math_log);
    try registerNative(math_table, gc, "max", .math_max);
    try registerNative(math_table, gc, "min", .math_min);
    try registerNative(math_table, gc, "modf", .math_modf);
    try registerNative(math_table, gc, "rad", .math_rad);
    try registerNative(math_table, gc, "random", .math_random);
    try registerNative(math_table, gc, "randomseed", .math_randomseed);
    try registerNative(math_table, gc, "sin", .math_sin);
    try registerNative(math_table, gc, "sqrt", .math_sqrt);
    try registerNative(math_table, gc, "tan", .math_tan);
    try registerNative(math_table, gc, "tointeger", .math_tointeger);
    try registerNative(math_table, gc, "type", .math_type);
    try registerNative(math_table, gc, "ult", .math_ult);

    try setStringKey(globals, gc, "math", TValue.fromTable(math_table));
}

/// Table Library: table.insert, table.remove, etc. (skeleton implementations)
fn initTableLibrary(globals: *TableObject, gc: *GC) !void {
    const table_table = try gc.allocTable();

    try registerNative(table_table, gc, "insert", .table_insert);
    try registerNative(table_table, gc, "remove", .table_remove);
    try registerNative(table_table, gc, "sort", .table_sort);
    try registerNative(table_table, gc, "concat", .table_concat);
    try registerNative(table_table, gc, "move", .table_move);
    try registerNative(table_table, gc, "pack", .table_pack);
    try registerNative(table_table, gc, "unpack", .table_unpack);

    try setStringKey(globals, gc, "table", TValue.fromTable(table_table));
}

/// OS Library: os.clock, os.date, etc. (skeleton implementations)
fn initOSLibrary(globals: *TableObject, gc: *GC) !void {
    const os_table = try gc.allocTable();

    try registerNative(os_table, gc, "clock", .os_clock);
    try registerNative(os_table, gc, "date", .os_date);
    try registerNative(os_table, gc, "difftime", .os_difftime);
    try registerNative(os_table, gc, "execute", .os_execute);
    try registerNative(os_table, gc, "exit", .os_exit);
    try registerNative(os_table, gc, "getenv", .os_getenv);
    try registerNative(os_table, gc, "remove", .os_remove);
    try registerNative(os_table, gc, "rename", .os_rename);
    try registerNative(os_table, gc, "setlocale", .os_setlocale);
    try registerNative(os_table, gc, "time", .os_time);
    try registerNative(os_table, gc, "tmpname", .os_tmpname);

    try setStringKey(globals, gc, "os", TValue.fromTable(os_table));
}

/// Debug Library: debug.debug, debug.getinfo, etc. (skeleton implementations)
fn initDebugLibrary(globals: *TableObject, gc: *GC) !void {
    const debug_table = try gc.allocTable();

    try registerNative(debug_table, gc, "debug", .debug_debug);
    try registerNative(debug_table, gc, "gethook", .debug_gethook);
    try registerNative(debug_table, gc, "getinfo", .debug_getinfo);
    try registerNative(debug_table, gc, "getlocal", .debug_getlocal);
    try registerNative(debug_table, gc, "getmetatable", .debug_getmetatable);
    try registerNative(debug_table, gc, "getregistry", .debug_getregistry);
    try registerNative(debug_table, gc, "getupvalue", .debug_getupvalue);
    try registerNative(debug_table, gc, "getuservalue", .debug_getuservalue);
    try registerNative(debug_table, gc, "newuserdata", .debug_newuserdata);
    try registerNative(debug_table, gc, "sethook", .debug_sethook);
    try registerNative(debug_table, gc, "setlocal", .debug_setlocal);
    try registerNative(debug_table, gc, "setmetatable", .debug_setmetatable);
    try registerNative(debug_table, gc, "setupvalue", .debug_setupvalue);
    try registerNative(debug_table, gc, "setuservalue", .debug_setuservalue);
    try registerNative(debug_table, gc, "traceback", .debug_traceback);
    try registerNative(debug_table, gc, "upvalueid", .debug_upvalueid);
    try registerNative(debug_table, gc, "upvaluejoin", .debug_upvaluejoin);

    try setStringKey(globals, gc, "debug", TValue.fromTable(debug_table));
}

/// UTF-8 Library: utf8.char, utf8.len, etc. (skeleton implementations)
fn initUtf8Library(globals: *TableObject, gc: *GC) !void {
    const utf8_table = try gc.allocTable();

    // UTF-8 pattern constant
    const charpattern_str = try gc.allocString(utf8.UTF8_CHARPATTERN);
    try setStringKey(utf8_table, gc, "charpattern", TValue.fromString(charpattern_str));

    try registerNative(utf8_table, gc, "char", .utf8_char);
    try registerNative(utf8_table, gc, "codes", .utf8_codes);
    try registerNative(utf8_table, gc, "codepoint", .utf8_codepoint);
    try registerNative(utf8_table, gc, "len", .utf8_len);
    try registerNative(utf8_table, gc, "offset", .utf8_offset);

    try setStringKey(globals, gc, "utf8", TValue.fromTable(utf8_table));
}

/// Coroutine Library: coroutine.create, coroutine.resume, etc. (skeleton implementations)
fn initCoroutineLibrary(globals: *TableObject, gc: *GC) !void {
    const coroutine_table = try gc.allocTable();

    try registerNative(coroutine_table, gc, "create", .coroutine_create);
    try registerNative(coroutine_table, gc, "resume", .coroutine_resume);
    try registerNative(coroutine_table, gc, "running", .coroutine_running);
    try registerNative(coroutine_table, gc, "status", .coroutine_status);
    try registerNative(coroutine_table, gc, "wrap", .coroutine_wrap);
    try registerNative(coroutine_table, gc, "yield", .coroutine_yield);
    try registerNative(coroutine_table, gc, "isyieldable", .coroutine_isyieldable);
    try registerNative(coroutine_table, gc, "close", .coroutine_close);

    try setStringKey(globals, gc, "coroutine", TValue.fromTable(coroutine_table));
}

/// Module System: require, package.loadlib, package.searchpath (skeleton implementations)
fn initModuleSystem(globals: *TableObject, gc: *GC) !void {
    // Global require function
    try registerNative(globals, gc, "require", .require);

    // Package table for module system
    const package_table = try gc.allocTable();

    // Package functions
    try registerNative(package_table, gc, "loadlib", .package_loadlib);
    try registerNative(package_table, gc, "searchpath", .package_searchpath);

    // Package configuration and paths (platform-specific in real implementation)
    const config_str = try gc.allocString("/\n;\n?\n!\n-");
    try setStringKey(package_table, gc, "config", TValue.fromString(config_str));

    const path_str = try gc.allocString("./?.lua;/usr/local/share/lua/5.4/?.lua");
    try setStringKey(package_table, gc, "path", TValue.fromString(path_str));

    const cpath_str = try gc.allocString("./?.so;/usr/local/lib/lua/5.4/?.so");
    try setStringKey(package_table, gc, "cpath", TValue.fromString(cpath_str));

    // Package tables for loaded modules and searchers
    const loaded_table = try gc.allocTable();
    try setStringKey(package_table, gc, "loaded", TValue.fromTable(loaded_table));

    const preload_table = try gc.allocTable();
    try setStringKey(package_table, gc, "preload", TValue.fromTable(preload_table));

    const searchers_table = try gc.allocTable();
    try setStringKey(package_table, gc, "searchers", TValue.fromTable(searchers_table));

    try setStringKey(globals, gc, "package", TValue.fromTable(package_table));
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
        .collectgarbage => try global.nativeCollectGarbage(vm, func_reg, nargs, nresults),

        // Additional Global Functions (Skeleton implementations)
        .lua_type => try global.nativeType(vm, func_reg, nargs, nresults),
        .pcall => try global.nativePcall(vm, func_reg, nargs, nresults),
        .xpcall => try global.nativeXpcall(vm, func_reg, nargs, nresults),
        .next => try global.nativeNext(vm, func_reg, nargs, nresults),
        .pairs => try global.nativePairs(vm, func_reg, nargs, nresults),
        .ipairs => try global.nativeIpairs(vm, func_reg, nargs, nresults),
        .ipairs_iterator => try global.nativeIpairsIterator(vm, func_reg, nargs, nresults),
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
        .string_gmatch_iterator => try string.nativeStringGmatchIterator(vm, func_reg, nargs, nresults),
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
        .io_lines_iterator => try io.nativeIoLinesIterator(vm, func_reg, nargs, nresults),
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
        .debug_newuserdata => try debug.nativeDebugNewuserdata(vm, func_reg, nargs, nresults),
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
        .utf8_codes_iterator => try utf8.nativeUtf8CodesIterator(vm, func_reg, nargs, nresults),
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
