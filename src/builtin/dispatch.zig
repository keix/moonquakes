/// Native builtin function interface (Lua-compatible)
///
/// All builtin functions are invoked by the VM using this unified calling convention.
/// This function operates directly on the VM state and stack.
///
/// Parameters:
/// - vm:        Execution context (VM state). Provides access to stack, registers, and runtime.
/// - func_reg:  Register index where the function is located (base of call frame).
/// - nargs:     Number of arguments passed to the function.
/// - nresults:  Number of expected return values (Lua call convention).
///
/// Stack Layout:
///   [func_reg]           : function
///   [func_reg + 1 ... ]  : arguments
///
/// The builtin function must:
/// - Read arguments from the VM stack
/// - Push return values onto the stack
/// - Respect the expected result count (nresults)
///
/// Notes:
/// - This is the public interface exposed to the VM dispatcher.
/// - Internal helper functions should NOT follow this signature.
/// - Behavior must match Lua 5.4 semantics.
///
/// Example:
///   nativePrint(vm, func_reg, nargs, nresults)
///     -> reads nargs arguments
///     -> writes up to nresults return values
///
const std = @import("std");
const object = @import("../runtime/gc/object.zig");
const TableObject = object.TableObject;
const NativeClosureObject = object.NativeClosureObject;
const NativeFn = @import("../runtime/native.zig").NativeFn;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const TValue = @import("../runtime/value.zig").TValue;
const GC = @import("../runtime/gc/gc.zig").GC;
const ver = @import("../version.zig");
const pipeline = @import("../compiler/pipeline.zig");

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
    try object.tableSetWithBarrier(gc, tbl, TValue.fromString(key_str), value);
}

/// Register a native function in a table using NativeClosureObject
/// Keys are GC-allocated strings to ensure proper marking during GC
fn registerNative(tbl: *TableObject, gc: *GC, name: []const u8, id: NativeFnId) !void {
    const nc = try gc.allocNativeClosure(.{ .id = id });
    try setStringKey(tbl, gc, name, TValue.fromNativeClosure(nc));
}

const BuiltinEntry = struct {
    name: []const u8,
    id: NativeFnId,
};

fn registerEntries(tbl: *TableObject, gc: *GC, entries: []const BuiltinEntry) !void {
    for (entries) |entry| {
        try registerNative(tbl, gc, entry.name, entry.id);
    }
}

fn registerLuaDofileWrapper(globals: *TableObject, gc: *GC) !void {
    const source =
        \\return function (filename)
        \\  if filename == nil then
        \\    error("dofile: stdin not supported")
        \\  end
        \\  local f, msg = loadfile(filename)
        \\  if not f then
        \\    error(msg)
        \\  end
        \\  return f()
        \\end
    ;

    const compile_result = pipeline.compile(gc.allocator, source, .{ .source_name = "=(dofile)" });
    switch (compile_result) {
        .err => |e| {
            defer e.deinit(gc.allocator);
            return error.InvalidBuiltinDefinition;
        },
        .ok => {},
    }
    const raw_proto = compile_result.ok;
    defer pipeline.freeRawProto(gc.allocator, raw_proto);

    gc.inhibitGC();
    defer gc.allowGC();

    const proto = pipeline.materialize(&raw_proto, gc, gc.allocator) catch {
        return error.InvalidBuiltinDefinition;
    };
    if (proto.protos.len < 1) return error.InvalidBuiltinDefinition;
    const closure = try gc.allocClosure(proto.protos[0]);
    if (closure.upvalues.len > 0) {
        closure.upvalues[0].closed = TValue.fromTable(globals);
        closure.upvalues[0].location = &closure.upvalues[0].closed;
    }
    try setStringKey(globals, gc, "dofile", TValue.fromClosure(closure));
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

    // Register standard libraries in package.loaded (required by Lua semantics)
    try registerStdLibsInPackageLoaded(globals, gc);
}

