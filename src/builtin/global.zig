const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const string = @import("string.zig");

/// Lua 5.4 Global Functions (Basic Functions)
/// Corresponds to Lua manual chapter "Basic Functions"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.1
pub fn nativePrint(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const stdout = std.io.getStdOut().writer();

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
        const str_val = switch (result) {
            .string => |s| s,
            else => unreachable, // tostring must return string
        };

        try stdout.writeAll(str_val.asSlice());

        // Clean up temporary registers
        vm.top -= 2;
    }
    try stdout.writeAll("\n");

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
            .string => "string",
            .function => "function",
            .table => "table",
            .closure => "function",
        };
    } else "nil";

    if (nresults > 0) {
        const type_name = try vm.gc.allocString(type_name_str);
        vm.stack[vm.base + func_reg] = TValue{ .string = type_name };
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
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement next
    // Returns the next index of the table and its associated value
}

/// pairs(t) - Returns three values for iterating over table
pub fn nativePairs(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement pairs
    // Returns next, t, nil for generic for loop
}

/// ipairs(t) - Returns three values for iterating over array part of table
pub fn nativeIpairs(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement ipairs
    // Returns iterator for integer indices 1, 2, 3, ...
}

/// getmetatable(object) - Returns the metatable of the given object
pub fn nativeGetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement getmetatable
    // Returns the metatable of the given object or nil
}

/// setmetatable(table, metatable) - Sets the metatable for the given table
pub fn nativeSetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement setmetatable
    // Sets metatable and returns the table
}

/// rawget(table, index) - Gets the real value of table[index] without metamethods
pub fn nativeRawget(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement rawget
    // Bypasses __index metamethod
}

/// rawset(table, index, value) - Sets the real value of table[index] without metamethods
pub fn nativeRawset(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement rawset
    // Bypasses __newindex metamethod
}

/// rawlen(v) - Returns the length of object v without metamethods
pub fn nativeRawlen(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement rawlen
    // Bypasses __len metamethod
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
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement tonumber
    // Converts string to number, optionally with specified base (2-36)
}

/// rawequal(v1, v2) - Checks whether v1 is equal to v2 without invoking metamethods
pub fn nativeRawequal(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement rawequal
    // Returns true if v1 and v2 are primitively equal (without __eq metamethod)
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
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement warn
    // Emits warning message (can be controlled with @on/@off)
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
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement _VERSION
    // Returns version string like "Lua 5.4" (or "Moonquakes 0.1")
    // Note: This could be implemented as a constant rather than a function
}
