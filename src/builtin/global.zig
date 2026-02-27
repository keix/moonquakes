const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const string = @import("string.zig");
const call = @import("../vm/call.zig");
const pipeline = @import("../compiler/pipeline.zig");
const metamethod = @import("../vm/metamethod.zig");

/// Lua 5.4 Global Functions (Basic Functions)
/// Corresponds to Lua manual chapter "Basic Functions"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.1
pub fn nativePrint(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    // Save original top to restore later
    const saved_top = vm.top;

    var i: u32 = 0;
    while (i < nargs) : (i += 1) {
        if (i > 0) {
            try stdout.writeAll("\t");
        }

        // Use temporary registers to avoid corrupting the stack
        const tmp_reg = vm.top;
        vm.top += 2; // Need 2 registers: argument at tmp_reg+1, result at tmp_reg

        // Copy argument to temporary register for tostring
        const arg_reg = func_reg + 1 + i;
        vm.stack[vm.base + tmp_reg + 1] = vm.stack[vm.base + arg_reg];

        // Call tostring with argument at tmp_reg+1, result at tmp_reg
        try string.nativeToString(vm, tmp_reg, 1, 1);

        // Get the string result from tostring
        const result = vm.stack[vm.base + tmp_reg];
        const str_val = result.asString() orelse unreachable; // tostring must return string

        try stdout.writeAll(str_val.asSlice());

        // Clean up temporary registers
        vm.top -= 2;
    }
    try stdout.writeAll("\n");

    // Restore original top to prevent stack growth
    vm.top = saved_top;

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue{ .nil = {} };
    }
}

/// type(v) - Returns the type of its only argument, coded as a string
pub fn nativeType(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs == 0) {
        const type_name = try vm.gc().allocString("nil");
        vm.stack[vm.base + func_reg] = TValue.fromString(type_name);
        return;
    }

    const arg = vm.stack[vm.base + func_reg + 1];

    // Moonquakes represents file handles as tables internally; present them as userdata.
    if (arg.asTable()) |table| {
        const closed_key = try vm.gc().allocString("_closed");
        if (table.get(TValue.fromString(closed_key)) != null) {
            const type_name = try vm.gc().allocString("userdata");
            vm.stack[vm.base + func_reg] = TValue.fromString(type_name);
            return;
        }

        // Preserve Moonquakes extension: type() returns __name for tables with that metamethod.
        if (table.metatable) |mt| {
            if (mt.get(TValue.fromString(vm.gc().mm_keys.get(.name)))) |name_val| {
                if (name_val.asString()) |name_str| {
                    vm.stack[vm.base + func_reg] = TValue.fromString(name_str);
                    return;
                }
            }
        }
    }

    // Default type names
    const type_name_str: []const u8 = switch (arg) {
        .nil => "nil",
        .boolean => "boolean",
        .integer => "number",
        .number => "number",
        .object => |obj| switch (obj.type) {
            .string => "string",
            .table => "table",
            .closure, .native_closure => "function",
            .upvalue => "upvalue",
            .userdata => "userdata",
            .proto => "proto",
            .thread => "thread",
        },
    };

    const type_name = try vm.gc().allocString(type_name_str);
    vm.stack[vm.base + func_reg] = TValue.fromString(type_name);
}