/// Register standard libraries in package.loaded so they are recognized as loaded modules
fn registerStdLibsInPackageLoaded(globals: *TableObject, gc: *GC) !void {
    const package_key = try gc.allocString("package");
    const package_table = (globals.get(TValue.fromString(package_key)) orelse return).asTable() orelse return;

    const loaded_key = try gc.allocString("loaded");
    const loaded_table = (package_table.get(TValue.fromString(loaded_key)) orelse return).asTable() orelse return;

    // Standard library names to register
    const lib_names = [_][]const u8{
        "string", "math", "table", "io", "os", "debug", "utf8", "coroutine", "package",
    };

    for (lib_names) |name| {
        const key = try gc.allocString(name);
        if (globals.get(TValue.fromString(key))) |lib_val| {
            try object.tableSetWithBarrier(gc, loaded_table, TValue.fromString(key), lib_val);
        }
    }

    // Also register _G as the loaded base library (for compat)
    const g_key = try gc.allocString("_G");
    try object.tableSetWithBarrier(gc, loaded_table, TValue.fromString(g_key), TValue.fromTable(globals));
}

/// Global Functions: print, assert, error, type, tostring, collectgarbage, etc.
fn initGlobalFunctions(globals: *TableObject, gc: *GC) !void {
    // Dispatcher-backed global functions.
    const global_entries = [_]BuiltinEntry{
        .{ .name = "print", .id = .print },
        .{ .name = "tostring", .id = .tostring },
        .{ .name = "assert", .id = .assert },
        .{ .name = "error", .id = .lua_error },
        .{ .name = "collectgarbage", .id = .collectgarbage },
        .{ .name = "type", .id = .lua_type },
        .{ .name = "pcall", .id = .pcall },
        .{ .name = "xpcall", .id = .xpcall },
        .{ .name = "next", .id = .next },
        .{ .name = "pairs", .id = .pairs },
        .{ .name = "ipairs", .id = .ipairs },
        .{ .name = "getmetatable", .id = .getmetatable },
        .{ .name = "setmetatable", .id = .setmetatable },
        .{ .name = "rawget", .id = .rawget },
        .{ .name = "rawset", .id = .rawset },
        .{ .name = "rawlen", .id = .rawlen },
        .{ .name = "rawequal", .id = .rawequal },
        .{ .name = "select", .id = .select },
        .{ .name = "tonumber", .id = .tonumber },
        .{ .name = "load", .id = .load },
        .{ .name = "loadfile", .id = .loadfile },
        .{ .name = "warn", .id = .warn },
    };
    try registerEntries(globals, gc, &global_entries);

    // Wrapper-only globals and fixed global bindings.
    try registerLuaDofileWrapper(globals, gc);

    // _G and _ENV are self-references to the globals table itself
    try setStringKey(globals, gc, "_G", TValue.fromTable(globals));
    try setStringKey(globals, gc, "_ENV", TValue.fromTable(globals));
    // _VERSION is a version string constant
    const version_str = try gc.allocString(ver.lua_version);
    try setStringKey(globals, gc, "_VERSION", TValue.fromString(version_str));
}

/// String Library: string.len, string.sub, etc. (skeleton implementations)
fn initStringLibrary(globals: *TableObject, gc: *GC) !void {
    const string_table = try gc.allocTable();

    // Dispatcher-backed string functions.
    const string_entries = [_]BuiltinEntry{
        .{ .name = "len", .id = .string_len },
        .{ .name = "sub", .id = .string_sub },
        .{ .name = "upper", .id = .string_upper },
        .{ .name = "lower", .id = .string_lower },
        .{ .name = "byte", .id = .string_byte },
        .{ .name = "char", .id = .string_char },
        .{ .name = "rep", .id = .string_rep },
        .{ .name = "reverse", .id = .string_reverse },
        .{ .name = "find", .id = .string_find },
        .{ .name = "match", .id = .string_match },
        .{ .name = "gmatch", .id = .string_gmatch },
        .{ .name = "gsub", .id = .string_gsub },
        .{ .name = "format", .id = .string_format },
        .{ .name = "dump", .id = .string_dump },
        .{ .name = "pack", .id = .string_pack },
        .{ .name = "unpack", .id = .string_unpack },
        .{ .name = "packsize", .id = .string_packsize },
    };
    try registerEntries(string_table, gc, &string_entries);

    // Public library table and shared string metatable.
    try setStringKey(globals, gc, "string", TValue.fromTable(string_table));

    // Set shared string metatable so "str:method(...)" works.
    const string_mt = try gc.allocTable();
    try object.tableSetWithBarrier(gc, string_mt, TValue.fromString(gc.mm_keys.get(.index)), TValue.fromTable(string_table));
    gc.shared_mt.string = string_mt;
}

