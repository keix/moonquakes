const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;

/// Expression Layer: assert() function
/// Lua signature: assert(v [, message])
/// If v is false or nil, raises an error with optional message
pub fn nativeAssert(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs == 0) {
        // assert() with no arguments - assertion failed
        return vm.raiseString("assertion failed!");
    }

    const value = vm.stack[vm.base + func_reg + 1];

    // In Lua, only nil and false are falsy
    const is_truthy = switch (value) {
        .nil => false,
        .boolean => |b| b,
        else => true,
    };

    if (!is_truthy) {
        // Get optional message from second argument
        if (nargs >= 2) {
            const msg_arg = vm.stack[vm.base + func_reg + 2];
            // Lua's assert can throw any value as error
            return vm.raise(msg_arg);
        }
        return vm.raiseString("assertion failed!");
    }

    // Return the first argument if assertion succeeds
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = value;
    }
}

/// Expression Layer: error() function
/// Lua signature: error(message [, level])
/// Raises an error with the given message (can be any value)
pub fn nativeError(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults; // error() never returns

    // Lua's error() can throw any value, not just strings
    const error_value = if (nargs > 0)
        vm.stack[vm.base + func_reg + 1]
    else
        .nil;

    // TODO: Handle optional level parameter for stack unwinding
    return vm.raise(error_value);
}
