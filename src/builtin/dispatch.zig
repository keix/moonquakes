const std = @import("std");
const Table = @import("../runtime/table.zig").Table;
const Function = @import("../runtime/function.zig").Function;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const TValue = @import("../runtime/value.zig").TValue;

// Builtin library modules - organized by Lua manual chapters
const string = @import("string.zig");
const io = @import("io.zig");
const global = @import("global.zig");
const error_handling = @import("error.zig");
const math = @import("math.zig");
const table = @import("table.zig");
const utf8 = @import("utf8.zig");

/// Initialize the global environment with all Lua standard libraries
/// Organized by Lua manual chapters for maintainability
pub fn initGlobalEnvironment(globals: *Table, allocator: std.mem.Allocator) !void {
    // Global Functions (Chapter 6.1)
    try initGlobalFunctions(globals);

    // IO Library (Chapter 6.8)
    try initIOLibrary(globals, allocator);

    // Math Library (Chapter 6.7) - skeleton
    try initMathLibrary(globals, allocator);

    // Table Library (Chapter 6.6) - skeleton
    try initTableLibrary(globals, allocator);

    // UTF-8 Support (Chapter 6.5) - skeleton
    try initUtf8Library(globals, allocator);
}

/// Global Functions: print, assert, error, type, tostring, collectgarbage
fn initGlobalFunctions(globals: *Table) !void {
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
}

/// IO Library: io.write (more functions can be added later)
fn initIOLibrary(globals: *Table, allocator: std.mem.Allocator) !void {
    var io_table = try allocator.create(Table);
    io_table.* = Table.init(allocator);

    const io_write_fn = Function{ .native = .{ .id = NativeFnId.io_write } };
    try io_table.set("write", .{ .function = io_write_fn });

    try globals.set("io", .{ .table = io_table });
}

/// Math Library: math.abs, math.ceil, etc. (skeleton implementations)
fn initMathLibrary(globals: *Table, allocator: std.mem.Allocator) !void {
    var math_table = try allocator.create(Table);
    math_table.* = Table.init(allocator);

    // Math constants
    try math_table.set("pi", .{ .number = math.MATH_PI });
    try math_table.set("huge", .{ .number = math.MATH_HUGE });

    // Math functions (skeleton)
    const abs_fn = Function{ .native = .{ .id = NativeFnId.math_abs } };
    try math_table.set("abs", .{ .function = abs_fn });

    const ceil_fn = Function{ .native = .{ .id = NativeFnId.math_ceil } };
    try math_table.set("ceil", .{ .function = ceil_fn });

    const floor_fn = Function{ .native = .{ .id = NativeFnId.math_floor } };
    try math_table.set("floor", .{ .function = floor_fn });

    const max_fn = Function{ .native = .{ .id = NativeFnId.math_max } };
    try math_table.set("max", .{ .function = max_fn });

    const min_fn = Function{ .native = .{ .id = NativeFnId.math_min } };
    try math_table.set("min", .{ .function = min_fn });

    const sqrt_fn = Function{ .native = .{ .id = NativeFnId.math_sqrt } };
    try math_table.set("sqrt", .{ .function = sqrt_fn });

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

/// UTF-8 Library: utf8.char, utf8.len, etc. (skeleton implementations)
fn initUtf8Library(globals: *Table, allocator: std.mem.Allocator) !void {
    var utf8_table = try allocator.create(Table);
    utf8_table.* = Table.init(allocator);

    // UTF-8 pattern constant
    try utf8_table.set("charpattern", .{ .string = utf8.UTF8_CHARPATTERN });

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

/// Dispatch native function calls to appropriate implementations
/// Organized by library for maintainability
pub fn invoke(id: NativeFnId, vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    switch (id) {
        // Global Functions
        .print => try global.nativePrint(vm, func_reg, nargs, nresults),
        .tostring => try string.nativeToString(vm, func_reg, nargs, nresults),
        .assert => try error_handling.nativeAssert(vm, func_reg, nargs, nresults),
        .lua_error => try error_handling.nativeError(vm, func_reg, nargs, nresults),
        .collectgarbage => try error_handling.nativeCollectGarbage(vm, func_reg, nargs, nresults),

        // IO Library
        .io_write => try io.nativeIoWrite(vm, func_reg, nargs, nresults),

        // Math Library (skeleton implementations)
        .math_abs => try math.nativeMathAbs(vm, func_reg, nargs, nresults),
        .math_ceil => try math.nativeMathCeil(vm, func_reg, nargs, nresults),
        .math_floor => try math.nativeMathFloor(vm, func_reg, nargs, nresults),
        .math_max => try math.nativeMathMax(vm, func_reg, nargs, nresults),
        .math_min => try math.nativeMathMin(vm, func_reg, nargs, nresults),
        .math_sqrt => try math.nativeMathSqrt(vm, func_reg, nargs, nresults),

        // Table Library (skeleton implementations)
        .table_insert => try table.nativeTableInsert(vm, func_reg, nargs, nresults),
        .table_remove => try table.nativeTableRemove(vm, func_reg, nargs, nresults),
        .table_sort => try table.nativeTableSort(vm, func_reg, nargs, nresults),
        .table_concat => try table.nativeTableConcat(vm, func_reg, nargs, nresults),
        .table_move => try table.nativeTableMove(vm, func_reg, nargs, nresults),
        .table_pack => try table.nativeTablePack(vm, func_reg, nargs, nresults),
        .table_unpack => try table.nativeTableUnpack(vm, func_reg, nargs, nresults),

        // UTF-8 Library (skeleton implementations)
        .utf8_char => try utf8.nativeUtf8Char(vm, func_reg, nargs, nresults),
        .utf8_codes => try utf8.nativeUtf8Codes(vm, func_reg, nargs, nresults),
        .utf8_codepoint => try utf8.nativeUtf8Codepoint(vm, func_reg, nargs, nresults),
        .utf8_len => try utf8.nativeUtf8Len(vm, func_reg, nargs, nresults),
        .utf8_offset => try utf8.nativeUtf8Offset(vm, func_reg, nargs, nresults),
    }
}