/// IO Library: io.write, io.open, etc. (skeleton implementations)
fn initIOLibrary(globals: *TableObject, gc: *GC) !void {
    const io_table = try gc.allocTable();

    // Dispatcher-backed io functions.
    const io_entries = [_]BuiltinEntry{
        .{ .name = "write", .id = .io_write },
        .{ .name = "close", .id = .io_close },
        .{ .name = "flush", .id = .io_flush },
        .{ .name = "input", .id = .io_input },
        .{ .name = "lines", .id = .io_lines },
        .{ .name = "open", .id = .io_open },
        .{ .name = "output", .id = .io_output },
        .{ .name = "popen", .id = .io_popen },
        .{ .name = "read", .id = .io_read },
        .{ .name = "tmpfile", .id = .io_tmpfile },
        .{ .name = "type", .id = .io_type },
    };
    try registerEntries(io_table, gc, &io_entries);

    // Stdio handles are initialized separately from dispatcher registration.
    try io.initStdioHandles(io_table, gc);

    try setStringKey(globals, gc, "io", TValue.fromTable(io_table));
}

/// Math Library: math.abs, math.ceil, etc. (skeleton implementations)
fn initMathLibrary(globals: *TableObject, gc: *GC) !void {
    const math_table = try gc.allocTable();

    // Exported math constants remain explicit.
    try setStringKey(math_table, gc, "pi", .{ .number = math.MATH_PI });
    try setStringKey(math_table, gc, "huge", .{ .number = math.MATH_HUGE });
    try setStringKey(math_table, gc, "maxinteger", .{ .integer = math.MATH_MAXINTEGER });
    try setStringKey(math_table, gc, "mininteger", .{ .integer = math.MATH_MININTEGER });

    // Dispatcher-backed math functions.
    const math_entries = [_]BuiltinEntry{
        .{ .name = "abs", .id = .math_abs },
        .{ .name = "acos", .id = .math_acos },
        .{ .name = "asin", .id = .math_asin },
        .{ .name = "atan", .id = .math_atan },
        .{ .name = "ceil", .id = .math_ceil },
        .{ .name = "cos", .id = .math_cos },
        .{ .name = "deg", .id = .math_deg },
        .{ .name = "exp", .id = .math_exp },
        .{ .name = "floor", .id = .math_floor },
        .{ .name = "fmod", .id = .math_fmod },
        .{ .name = "log", .id = .math_log },
        .{ .name = "max", .id = .math_max },
        .{ .name = "min", .id = .math_min },
        .{ .name = "modf", .id = .math_modf },
        .{ .name = "rad", .id = .math_rad },
        .{ .name = "random", .id = .math_random },
        .{ .name = "randomseed", .id = .math_randomseed },
        .{ .name = "sin", .id = .math_sin },
        .{ .name = "sqrt", .id = .math_sqrt },
        .{ .name = "tan", .id = .math_tan },
        .{ .name = "tointeger", .id = .math_tointeger },
        .{ .name = "type", .id = .math_type },
        .{ .name = "ult", .id = .math_ult },
    };
    try registerEntries(math_table, gc, &math_entries);

    try setStringKey(globals, gc, "math", TValue.fromTable(math_table));
}