/// pcall(f [, arg1, ...]) - Calls function f with given arguments in protected mode
/// Returns: (true, results...) on success, (false, error_value) on failure
pub fn nativePcall(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .{ .boolean = false };
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("bad argument #1 to 'pcall' (value expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    }

    const func_val = vm.stack[vm.base + func_reg + 1];

    // Build argument array
    const arg_count = if (nargs > 1) nargs - 1 else 0;
    var args: [256]TValue = undefined;
    for (0..arg_count) |i| {
        args[i] = vm.stack[vm.base + func_reg + 2 + @as(u32, @intCast(i))];
    }

    // Call in protected mode - only catch LuaException
    const result = call.callValue(vm, func_val, args[0..arg_count]);

    if (result) |ret_val| {
        // Success: return (true, result)
        vm.stack[vm.base + func_reg] = .{ .boolean = true };
        if (nresults > 1) {
            vm.stack[vm.base + func_reg + 1] = ret_val;
        }
    } else |err| switch (err) {
        error.LuaException => {
            // Lua error: return (false, error_value)
            vm.stack[vm.base + func_reg] = .{ .boolean = false };
            if (nresults > 1) {
                vm.stack[vm.base + func_reg + 1] = vm.lua_error_value;
            }
            // Always clear error value after handling
            vm.lua_error_value = .nil;
        },
        else => return err, // OOM etc. propagate up
    }
}

/// xpcall(f, msgh [, arg1, ...]) - Calls function f with error handler msgh
/// Returns: (true, results...) on success, (false, handler_result) on failure
pub fn nativeXpcall(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 2) {
        vm.stack[vm.base + func_reg] = .{ .boolean = false };
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("bad argument #2 to 'xpcall' (value expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    }

    const func_val = vm.stack[vm.base + func_reg + 1];
    const handler_val = vm.stack[vm.base + func_reg + 2];

    // Build argument array (arguments after the handler)
    const arg_count = if (nargs > 2) nargs - 2 else 0;
    var args: [256]TValue = undefined;
    for (0..arg_count) |i| {
        args[i] = vm.stack[vm.base + func_reg + 3 + @as(u32, @intCast(i))];
    }

    // Call in protected mode - only catch LuaException
    const result = call.callValue(vm, func_val, args[0..arg_count]);

    if (result) |ret_val| {
        // Success: return (true, result)
        vm.stack[vm.base + func_reg] = .{ .boolean = true };
        if (nresults > 1) {
            vm.stack[vm.base + func_reg + 1] = ret_val;
        }
    } else |err| switch (err) {
        error.LuaException => {
            // Get error value and call handler
            const error_value = vm.lua_error_value;
            vm.lua_error_value = .nil;

            // Call error handler with the error value
            var handler_args = [1]TValue{error_value};
            const handler_result = call.callValue(vm, handler_val, &handler_args) catch |handler_err| switch (handler_err) {
                error.LuaException => {
                    // Handler itself raised - return handler's error
                    vm.stack[vm.base + func_reg] = .{ .boolean = false };
                    if (nresults > 1) {
                        vm.stack[vm.base + func_reg + 1] = vm.lua_error_value;
                    }
                    vm.lua_error_value = .nil;
                    return;
                },
                else => return handler_err, // OOM etc. propagate up
            };

            // Return (false, handler_result)
            vm.stack[vm.base + func_reg] = .{ .boolean = false };
            if (nresults > 1) {
                vm.stack[vm.base + func_reg + 1] = handler_result;
            }
        },
        else => return err, // OOM etc. propagate up
    }
}

/// next(table [, index]) - Allows traversal of all fields of a table
pub fn nativeNext(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const table_arg = vm.stack[vm.base + func_reg + 1];
    const table = table_arg.asTable() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Get optional index (nil means start from beginning)
    const index_arg = if (nargs >= 2) vm.stack[vm.base + func_reg + 2] else TValue.nil;

    // Iterate through hash_part
    var iter = table.hash_part.iterator();
    var found_current = index_arg.isNil();

    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        if (found_current) {
            // Return this key-value pair (key is already TValue)
            vm.stack[vm.base + func_reg] = key;
            if (nresults > 1) {
                vm.stack[vm.base + func_reg + 1] = value;
            }
            return;
        }

        // Check if this is the current key (using TValue equality)
        if (key.eql(index_arg)) {
            found_current = true;
        }
    }

    // No more entries
    vm.stack[vm.base + func_reg] = .nil;
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = .nil;
    }
}

/// pairs(t) - Returns three values for iterating over table
/// If t has __pairs metamethod, calls it and returns its results
/// Otherwise returns: next function, table, nil (default behavior)
pub fn nativePairs(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const table_arg = vm.stack[vm.base + func_reg + 1];

    // Check for __pairs metamethod
    if (table_arg.asTable()) |table| {
        if (table.metatable) |mt| {
            if (mt.get(TValue.fromString(vm.gc().mm_keys.get(.pairs)))) |pairs_mm| {
                // Call __pairs(t) and return its results
                // __pairs should return (iterator, state, initial_key)
                const result = try call.callValue(vm, pairs_mm, &[_]TValue{table_arg});
                vm.stack[vm.base + func_reg] = result;
                // Note: callValue only returns first result
                // For full multi-return support, we'd need callValueMulti
                // For now, common usage is to return a single iterator function
                if (nresults > 1) vm.stack[vm.base + func_reg + 1] = table_arg;
                if (nresults > 2) vm.stack[vm.base + func_reg + 2] = .nil;
                return;
            }
        }
    }

    // Default behavior: return next, table, nil
    const next_nc = try vm.gc().allocNativeClosure(.{ .id = .next });
    vm.stack[vm.base + func_reg] = TValue.fromNativeClosure(next_nc);

    // Return the table
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = table_arg;
    }

    // Return nil as initial key
    if (nresults > 2) {
        vm.stack[vm.base + func_reg + 2] = .nil;
    }
}

