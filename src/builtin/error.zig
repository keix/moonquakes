const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Expression Layer: assert() function
/// Lua signature: assert(v [, message])
/// If v is false or nil, raises an error with optional message
pub fn nativeAssert(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs == 0) {
        // assert() with no arguments - assertion failed
        return raiseError(vm, "assertion failed!");
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
        const message = if (nargs >= 2) blk: {
            const msg_arg = vm.stack[vm.base + func_reg + 2];
            break :blk if (msg_arg.asString()) |s| s.asSlice() else "assertion failed!";
        } else "assertion failed!";

        return raiseError(vm, message);
    }

    // Return the first argument if assertion succeeds
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = value;
    }
}

/// Expression Layer: error() function
/// Lua signature: error(message [, level])
/// Raises an error with the given message
pub fn nativeError(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults; // error() never returns

    const message = if (nargs > 0) blk: {
        const msg_arg = vm.stack[vm.base + func_reg + 1];
        break :blk if (msg_arg.asString()) |s| s.asSlice() else "error";
    } else "error";

    // TODO: Handle optional level parameter for stack unwinding
    // For now, we raise the error at the current level
    return raiseError(vm, message);
}

/// Internal helper: Raise a Lua error with message
/// This bridges from Expression Layer to Sugar Layer error translation
fn raiseError(vm: anytype, message: []const u8) !void {
    // Store error message in VM for pcall to retrieve
    vm.lua_error_msg = vm.gc.allocString(message) catch null;

    // Return a VM error that will be caught by protected call handler
    return RuntimeError.RuntimeError;
}

/// Error type for user-level errors raised by assert/error functions
pub const RuntimeError = error{
    RuntimeError, // Generic runtime error from user code
};
