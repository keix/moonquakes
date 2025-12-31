const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Lua 5.4 Table Library
/// Corresponds to Lua manual chapter "Table Manipulation"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.6
/// table.insert(list, [pos,] value) - Inserts element into table
pub fn nativeTableInsert(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement table.insert
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