/// ipairs(t) - Returns three values for iterating over array part of table
/// Returns iterator function, table, and 0 (initial index)
pub fn nativeIpairs(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const table_arg = vm.stack[vm.base + func_reg + 1];

    // Return ipairs_iterator function
    const iter_nc = try vm.gc().allocNativeClosure(.{ .id = .ipairs_iterator });
    vm.stack[vm.base + func_reg] = TValue.fromNativeClosure(iter_nc);

    // Return the table
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = table_arg;
    }

    // Return 0 as initial index
    if (nresults > 2) {
        vm.stack[vm.base + func_reg + 2] = .{ .integer = 0 };
    }
}

/// ipairs iterator - Returns (index+1, t[index+1]) or nil when done
pub fn nativeIpairsIterator(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 2) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const table_arg = vm.stack[vm.base + func_reg + 1];
    const index_arg = vm.stack[vm.base + func_reg + 2];

    const table = table_arg.asTable() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    const current_index = index_arg.toInteger() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    const next_index = current_index + 1;

    // Use integer key directly (Lua 5.4 supports any TValue as key)
    const key = TValue{ .integer = next_index };
    const value = table.get(key);

    if (value == null or value.?.isNil()) {
        // No more elements
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Return index and value
    vm.stack[vm.base + func_reg] = .{ .integer = next_index };
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = value.?;
    }
}

/// getmetatable(object) - Returns the metatable of the given object
/// If object has a metatable with __metatable field, returns that value
/// Otherwise returns the metatable, or nil if no metatable
/// Supports: tables (individual), userdata (individual), and primitives (shared)
pub fn nativeGetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const arg = vm.stack[vm.base + func_reg + 1];

    var result: TValue = .nil;

    // Use metamethod.getMetatable which handles both individual and shared metatables
    if (metamethod.getMetatable(arg, &vm.gc().shared_mt)) |mt| {
        // Check for __metatable field (protects metatable from modification/inspection)
        if (mt.get(TValue.fromString(vm.gc().mm_keys.get(.metatable)))) |protected| {
            result = protected;
        } else {
            result = TValue.fromTable(mt);
        }
    }

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
}

/// setmetatable(table, metatable) - Sets the metatable for the given table
/// Returns the table. Raises error if metatable has __metatable field (protected).
pub fn nativeSetmetatable(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const table_arg = vm.stack[vm.base + func_reg + 1];
    const mt_arg = vm.stack[vm.base + func_reg + 2];

    const table = table_arg.asTable() orelse {
        // setmetatable only works on tables
        return vm.raiseString("bad argument #1 to 'setmetatable' (table expected)");
    };

    // Check if current metatable is protected
    if (table.metatable) |current_mt| {
        if (current_mt.get(TValue.fromString(vm.gc().mm_keys.get(.metatable))) != null) {
            return vm.raiseString("cannot change a protected metatable");
        }
    }

    // Set the new metatable (nil clears it)
    if (mt_arg.isNil()) {
        table.metatable = null;
    } else if (mt_arg.asTable()) |new_mt| {
        table.metatable = new_mt;
    } else {
        return vm.raiseString("bad argument #2 to 'setmetatable' (nil or table expected)");
    }

    // Return the table
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = table_arg;
    }
}

/// rawget(table, index) - Gets the real value of table[index] without metamethods
pub fn nativeRawget(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 2) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const table_arg = vm.stack[vm.base + func_reg + 1];
    const key_arg = vm.stack[vm.base + func_reg + 2];

    const table = table_arg.asTable() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Direct table access without metamethods
    // Supports any TValue as key (Lua 5.4 semantics)
    vm.stack[vm.base + func_reg] = table.get(key_arg) orelse .nil;
}

/// rawset(table, index, value) - Sets the real value of table[index] without metamethods
pub fn nativeRawset(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 3) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const table_arg = vm.stack[vm.base + func_reg + 1];
    const key_arg = vm.stack[vm.base + func_reg + 2];
    const value_arg = vm.stack[vm.base + func_reg + 3];

    if (key_arg.isNil() or (key_arg == .number and std.math.isNan(key_arg.number))) {
        return vm.raiseString("table index is nil or NaN");
    }

    const table = table_arg.asTable() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Direct table set without metamethods
    // Supports any TValue as key (Lua 5.4 semantics)
    try table.set(key_arg, value_arg);

    // Return the table
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = table_arg;
    }
}

