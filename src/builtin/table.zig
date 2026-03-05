const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const TableObject = object.TableObject;
const call = @import("../vm/call.zig");
const metamethod = @import("../vm/metamethod.zig");

/// Lua 5.4 Table Library
/// Corresponds to Lua manual chapter "Table Manipulation"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.6
/// Helper: Get the length of a table (count sequential integer keys from 1)
fn getTableLength(table: *TableObject) i64 {
    var len: i64 = 0;
    while (true) {
        const key = TValue{ .integer = len + 1 };
        const val = table.get(key) orelse break;
        // Also check if value is nil (key exists but value is nil)
        if (val == .nil) break;
        len += 1;
    }
    return len;
}

fn rawSetWithBarrier(vm: anytype, table: *TableObject, key: TValue, value: TValue) !void {
    try table.set(key, value);
    vm.gc().barrierBackValue(&table.header, value);
}

fn callValueManaged(vm: anytype, fn_val: TValue, args: []const TValue) !TValue {
    var pushed: u8 = 0;
    if (!vm.pushTempRoot(fn_val)) return error.OutOfMemory;
    pushed += 1;
    for (args) |arg| {
        if (!vm.pushTempRoot(arg)) {
            vm.popTempRoots(pushed);
            return error.OutOfMemory;
        }
        pushed += 1;
    }
    defer vm.popTempRoots(pushed);

    return call.callValueSafe(vm, fn_val, args) catch |err| switch (err) {
        call.CallError.NotCallable => vm.raiseString("attempt to call a non-function value"),
        else => err,
    };
}

fn getLengthMM(vm: anytype, table_val: TValue, table: *TableObject) !i64 {
    if (metamethod.getMetamethod(table_val, .len, &vm.gc().mm_keys, &vm.gc().shared_mt)) |len_mm| {
        const result = try callValueManaged(vm, len_mm, &[_]TValue{table_val});
        return result.toInteger() orelse vm.raiseString("'__len' must return an integer");
    }
    return getTableLength(table);
}

fn getAt(vm: anytype, table_val: TValue, table: *TableObject, key: TValue) !TValue {
    if (table.get(key)) |v| return v;
    if (metamethod.getMetamethod(table_val, .index, &vm.gc().mm_keys, &vm.gc().shared_mt)) |index_mm| {
        if (index_mm.asTable()) |index_table| {
            return index_table.get(key) orelse .nil;
        }
        return callValueManaged(vm, index_mm, &[_]TValue{ table_val, key });
    }
    return .nil;
}

fn setAt(vm: anytype, table_val: TValue, table: *TableObject, key: TValue, value: TValue) !void {
    if (table.get(key) != null) {
        return rawSetWithBarrier(vm, table, key, value);
    }
    if (metamethod.getMetamethod(table_val, .newindex, &vm.gc().mm_keys, &vm.gc().shared_mt)) |newindex_mm| {
        if (newindex_mm.asTable()) |newindex_table| {
            return rawSetWithBarrier(vm, newindex_table, key, value);
        }
        _ = try callValueManaged(vm, newindex_mm, &[_]TValue{ table_val, key, value });
        return;
    }
    return rawSetWithBarrier(vm, table, key, value);
}

/// table.insert(list, [pos,] value) - Inserts element into table
pub fn nativeTableInsert(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    if (nargs < 2 or nargs > 3) return vm.raiseString("wrong number of arguments to 'insert'");

    // First argument must be a table
    const tbl_arg = vm.stack[vm.base + func_reg + 1];
    const table = tbl_arg.asTable() orelse return vm.raiseString("bad argument #1 to 'insert' (table expected)");

    const len = try getLengthMM(vm, tbl_arg, table);

    if (nargs == 2) {
        // table.insert(list, value): insert at end
        const value = vm.stack[vm.base + func_reg + 2];
        const key = TValue{ .integer = len + 1 };
        try setAt(vm, tbl_arg, table, key, value);
    } else {
        // table.insert(list, pos, value): insert at pos, shift elements
        const pos_arg = vm.stack[vm.base + func_reg + 2];
        const pos = pos_arg.toInteger() orelse return vm.raiseString("bad argument #2 to 'insert' (number expected)");
        const value = vm.stack[vm.base + func_reg + 3];

        if (pos < 1 or pos > len + 1) return vm.raiseString("position out of bounds");

        // Shift elements from len down to pos
        var i: i64 = len;
        while (i >= pos) : (i -= 1) {
            const src_key = TValue{ .integer = i };
            const dst_key = TValue{ .integer = i + 1 };
            const val = try getAt(vm, tbl_arg, table, src_key);
            try setAt(vm, tbl_arg, table, dst_key, val);
        }

        // Insert the new value at pos
        const key = TValue{ .integer = pos };
        try setAt(vm, tbl_arg, table, key, value);
    }

    // table.insert returns nothing
}