/// Table Library: table.insert, table.remove, etc. (skeleton implementations)
fn initTableLibrary(globals: *TableObject, gc: *GC) !void {
    const table_table = try gc.allocTable();

    // Dispatcher-backed table functions.
    const table_entries = [_]BuiltinEntry{
        .{ .name = "insert", .id = .table_insert },
        .{ .name = "remove", .id = .table_remove },
        .{ .name = "sort", .id = .table_sort },
        .{ .name = "concat", .id = .table_concat },
        .{ .name = "move", .id = .table_move },
        .{ .name = "pack", .id = .table_pack },
        .{ .name = "unpack", .id = .table_unpack },
    };
    try registerEntries(table_table, gc, &table_entries);

    try setStringKey(globals, gc, "table", TValue.fromTable(table_table));
}

/// OS Library: os.clock, os.date, etc. (skeleton implementations)
fn initOSLibrary(globals: *TableObject, gc: *GC) !void {
    const os_table = try gc.allocTable();

    // Dispatcher-backed os functions.
    const os_entries = [_]BuiltinEntry{
        .{ .name = "clock", .id = .os_clock },
        .{ .name = "date", .id = .os_date },
        .{ .name = "difftime", .id = .os_difftime },
        .{ .name = "execute", .id = .os_execute },
        .{ .name = "exit", .id = .os_exit },
        .{ .name = "getenv", .id = .os_getenv },
        .{ .name = "remove", .id = .os_remove },
        .{ .name = "rename", .id = .os_rename },
        .{ .name = "setlocale", .id = .os_setlocale },
        .{ .name = "time", .id = .os_time },
        .{ .name = "tmpname", .id = .os_tmpname },
    };
    try registerEntries(os_table, gc, &os_entries);

    try setStringKey(globals, gc, "os", TValue.fromTable(os_table));
}

/// Debug Library: debug.debug, debug.getinfo, etc. (skeleton implementations)
fn initDebugLibrary(globals: *TableObject, gc: *GC) !void {
    const debug_table = try gc.allocTable();

    // Dispatcher-backed debug functions.
    const debug_entries = [_]BuiltinEntry{
        .{ .name = "debug", .id = .debug_debug },
        .{ .name = "gethook", .id = .debug_gethook },
        .{ .name = "getinfo", .id = .debug_getinfo },
        .{ .name = "getlocal", .id = .debug_getlocal },
        .{ .name = "getmetatable", .id = .debug_getmetatable },
        .{ .name = "getregistry", .id = .debug_getregistry },
        .{ .name = "getupvalue", .id = .debug_getupvalue },
        .{ .name = "getuservalue", .id = .debug_getuservalue },
        .{ .name = "newuserdata", .id = .debug_newuserdata },
        .{ .name = "sethook", .id = .debug_sethook },
        .{ .name = "setlocal", .id = .debug_setlocal },
        .{ .name = "setmetatable", .id = .debug_setmetatable },
        .{ .name = "setupvalue", .id = .debug_setupvalue },
        .{ .name = "setuservalue", .id = .debug_setuservalue },
        .{ .name = "traceback", .id = .debug_traceback },
        .{ .name = "upvalueid", .id = .debug_upvalueid },
        .{ .name = "upvaluejoin", .id = .debug_upvaluejoin },
    };
    try registerEntries(debug_table, gc, &debug_entries);

    try setStringKey(globals, gc, "debug", TValue.fromTable(debug_table));
}

/// UTF-8 Library: utf8.char, utf8.len, etc. (skeleton implementations)
fn initUtf8Library(globals: *TableObject, gc: *GC) !void {
    const utf8_table = try gc.allocTable();

    // Exported utf8 constants remain explicit.
    const charpattern_str = try gc.allocString(utf8.UTF8_CHARPATTERN);
    try setStringKey(utf8_table, gc, "charpattern", TValue.fromString(charpattern_str));

    // Dispatcher-backed utf8 functions.
    const utf8_entries = [_]BuiltinEntry{
        .{ .name = "char", .id = .utf8_char },
        .{ .name = "codes", .id = .utf8_codes },
        .{ .name = "codepoint", .id = .utf8_codepoint },
        .{ .name = "len", .id = .utf8_len },
        .{ .name = "offset", .id = .utf8_offset },
    };
    try registerEntries(utf8_table, gc, &utf8_entries);

    try setStringKey(globals, gc, "utf8", TValue.fromTable(utf8_table));
}