/// rawlen(v) - Returns the length of object v without metamethods
pub fn nativeRawlen(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .{ .integer = 0 };
        return;
    }

    const arg = vm.stack[vm.base + func_reg + 1];

    // String length
    if (arg.asString()) |s| {
        vm.stack[vm.base + func_reg] = .{ .integer = @intCast(s.asSlice().len) };
        return;
    }

    // Table length: count sequential integer keys from 1
    if (arg.asTable()) |table| {
        var len: i64 = 0;
        while (true) {
            const key = TValue{ .integer = len + 1 };
            const val = table.get(key) orelse break;
            if (val == .nil) break;
            len += 1;
        }
        vm.stack[vm.base + func_reg] = .{ .integer = len };
        return;
    }

    vm.stack[vm.base + func_reg] = .{ .integer = 0 };
}

/// select(index, ...) - Returns all arguments after argument number index
/// select(index, ...) - Returns arguments after index, or count with "#"
pub fn nativeSelect(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const index_arg = vm.stack[vm.base + func_reg + 1];
    const extra_args: u32 = if (nargs > 1) nargs - 1 else 0;

    // Check for "#" which returns count
    if (index_arg.asString()) |str| {
        if (std.mem.eql(u8, str.asSlice(), "#")) {
            vm.stack[vm.base + func_reg] = .{ .integer = @intCast(extra_args) };
            return;
        }
    }

    // Otherwise, index should be a number
    const index = index_arg.toInteger() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Handle negative indices (count from end)
    var start_idx: i64 = index;
    if (start_idx < 0) {
        start_idx = @as(i64, @intCast(extra_args)) + start_idx + 1;
    }

    if (start_idx < 1 or start_idx > @as(i64, @intCast(extra_args))) {
        // Out of range - return nothing
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = .nil;
        }
        return;
    }

    // Return arguments from start_idx onwards
    const start: u32 = @intCast(start_idx);
    var i: u32 = 0;
    while (i < nresults and (start + i) <= extra_args) : (i += 1) {
        // Arguments start at func_reg + 2 (func_reg + 1 is the index)
        vm.stack[vm.base + func_reg + i] = vm.stack[vm.base + func_reg + 1 + start + i];
    }

    // Fill remaining result slots with nil
    while (i < nresults) : (i += 1) {
        vm.stack[vm.base + func_reg + i] = .nil;
    }
}