/// table.remove(list [, pos]) - Removes element from table
/// Returns the removed element. Default pos is #list (removes last element).
pub fn nativeTableRemove(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) return vm.raiseString("bad argument #1 to 'remove' (table expected)");
    if (nargs > 2) return vm.raiseString("wrong number of arguments to 'remove'");

    // First argument must be a table
    const tbl_arg = vm.stack[vm.base + func_reg + 1];
    const table = tbl_arg.asTable() orelse return vm.raiseString("bad argument #1 to 'remove' (table expected)");

    const len = try getLengthMM(vm, tbl_arg, table);

    // Determine position (default is last element)
    const pos: i64 = if (nargs >= 2) blk: {
        const pos_arg = vm.stack[vm.base + func_reg + 2];
        break :blk pos_arg.toInteger() orelse return vm.raiseString("bad argument #2 to 'remove' (number expected)");
    } else len;

    // Lua compatibility for empty tables:
    // - table.remove(t) removes key 0 (because default pos is #t, which is 0)
    // - table.remove(t, 0) returns nil
    if (len == 0) {
        if (nargs < 2) {
            const zero_key = TValue{ .integer = 0 };
            const removed_value = try getAt(vm, tbl_arg, table, zero_key);
            try setAt(vm, tbl_arg, table, zero_key, .nil);
            if (nresults > 0) {
                vm.stack[vm.base + func_reg] = removed_value;
            }
            return;
        }
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = .nil;
        }
        return;
    }

    // Non-empty list behavior:
    // - pos < 1: error
    // - pos > len: return nil
    if (pos < 1) {
        return vm.raiseString("position out of bounds");
    }
    if (pos > len) {
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = .nil;
        }
        return;
    }

    // Get the element to remove (to return it)
    const remove_key = TValue{ .integer = pos };
    const removed_value = try getAt(vm, tbl_arg, table, remove_key);

    // Shift elements down from pos+1 to len
    var i: i64 = pos;
    while (i < len) : (i += 1) {
        const src_key = TValue{ .integer = i + 1 };
        const dst_key = TValue{ .integer = i };
        const val = try getAt(vm, tbl_arg, table, src_key);
        try setAt(vm, tbl_arg, table, dst_key, val);
    }

    // Remove the last element (now duplicated)
    const last_key = TValue{ .integer = len };
    try setAt(vm, tbl_arg, table, last_key, .nil);

    // Return the removed value
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = removed_value;
    }
}

/// table.sort(list [, comp]) - Sorts table elements in-place
/// Uses < operator by default. Implements insertion sort for simplicity.
/// If comp is provided, it must be a function that takes two arguments
/// and returns true if the first argument should come before the second.
pub fn nativeTableSort(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    if (nargs < 1) return error.BadArgument;

    // First argument must be a table
    const tbl_arg = vm.stack[vm.base + func_reg + 1];
    const table = tbl_arg.asTable() orelse return error.BadArgument;

    // Get optional comparator function
    const comp: ?TValue = if (nargs >= 2) blk: {
        const comp_arg = vm.stack[vm.base + func_reg + 2];
        // Verify it's callable
        if (comp_arg.asClosure() != null or comp_arg.asNativeClosure() != null) {
            break :blk comp_arg;
        }
        if (!comp_arg.isNil()) {
            return error.BadArgument; // comp must be function or nil
        }
        break :blk null;
    } else null;

    const len = try getLengthMM(vm, tbl_arg, table);
    if (len <= 1) return; // Already sorted

    // Collect all elements into a temporary array
    const allocator = vm.gc().allocator;
    var elements = try std.ArrayList(TValue).initCapacity(allocator, @intCast(len));
    defer elements.deinit(allocator);

    var i: i64 = 1;
    while (i <= len) : (i += 1) {
        const key = TValue{ .integer = i };
        const val = try getAt(vm, tbl_arg, table, key);
        elements.appendAssumeCapacity(val);
    }

    // Insertion sort
    var j: usize = 1;
    while (j < elements.items.len) : (j += 1) {
        const current = elements.items[j];
        var k: usize = j;

        while (k > 0) {
            const prev = elements.items[k - 1];

            // Compare: is prev > current? (need to swap)
            const should_swap = try compareForSort(vm, prev, current, comp);

            if (should_swap) {
                elements.items[k] = prev;
                k -= 1;
            } else {
                break;
            }
        }

        elements.items[k] = current;
    }

    // Write sorted elements back to table
    i = 1;
    for (elements.items) |val| {
        const key = TValue{ .integer = i };
        try setAt(vm, tbl_arg, table, key, val);
        i += 1;
    }

    // table.sort returns nothing
}