/// Coroutine Library: coroutine.create, coroutine.resume, etc. (skeleton implementations)
fn initCoroutineLibrary(globals: *TableObject, gc: *GC) !void {
    const coroutine_table = try gc.allocTable();

    // Dispatcher-backed coroutine functions.
    const coroutine_entries = [_]BuiltinEntry{
        .{ .name = "create", .id = .coroutine_create },
        .{ .name = "resume", .id = .coroutine_resume },
        .{ .name = "running", .id = .coroutine_running },
        .{ .name = "status", .id = .coroutine_status },
        .{ .name = "wrap", .id = .coroutine_wrap },
        .{ .name = "yield", .id = .coroutine_yield },
        .{ .name = "isyieldable", .id = .coroutine_isyieldable },
        .{ .name = "close", .id = .coroutine_close },
    };
    try registerEntries(coroutine_table, gc, &coroutine_entries);

    try setStringKey(globals, gc, "coroutine", TValue.fromTable(coroutine_table));
}

/// Module System: require, package.loadlib, package.searchpath (skeleton implementations)
fn initModuleSystem(globals: *TableObject, gc: *GC) !void {
    // Global require entrypoint is registered separately from the package table.
    try registerNative(globals, gc, "require", .require);

    // Package table for module system.
    const package_table = try gc.allocTable();

    // Dispatcher-backed package functions.
    const package_entries = [_]BuiltinEntry{
        .{ .name = "loadlib", .id = .package_loadlib },
        .{ .name = "searchpath", .id = .package_searchpath },
    };
    try registerEntries(package_table, gc, &package_entries);

    // Static package fields remain explicit.
    const config_str = try gc.allocString("/\n;\n?\n!\n-");
    try setStringKey(package_table, gc, "config", TValue.fromString(config_str));

    const path_str = try gc.allocString("./?.lua;./?/init.lua;/usr/local/share/lua/5.4/?.lua;/usr/local/share/lua/5.4/?/init.lua");
    try setStringKey(package_table, gc, "path", TValue.fromString(path_str));

    const cpath_str = try gc.allocString("./?.so;/usr/local/lib/lua/5.4/?.so");
    try setStringKey(package_table, gc, "cpath", TValue.fromString(cpath_str));

    // Mutable package state tables remain explicit.
    const loaded_table = try gc.allocTable();
    try setStringKey(package_table, gc, "loaded", TValue.fromTable(loaded_table));

    const preload_table = try gc.allocTable();
    try setStringKey(package_table, gc, "preload", TValue.fromTable(preload_table));

    const searchers_table = try gc.allocTable();
    try setStringKey(package_table, gc, "searchers", TValue.fromTable(searchers_table));

    // Stable internal reference used by require even if global "package" is reassigned.
    try setStringKey(globals, gc, "__moonquakes_package", TValue.fromTable(package_table));
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
        .io_lines_unreadable_iterator => try io.nativeIoLinesUnreadableIterator(vm, func_reg, nargs, nresults),
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
        .coroutine_wrap_call => try coroutine.nativeCoroutineWrapCall(vm, func_reg, nargs, nresults),
        .coroutine_yield => try coroutine.nativeCoroutineYield(vm, func_reg, nargs, nresults),
        .coroutine_isyieldable => try coroutine.nativeCoroutineIsYieldable(vm, func_reg, nargs, nresults),
        .coroutine_close => try coroutine.nativeCoroutineClose(vm, func_reg, nargs, nresults),

        // Module System (skeleton implementations)
        .require => try modules.nativeRequire(vm, func_reg, nargs, nresults),
        .package_loadlib => try modules.nativePackageLoadlib(vm, func_reg, nargs, nresults),
        .package_searchpath => try modules.nativePackageSearchpath(vm, func_reg, nargs, nresults),
    }
}