/// tonumber(e [, base]) - Tries to convert argument to a number
pub fn nativeTonumber(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;
    defer {
        if (nresults > 1) {
            var i: u32 = 1;
            while (i < nresults) : (i += 1) {
                vm.stack[vm.base + func_reg + i] = .nil;
            }
        }
    }

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const arg = vm.stack[vm.base + func_reg + 1];

    // If already a number, return it
    if (arg == .integer) {
        vm.stack[vm.base + func_reg] = arg;
        return;
    }
    if (arg == .number) {
        vm.stack[vm.base + func_reg] = arg;
        return;
    }

    // Try to convert string to number
    if (arg.asString()) |str_obj| {
        const str = std.mem.trim(u8, str_obj.asSlice(), " \t\n\r");

        // Get optional base (default 10)
        var base: u8 = 10;
        const has_base = nargs >= 2 and !vm.stack[vm.base + func_reg + 2].isNil();
        if (has_base) {
            const base_arg = vm.stack[vm.base + func_reg + 2];
            const b = base_arg.toInteger() orelse {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            };
            if (b >= 2 and b <= 36) {
                base = @intCast(b);
            } else {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            }
        }

        // If base is explicitly provided, only accept integer numerals for that base.
        if (has_base) {
            if (std.fmt.parseInt(i64, str, base)) |i| {
                vm.stack[vm.base + func_reg] = .{ .integer = i };
                return;
            } else |_| {}

            vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        // Try integer first for base 10 (preserves large integer strings)
        if (std.fmt.parseInt(i64, str, 10)) |i| {
            vm.stack[vm.base + func_reg] = .{ .integer = i };
            return;
        } else |_| {}

        // Hex integer literals: parse and wrap modulo 2^64 (Lua 5.4 semantics)
        if (parseHexIntegerWrap(str)) |i| {
            vm.stack[vm.base + func_reg] = .{ .integer = i };
            return;
        }

        // Hex floating literals: parse as float when format includes '.' or 'p'
        if (parseHexFloat(str)) |n| {
            vm.stack[vm.base + func_reg] = .{ .number = n };
            return;
        }

        if (isInfNanToken(str)) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        // Fall back to float for base 10
        if (std.fmt.parseFloat(f64, str)) |n| {
            vm.stack[vm.base + func_reg] = .{ .number = n };
            return;
        } else |_| {}

        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    vm.stack[vm.base + func_reg] = .nil;
}

fn parseHexIntegerWrap(str: []const u8) ?i64 {
    if (str.len < 3) return null;
    var idx: usize = 0;
    var neg = false;
    if (str[idx] == '+' or str[idx] == '-') {
        neg = str[idx] == '-';
        idx += 1;
        if (idx >= str.len) return null;
    }
    if (idx + 1 >= str.len) return null;
    if (str[idx] != '0' or (str[idx + 1] != 'x' and str[idx + 1] != 'X')) return null;
    idx += 2;
    if (idx >= str.len) return null;

    var value: u64 = 0;
    while (idx < str.len) : (idx += 1) {
        const c = str[idx];
        const digit: u64 = switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'f' => @intCast(c - 'a' + 10),
            'A'...'F' => @intCast(c - 'A' + 10),
            else => return null,
        };
        value = (value << 4) | digit;
    }

    if (neg) {
        value = 0 -% value;
    }
    return @bitCast(value);
}

fn parseHexFloat(str: []const u8) ?f64 {
    if (str.len < 3) return null;
    var idx: usize = 0;
    var neg = false;
    if (str[idx] == '+' or str[idx] == '-') {
        neg = str[idx] == '-';
        idx += 1;
        if (idx >= str.len) return null;
    }
    if (idx + 1 >= str.len) return null;
    if (str[idx] != '0' or (str[idx + 1] != 'x' and str[idx + 1] != 'X')) return null;
    idx += 2;
    if (idx >= str.len) return null;

    // Only treat as hex float if there's a '.' or a 'p'/'P'
    if (std.mem.indexOfScalar(u8, str[idx..], '.') == null and
        std.mem.indexOfAny(u8, str[idx..], "pP") == null)
    {
        return null;
    }

    const max_keep: usize = 16;
    var total_digits: usize = 0;
    var frac_digits: usize = 0;
    var saw_dot = false;
    var first_nonzero: ?usize = null;

    // Pass 1: count digits and locate first non-zero digit
    var scan = idx;
    var flat_index: usize = 0;
    while (scan < str.len) {
        const c = str[scan];
        if (c == '.') {
            if (saw_dot) return null;
            saw_dot = true;
            scan += 1;
            continue;
        }
        const digit_opt: ?u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
        if (digit_opt) |digit| {
            total_digits += 1;
            if (saw_dot) frac_digits += 1;
            if (digit != 0 and first_nonzero == null) {
                first_nonzero = flat_index;
            }
            flat_index += 1;
            scan += 1;
            continue;
        }
        break;
    }

    if (total_digits == 0) return null;
    if (first_nonzero == null) return if (neg) -0.0 else 0.0;

    const start = if (first_nonzero.? >= max_keep) first_nonzero.? else 0;
    const kept = @min(max_keep, total_digits - start);

    // Pass 2: build kept_value from the selected window
    var kept_value: u64 = 0;
    scan = idx;
    flat_index = 0;
    saw_dot = false;
    while (scan < str.len) {
        const c = str[scan];
        if (c == '.') {
            saw_dot = true;
            scan += 1;
            continue;
        }
        const digit_opt: ?u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
        if (digit_opt) |digit| {
            if (flat_index >= start and flat_index < start + kept) {
                kept_value = (kept_value << 4) | @as(u64, digit);
            }
            flat_index += 1;
            scan += 1;
            continue;
        }
        break;
    }

    const total_i: i64 = @intCast(total_digits);
    const start_i: i64 = @intCast(start);
    const kept_i: i64 = @intCast(kept);
    const frac_i: i64 = @intCast(frac_digits);
    var exp2: i64 = 4 * (total_i - start_i - kept_i - frac_i);
    if (scan < str.len and (str[scan] == 'p' or str[scan] == 'P')) {
        scan += 1;
        if (scan >= str.len) return null;
        var exp_neg = false;
        if (str[scan] == '+' or str[scan] == '-') {
            exp_neg = str[scan] == '-';
            scan += 1;
        }
        if (scan >= str.len) return null;
        var exp_val: i64 = 0;
        var saw_digit = false;
        while (scan < str.len) : (scan += 1) {
            const c = str[scan];
            if (c < '0' or c > '9') break;
            saw_digit = true;
            exp_val = exp_val * 10 + @as(i64, @intCast(c - '0'));
        }
        if (!saw_digit) return null;
        if (exp_neg) exp_val = -exp_val;
        exp2 += exp_val;
    }

    if (scan != str.len) return null;

    const value = @as(f64, @floatFromInt(kept_value));
    const scaled = value * std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exp2)));
    return if (neg) -scaled else scaled;
}