/// Compare two values for sorting.
/// Returns true if `a` should come AFTER `b` (i.e., need to swap).
/// With custom comparator: returns true if NOT comp(a, b) AND comp(b, a)
/// Default: returns true if a > b
fn compareForSort(vm: anytype, a: TValue, b: TValue, comp: ?TValue) !bool {
    if (comp) |comp_fn| {
        // Call comparator with (a, b) - returns true if a < b
        var args: [2]TValue = .{ a, b };
        const result = call.callValueSafe(vm, comp_fn, &args) catch |err| {
            if (err == call.CallError.NotCallable) return false;
            return err;
        };

        // If comp(a, b) is true, a should come before b, so don't swap
        if (result.isBoolean() and result.boolean) {
            return false;
        }

        // comp(a, b) is false or nil
        // For stable sort behavior, only swap if comp(b, a) is true
        args = .{ b, a };
        const reverse = call.callValueSafe(vm, comp_fn, &args) catch |err| {
            if (err == call.CallError.NotCallable) return false;
            return err;
        };

        return reverse.isBoolean() and reverse.boolean;
    } else {
        // Default comparison: a > b means swap
        // Compare numbers
        if (a.toNumber()) |a_num| {
            if (b.toNumber()) |b_num| {
                return a_num > b_num;
            }
        }
        // Compare strings
        if (a.asString()) |a_str| {
            if (b.asString()) |b_str| {
                const cmp = std.mem.order(u8, a_str.asSlice(), b_str.asSlice());
                return cmp == .gt;
            }
        }
        // Mixed types or incomparable - don't swap
        return false;
    }
}

/// table.concat(list [, sep [, start [, end]]]) - Concatenates table elements
/// Returns a string with all string/number elements joined by separator.
pub fn nativeTableConcat(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) return vm.raiseString("bad argument #1 to 'concat' (table expected)");

    // First argument must be a table
    const tbl_arg = vm.stack[vm.base + func_reg + 1];
    const table = tbl_arg.asTable() orelse return vm.raiseString("bad argument #1 to 'concat' (table expected)");

    const len = try getLengthMM(vm, tbl_arg, table);

    // Get separator (default empty string)
    const sep: []const u8 = if (nargs >= 2) blk: {
        const sep_arg = vm.stack[vm.base + func_reg + 2];
        if (sep_arg.asString()) |s| {
            break :blk s.asSlice();
        } else {
            break :blk "";
        }
    } else "";

    // Get start index (default 1)
    const start: i64 = if (nargs >= 3) blk: {
        const start_arg = vm.stack[vm.base + func_reg + 3];
        break :blk start_arg.toInteger() orelse 1;
    } else 1;

    // Get end index (default #list)
    const end: i64 = if (nargs >= 4) blk: {
        const end_arg = vm.stack[vm.base + func_reg + 4];
        break :blk end_arg.toInteger() orelse len;
    } else len;

    // Handle empty range
    if (start > end) {
        const empty = vm.gc().allocString("") catch {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        vm.stack[vm.base + func_reg] = TValue.fromString(empty);
        return;
    }

    // Build result string
    const allocator = vm.gc().allocator;
    var result = std.ArrayList(u8).initCapacity(allocator, 256) catch {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    defer result.deinit(allocator);

    var i: i64 = start;
    while (i <= end) : (i += 1) {
        if (i > start) {
            result.appendSlice(allocator, sep) catch {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            };
        }

        const key = TValue{ .integer = i };
        const val = try getAt(vm, tbl_arg, table, key);

        // Convert value to string
        if (val.asString()) |s| {
            result.appendSlice(allocator, s.asSlice()) catch {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            };
        } else if (val.toInteger()) |int_val| {
            var buf: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{int_val}) catch {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            };
            result.appendSlice(allocator, slice) catch {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            };
        } else if (val.toNumber()) |num_val| {
            var buf: [64]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{num_val}) catch {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            };
            result.appendSlice(allocator, slice) catch {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            };
        } else {
            // Non-string/number element - error in Lua
            var msg_buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "invalid value at index {d}", .{i}) catch "invalid value";
            return vm.raiseString(msg);
        }
    }

    // Allocate result string
    const result_str = vm.gc().allocString(result.items) catch {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    vm.stack[vm.base + func_reg] = TValue.fromString(result_str);
}

