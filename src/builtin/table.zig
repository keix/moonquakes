const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const TableObject = object.TableObject;

/// Lua 5.4 Table Library
/// Corresponds to Lua manual chapter "Table Manipulation"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.6
/// Helper: Get the length of a table (count sequential integer keys from 1)
fn getTableLength(table: *TableObject, vm: anytype) i64 {
    var len: i64 = 0;
    var key_buffer: [32]u8 = undefined;
    while (true) {
        const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{len + 1}) catch break;
        const key = vm.gc.allocString(key_slice) catch break;
        if (table.get(key) == null) break;
        len += 1;
    }
    return len;
}

/// Helper: Get string key for an integer index
fn getIntKey(vm: anytype, index: i64) !*object.StringObject {
    var key_buffer: [32]u8 = undefined;
    const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{index}) catch return error.FormatError;
    return vm.gc.allocString(key_slice);
}

/// table.insert(list, [pos,] value) - Inserts element into table
pub fn nativeTableInsert(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    if (nargs < 2) return error.BadArgument;

    // First argument must be a table
    const tbl_arg = vm.stack[vm.base + func_reg + 1];
    const table = tbl_arg.asTable() orelse return error.BadArgument;

    const len = getTableLength(table, vm);

    if (nargs == 2) {
        // table.insert(list, value): insert at end
        const value = vm.stack[vm.base + func_reg + 2];
        const key = try getIntKey(vm, len + 1);
        try table.set(key, value);
    } else {
        // table.insert(list, pos, value): insert at pos, shift elements
        const pos_arg = vm.stack[vm.base + func_reg + 2];
        const pos = pos_arg.toInteger() orelse return error.BadArgument;
        const value = vm.stack[vm.base + func_reg + 3];

        if (pos < 1 or pos > len + 1) return error.BadArgument;

        // Shift elements from len down to pos
        var i: i64 = len;
        while (i >= pos) : (i -= 1) {
            const src_key = try getIntKey(vm, i);
            const dst_key = try getIntKey(vm, i + 1);
            const val = table.get(src_key) orelse .nil;
            try table.set(dst_key, val);
        }

        // Insert the new value at pos
        const key = try getIntKey(vm, pos);
        try table.set(key, value);
    }

    // table.insert returns nothing
}

/// table.remove(list [, pos]) - Removes element from table
pub fn nativeTableRemove(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement table.remove
}

/// table.sort(list [, comp]) - Sorts table elements in-place
pub fn nativeTableSort(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement table.sort
}

/// table.concat(list [, sep [, start [, end]]]) - Concatenates table elements
pub fn nativeTableConcat(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement table.concat
}

/// table.move(a1, f, e, t [, a2]) - Moves elements between arrays
pub fn nativeTableMove(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement table.move
}

/// table.pack(...) - Returns a new table with all arguments stored into keys 1, 2, etc.
pub fn nativeTablePack(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement table.pack
}

/// table.unpack(list [, i [, j]]) - Unpacks table elements as multiple return values
pub fn nativeTableUnpack(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement table.unpack
}