fn isInfNanToken(str: []const u8) bool {
    return std.ascii.eqlIgnoreCase(str, "inf") or
        std.ascii.eqlIgnoreCase(str, "+inf") or
        std.ascii.eqlIgnoreCase(str, "-inf") or
        std.ascii.eqlIgnoreCase(str, "nan") or
        std.ascii.eqlIgnoreCase(str, "+nan") or
        std.ascii.eqlIgnoreCase(str, "-nan");
}

fn floatToIntExact(n: f64) ?i64 {
    if (!std.math.isFinite(n)) return null;
    if (n != @floor(n)) return null;
    const max_i = std.math.maxInt(i64);
    const min_i = std.math.minInt(i64);
    const max_f = @as(f64, @floatFromInt(max_i));
    const min_f = @as(f64, @floatFromInt(min_i));
    if (n < min_f or n > max_f) return null;
    if (!intFitsFloat(max_i) and n >= max_f) return null;
    const i: i64 = @intFromFloat(n);
    if (@as(f64, @floatFromInt(i)) != n) return null;
    return i;
}

fn intFitsFloat(i: i64) bool {
    const max_exact: i64 = @as(i64, 1) << 53;
    return i >= -max_exact and i <= max_exact;
}

/// rawequal(v1, v2) - Checks whether v1 is equal to v2 without invoking metamethods
pub fn nativeRawequal(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 2) {
        vm.stack[vm.base + func_reg] = .{ .boolean = false };
        return;
    }

    const v1 = vm.stack[vm.base + func_reg + 1];
    const v2 = vm.stack[vm.base + func_reg + 2];

    // Use primitive equality (no metamethods)
    vm.stack[vm.base + func_reg] = .{ .boolean = v1.eql(v2) };
}