/// table.move(a1, f, e, t [, a2]) - Moves elements between arrays
/// Moves elements from a1[f..e] to a2[t..]. Returns a2.
/// If a2 is not given, uses a1.
pub fn nativeTableMove(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 4) return error.BadArgument;

    // Source table (a1)
    const src_arg = vm.stack[vm.base + func_reg + 1];
    const src_table = src_arg.asTable() orelse return error.BadArgument;

    // Source range: f to e
    const f_arg = vm.stack[vm.base + func_reg + 2];
    const f = f_arg.toInteger() orelse return error.BadArgument;

    const e_arg = vm.stack[vm.base + func_reg + 3];
    const e = e_arg.toInteger() orelse return error.BadArgument;

    // Target start position
    const t_arg = vm.stack[vm.base + func_reg + 4];
    const t = t_arg.toInteger() orelse return error.BadArgument;

    // Destination table (a2, default is a1)
    const dst_table = if (nargs >= 5) blk: {
        const dst_arg = vm.stack[vm.base + func_reg + 5];
        break :blk dst_arg.asTable() orelse return error.BadArgument;
    } else src_table;

    // Handle empty range
    if (f > e) {
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = TValue.fromTable(dst_table);
        }
        return;
    }

    const count = e - f + 1;

    // Determine copy direction to handle overlapping regions
    if (t > f and src_table == dst_table) {
        // Copy backwards to avoid overwriting source before reading
        var i: i64 = count - 1;
        while (i >= 0) : (i -= 1) {
            const src_key = TValue{ .integer = f + i };
            const dst_key = TValue{ .integer = t + i };
            const val = src_table.get(src_key) orelse .nil;
            try dst_table.set(dst_key, val);
        }
    } else {
        // Copy forwards
        var i: i64 = 0;
        while (i < count) : (i += 1) {
            const src_key = TValue{ .integer = f + i };
            const dst_key = TValue{ .integer = t + i };
            const val = src_table.get(src_key) orelse .nil;
            try dst_table.set(dst_key, val);
        }
    }

    // Return the destination table
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromTable(dst_table);
    }
}

/// table.pack(...) - Returns a new table with all arguments stored into keys 1, 2, etc.
/// Also sets field "n" to the total number of arguments.
pub fn nativeTablePack(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    // Create a new table
    const table = try vm.gc().allocTable();

    // Store all arguments with integer keys starting from 1
    var i: u32 = 0;
    while (i < nargs) : (i += 1) {
        const val = vm.stack[vm.base + func_reg + 1 + i];
        const key = TValue{ .integer = @as(i64, i) + 1 };
        try table.set(key, val);
    }

    // Set the "n" field to the count of arguments
    const n_key = try vm.gc().allocString("n");
    try table.set(TValue.fromString(n_key), .{ .integer = @intCast(nargs) });

    // Return the table
    vm.stack[vm.base + func_reg] = TValue.fromTable(table);
}

/// table.unpack(list [, i [, j]]) - Unpacks table elements as multiple return values
/// Returns list[i], list[i+1], ..., list[j]. Default i=1, j=#list.
pub fn nativeTableUnpack(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) return error.BadArgument;

    // First argument must be a table
    const tbl_arg = vm.stack[vm.base + func_reg + 1];
    const table = tbl_arg.asTable() orelse return error.BadArgument;

    const len = try getLengthMM(vm, tbl_arg, table);

    // Get start index (default 1)
    const start: i64 = if (nargs >= 2) blk: {
        const start_arg = vm.stack[vm.base + func_reg + 2];
        break :blk start_arg.toInteger() orelse 1;
    } else 1;

    // Get end index (default #list)
    const end: i64 = if (nargs >= 3) blk: {
        const end_arg = vm.stack[vm.base + func_reg + 3];
        break :blk end_arg.toInteger() orelse len;
    } else len;

    // Calculate how many values to return
    const count: u32 = if (end >= start) @intCast(end - start + 1) else 0;

    // Limit by nresults if fixed
    const actual_count: u32 = if (nresults > 0) @min(count, nresults) else count;

    // Store values in result registers
    var i: u32 = 0;
    while (i < actual_count) : (i += 1) {
        const key = TValue{ .integer = start + @as(i64, i) };
        const val = try getAt(vm, tbl_arg, table, key);
        vm.stack[vm.base + func_reg + i] = val;
    }

    // Fill remaining result slots with nil if needed
    if (nresults > 0) {
        var j: u32 = actual_count;
        while (j < nresults) : (j += 1) {
            vm.stack[vm.base + func_reg + j] = .nil;
        }
    }

    vm.top = if (nresults > 0)
        vm.base + func_reg + nresults
    else
        vm.base + func_reg + actual_count;
}
