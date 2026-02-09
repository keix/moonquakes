const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const string = @import("string.zig");

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
    const type_name_str = if (nargs > 0) blk: {
        const arg = vm.stack[vm.base + func_reg + 1];
        break :blk switch (arg) {
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
            },
        };
    } else "nil";

    if (nresults > 0) {
        const type_name = try vm.gc.allocString(type_name_str);
        vm.stack[vm.base + func_reg] = TValue.fromString(type_name);
    }
}

/// pcall(f [, arg1, ...]) - Calls function f with given arguments in protected mode
pub fn nativePcall(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement pcall
    // Should catch errors and return (true, result...) or (false, error_message)
}

/// xpcall(f, msgh [, arg1, ...]) - Calls function f with error handler msgh
pub fn nativeXpcall(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement xpcall
    // Enhanced version of pcall with custom error handler
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
            // Return this key-value pair
            vm.stack[vm.base + func_reg] = TValue.fromString(@constCast(key));
            if (nresults > 1) {
                vm.stack[vm.base + func_reg + 1] = value;
            }
            return;
        }

        // Check if this is the current key
        if (index_arg.asString()) |index_str| {
            if (key == index_str) {
                found_current = true;
            }
        }
    }

    // No more entries
    vm.stack[vm.base + func_reg] = .nil;
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = .nil;
    }
}

/// pairs(t) - Returns three values for iterating over table
/// Returns: next function, table, nil
pub fn nativePairs(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const table_arg = vm.stack[vm.base + func_reg + 1];

    // Return next function
    const next_nc = try vm.gc.allocNativeClosure(.{ .id = .next });
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
    const iter_nc = try vm.gc.allocNativeClosure(.{ .id = .ipairs_iterator });
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

    // Convert integer index to string key (tables store integer keys as strings)
    var key_buffer: [32]u8 = undefined;
    const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{next_index}) catch {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const key = try vm.gc.allocString(key_slice);
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
pub fn nativeGetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const arg = vm.stack[vm.base + func_reg + 1];

    var result: TValue = .nil;
    if (arg.asTable()) |table| {
        if (table.metatable) |mt| {
            // Check for __metatable field (protects metatable from modification)
            if (mt.get(vm.mm_keys.metatable)) |protected| {
                result = protected;
            } else {
                result = TValue.fromTable(mt);
            }
        }
    }
    // TODO: Support metatables for strings (shared string metatable)

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
}

/// setmetatable(table, metatable) - Sets the metatable for the given table
/// Returns the table. Raises error if metatable has __metatable field (protected).
pub fn nativeSetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const table_arg = vm.stack[vm.base + func_reg + 1];
    const mt_arg = vm.stack[vm.base + func_reg + 2];

    const table = table_arg.asTable() orelse {
        // setmetatable only works on tables
        return error.InvalidTableOperation;
    };

    // Check if current metatable is protected
    if (table.metatable) |current_mt| {
        if (current_mt.get(vm.mm_keys.metatable) != null) {
            return error.ProtectedMetatable;
        }
    }

    // Set the new metatable (nil clears it)
    if (mt_arg.isNil()) {
        table.metatable = null;
    } else if (mt_arg.asTable()) |new_mt| {
        table.metatable = new_mt;
    } else {
        return error.InvalidTableOperation;
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
    // Currently only supports string keys
    const key = key_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    vm.stack[vm.base + func_reg] = table.get(key) orelse .nil;
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

    const table = table_arg.asTable() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Direct table set without metamethods
    // Currently only supports string keys
    const key = key_arg.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    try table.set(key, value_arg);

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
        var key_buffer: [32]u8 = undefined;
        while (true) {
            const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{len + 1}) catch break;
            const key = vm.gc.allocString(key_slice) catch break;
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
pub fn nativeSelect(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement select
    // Special case: select("#", ...) returns argument count
}

/// tonumber(e [, base]) - Tries to convert argument to a number
pub fn nativeTonumber(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

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
        const str = str_obj.asSlice();

        // Get optional base (default 10)
        var base: u8 = 10;
        if (nargs >= 2) {
            const base_arg = vm.stack[vm.base + func_reg + 2];
            if (base_arg.toInteger()) |b| {
                if (b >= 2 and b <= 36) {
                    base = @intCast(b);
                } else {
                    vm.stack[vm.base + func_reg] = .nil;
                    return;
                }
            }
        }

        // Try parsing as integer with base
        if (base == 10) {
            // Try float first for base 10
            if (std.fmt.parseFloat(f64, str)) |n| {
                // Check if it's an integer
                if (n == @floor(n) and n >= @as(f64, @floatFromInt(std.math.minInt(i64))) and n <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
                    vm.stack[vm.base + func_reg] = .{ .integer = @intFromFloat(n) };
                } else {
                    vm.stack[vm.base + func_reg] = .{ .number = n };
                }
                return;
            } else |_| {}
        }

        // Try integer parsing with specified base
        if (std.fmt.parseInt(i64, str, base)) |i| {
            vm.stack[vm.base + func_reg] = .{ .integer = i };
            return;
        } else |_| {}

        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    vm.stack[vm.base + func_reg] = .nil;
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
pub fn nativeLoad(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement load
    // Loads Lua chunk from string or reader function
    // Requires integration with compiler/parser
}

/// loadfile([filename [, mode [, env]]]) - Loads a chunk from a file
pub fn nativeLoadfile(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement loadfile
    // Loads Lua chunk from file
    // Requires integration with compiler/parser
}

/// dofile([filename]) - Executes a Lua file
pub fn nativeDofile(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement dofile
    // Equivalent to: assert(loadfile(filename))()
    // Requires integration with compiler/parser
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
    // TODO: Implement _G
    // Returns the global environment table
    // Note: In Lua, _G is usually just a reference to the globals table
}

/// _VERSION - A global variable containing the running Lua version string
pub fn nativeVersion(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    const version_str = try vm.gc.allocString("Lua 5.4");
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

    const result: TValue = if (gc_options.get(opt)) |option| switch (option) {
        .collect => blk: {
            vm.collectGarbage();
            break :blk TValue{ .nil = {} };
        },
        .stop => TValue{ .nil = {} }, // TODO
        .restart => TValue{ .nil = {} }, // TODO
        .count => blk: {
            const stats = vm.gc.getStats();
            const kb: f64 = @as(f64, @floatFromInt(stats.bytes_allocated)) / 1024.0;
            break :blk TValue{ .number = kb };
        },
        .step => blk: {
            vm.collectGarbage();
            break :blk TValue{ .boolean = true };
        },
        .isrunning => TValue{ .boolean = true },
        .incremental => TValue{ .nil = {} }, // TODO
        .generational => TValue{ .nil = {} }, // TODO
    } else blk: {
        // TODO: Raise error for invalid option
        break :blk TValue{ .nil = {} };
    };

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
}

// =============================================================================
// Tests
// =============================================================================

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