/// load(chunk [, chunkname [, mode [, env]]]) - Loads a chunk
/// chunk: string or function returning strings
/// Returns: compiled function, or (nil, error_message) on failure
pub fn nativeLoad(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const serializer = @import("../compiler/serializer.zig");
    const object = @import("../runtime/gc/object.zig");

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("bad argument #1 to 'load' (value expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    }

    const chunk_arg = vm.stack[vm.base + func_reg + 1];

    // Get env parameter (4th argument, default to globals)
    const env_table: *object.TableObject = if (nargs >= 4 and !vm.stack[vm.base + func_reg + 4].isNil())
        vm.stack[vm.base + func_reg + 4].asTable() orelse vm.globals()
    else
        vm.globals();

    // Get source string
    const source = if (chunk_arg.asString()) |str_obj|
        str_obj.asSlice()
    else {
        // TODO: Support reader function
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("load: reader function not yet supported");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    };

    // Check if this is binary bytecode
    if (serializer.isBytecode(source)) {
        // Load from bytecode
        vm.gc().inhibitGC();
        defer vm.gc().allowGC();

        const proto = serializer.loadProto(source, vm.gc(), vm.gc().allocator) catch {
            vm.stack[vm.base + func_reg] = .nil;
            if (nresults > 1) {
                const err_str = try vm.gc().allocString("invalid bytecode");
                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
            }
            return;
        };

        const closure = try vm.gc().allocClosure(proto);

        // Initialize _ENV upvalue (first upvalue) to the environment table
        if (closure.upvalues.len > 0) {
            const env_upval = try vm.gc().allocClosedUpvalue(TValue.fromTable(env_table));
            closure.upvalues[0] = env_upval;
        }

        vm.stack[vm.base + func_reg] = TValue.fromClosure(closure);
        return;
    }

    // Compile the source
    const compile_result = pipeline.compile(vm.gc().allocator, source, .{});
    switch (compile_result) {
        .err => |e| {
            defer e.deinit(vm.gc().allocator);
            vm.stack[vm.base + func_reg] = .nil;
            if (nresults > 1) {
                // Format: "[string]:line: message"
                const msg = std.fmt.allocPrint(vm.gc().allocator, "[string]:{d}: {s}", .{
                    e.line, e.message,
                }) catch "syntax error";
                defer vm.gc().allocator.free(msg);
                const err_str = try vm.gc().allocString(msg);
                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
            }
            return;
        },
        .ok => {},
    }
    const raw_proto = compile_result.ok;
    defer pipeline.freeRawProto(vm.gc().allocator, raw_proto);

    // Materialize to Proto and create closure
    // Inhibit GC until closure is on the stack (proto is not rooted otherwise)
    vm.gc().inhibitGC();
    defer vm.gc().allowGC();

    const proto = pipeline.materialize(&raw_proto, vm.gc(), vm.gc().allocator) catch {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("failed to materialize chunk");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    };

    // Create closure - proto is now safe since GC is inhibited
    const closure = try vm.gc().allocClosure(proto);

    // Initialize _ENV upvalue (first upvalue) to the environment table
    if (closure.upvalues.len > 0) {
        const env_upval = try vm.gc().allocClosedUpvalue(TValue.fromTable(env_table));
        closure.upvalues[0] = env_upval;
    }

    vm.stack[vm.base + func_reg] = TValue.fromClosure(closure);
}

/// loadfile([filename [, mode [, env]]]) - Loads a chunk from a file
/// Returns: compiled function, or (nil, error_message) on failure
pub fn nativeLoadfile(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const object = @import("../runtime/gc/object.zig");

    if (nargs < 1) {
        // loadfile() without args reads from stdin - not implemented
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("loadfile: stdin not supported");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    }

    const filename_arg = vm.stack[vm.base + func_reg + 1];
    const filename = if (filename_arg.asString()) |str_obj|
        str_obj.asSlice()
    else {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("bad argument #1 to 'loadfile' (string expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    };

    // Get env parameter (3rd argument, default to globals)
    const env_table: *object.TableObject = if (nargs >= 3 and !vm.stack[vm.base + func_reg + 3].isNil())
        vm.stack[vm.base + func_reg + 3].asTable() orelse vm.globals()
    else
        vm.globals();

    // Read file contents
    const file = std.fs.cwd().openFile(filename, .{}) catch {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("cannot open file");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    };
    defer file.close();

    const source = file.readToEndAlloc(vm.gc().allocator, 1024 * 1024 * 10) catch {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("cannot read file");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    };
    defer vm.gc().allocator.free(source);

    // Compile the source with filename as source name
    const compile_result = pipeline.compile(vm.gc().allocator, source, .{ .source_name = filename });
    switch (compile_result) {
        .err => |e| {
            defer e.deinit(vm.gc().allocator);
            vm.stack[vm.base + func_reg] = .nil;
            if (nresults > 1) {
                // Format: "filename:line: message"
                const msg = std.fmt.allocPrint(vm.gc().allocator, "{s}:{d}: {s}", .{
                    filename, e.line, e.message,
                }) catch "syntax error";
                defer vm.gc().allocator.free(msg);
                const err_str = try vm.gc().allocString(msg);
                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
            }
            return;
        },
        .ok => {},
    }
    const raw_proto = compile_result.ok;
    defer pipeline.freeRawProto(vm.gc().allocator, raw_proto);

    // Materialize to Proto and create closure
    // Inhibit GC until closure is on the stack (proto is not rooted otherwise)
    vm.gc().inhibitGC();
    defer vm.gc().allowGC();

    const proto = pipeline.materialize(&raw_proto, vm.gc(), vm.gc().allocator) catch {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("failed to materialize chunk");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    };

    // Create closure - proto is now safe since GC is inhibited
    const closure = try vm.gc().allocClosure(proto);

    // Initialize _ENV upvalue (first upvalue) to the environment table
    if (closure.upvalues.len > 0) {
        const env_upval = try vm.gc().allocClosedUpvalue(TValue.fromTable(env_table));
        closure.upvalues[0] = env_upval;
    }

    vm.stack[vm.base + func_reg] = TValue.fromClosure(closure);
}

/// dofile([filename]) - Executes a Lua file
/// Returns: all values returned by the chunk
pub fn nativeDofile(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        // dofile() without args reads from stdin - not implemented
        return vm.raiseString("dofile: stdin not supported");
    }

    const filename_arg = vm.stack[vm.base + func_reg + 1];
    const filename = if (filename_arg.asString()) |str_obj|
        str_obj.asSlice()
    else {
        return vm.raiseString("bad argument #1 to 'dofile' (string expected)");
    };

    // Read file contents
    const file = std.fs.cwd().openFile(filename, .{}) catch {
        return vm.raiseString("cannot open file");
    };
    defer file.close();

    const source = file.readToEndAlloc(vm.gc().allocator, 1024 * 1024 * 10) catch {
        return vm.raiseString("cannot read file");
    };
    defer vm.gc().allocator.free(source);

    // Compile the source
    const compile_result = pipeline.compile(vm.gc().allocator, source, .{ .source_name = filename });
    switch (compile_result) {
        .err => |e| {
            defer e.deinit(vm.gc().allocator);
            const msg = std.fmt.allocPrint(vm.gc().allocator, "{s}:{d}: {s}", .{
                filename, e.line, e.message,
            }) catch "syntax error";
            defer vm.gc().allocator.free(msg);
            return vm.raiseString(msg);
        },
        .ok => {},
    }
    const raw_proto = compile_result.ok;
    defer pipeline.freeRawProto(vm.gc().allocator, raw_proto);

    // Materialize to Proto and create closure
    // Inhibit GC until closure is on the stack (proto is not rooted otherwise)
    vm.gc().inhibitGC();
    defer vm.gc().allowGC();

    const proto = pipeline.materialize(&raw_proto, vm.gc(), vm.gc().allocator) catch {
        return vm.raiseString("failed to materialize chunk");
    };

    // Create closure - proto is now safe since GC is inhibited
    const closure = try vm.gc().allocClosure(proto);

    // Initialize _ENV upvalue (first upvalue) to the globals table
    if (closure.upvalues.len > 0) {
        const env_upval = try vm.gc().allocClosedUpvalue(TValue.fromTable(vm.globals()));
        closure.upvalues[0] = env_upval;
    }

    const func_val = TValue.fromClosure(closure);

    // Execute the chunk - errors propagate directly
    const result = try call.callValue(vm, func_val, &[_]TValue{});

    // Return the result
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
}

/// warn(msg1, ...) - Emits a warning with a message (Lua 5.4 feature)
pub fn nativeWarn(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    var stderr_writer = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_writer.interface;

    try stderr.writeAll("Lua warning: ");

    var i: u32 = 0;
    while (i < nargs) : (i += 1) {
        const arg = vm.stack[vm.base + func_reg + 1 + i];

        if (arg.asString()) |str_obj| {
            try stderr.writeAll(str_obj.asSlice());
        } else if (arg == .integer) {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{arg.integer}) catch "";
            try stderr.writeAll(s);
        } else if (arg == .number) {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{arg.number}) catch "";
            try stderr.writeAll(s);
        }
    }

    try stderr.writeAll("\n");
}

/// _G - A global variable holding the global environment
pub fn nativeG(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // Note: _G is initialized as a globals table reference in builtin_dispatch.
    // This native is currently unused; if called, it should return vm.globals().
}

/// _VERSION - A global variable containing the running Lua version string
pub fn nativeVersion(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const version_str = try vm.gc().allocString("Lua 5.4");
    vm.stack[vm.base + func_reg] = TValue.fromString(version_str);
}

/// collectgarbage([opt [, arg]]) - Controls garbage collection
const GcOption = enum {
    collect,
    stop,
    restart,
    count,
    step,
    isrunning,
    incremental,
    generational,
};

const gc_options = std.StaticStringMap(GcOption).initComptime(.{
    .{ "collect", .collect },
    .{ "stop", .stop },
    .{ "restart", .restart },
    .{ "count", .count },
    .{ "step", .step },
    .{ "isrunning", .isrunning },
    .{ "incremental", .incremental },
    .{ "generational", .generational },
});

pub fn nativeCollectGarbage(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const opt = if (nargs > 0) blk: {
        const opt_arg = vm.stack[vm.base + func_reg + 1];
        break :blk if (opt_arg.asString()) |s| s.asSlice() else "collect";
    } else "collect";

    const gc = vm.gc();
    const result: TValue = if (gc_options.get(opt)) |option| switch (option) {
        .collect => blk: {
            vm.collectGarbage();
            break :blk .nil;
        },
        .stop => TValue{ .boolean = gc.stop() },
        .restart => blk: {
            gc.restart();
            break :blk .nil;
        },
        .count => TValue{ .number = @as(f64, @floatFromInt(gc.bytes_allocated)) / 1024.0 },
        .step => TValue{ .boolean = gc.step() },
        .isrunning => TValue{ .boolean = gc.is_running },
        .incremental => .nil, // Not implemented (Lua 5.4 advanced)
        .generational => .nil, // Not implemented (Lua 5.4 advanced)
    } else blk: {
        // Invalid option returns nil (Lua compatible)
        break :blk .nil;
    };

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
}

test "gc_options maps all valid Lua 5.4 options" {
    // Valid options
    try std.testing.expectEqual(GcOption.collect, gc_options.get("collect").?);
    try std.testing.expectEqual(GcOption.stop, gc_options.get("stop").?);
    try std.testing.expectEqual(GcOption.restart, gc_options.get("restart").?);
    try std.testing.expectEqual(GcOption.count, gc_options.get("count").?);
    try std.testing.expectEqual(GcOption.step, gc_options.get("step").?);
    try std.testing.expectEqual(GcOption.isrunning, gc_options.get("isrunning").?);
    try std.testing.expectEqual(GcOption.incremental, gc_options.get("incremental").?);
    try std.testing.expectEqual(GcOption.generational, gc_options.get("generational").?);

    // Invalid options return null
    try std.testing.expect(gc_options.get("invalid") == null);
    try std.testing.expect(gc_options.get("") == null);
    try std.testing.expect(gc_options.get("COLLECT") == null); // case sensitive
}
