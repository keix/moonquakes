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
            break :blk switch (msg_arg) {
                .string => |s| s,
                else => "assertion failed!",
            };
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
        break :blk switch (msg_arg) {
            .string => |s| s,
            else => "error",
        };
    } else "error";

    // TODO: Handle optional level parameter for stack unwinding
    // For now, we raise the error at the current level
    return raiseError(vm, message);
}

/// Expression Layer: collectgarbage() function
/// Lua signature: collectgarbage([opt [, arg]])
/// Controls garbage collection
pub fn nativeCollectGarbage(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const opt = if (nargs > 0) blk: {
        const opt_arg = vm.stack[vm.base + func_reg + 1];
        break :blk switch (opt_arg) {
            .string => |s| s,
            else => "collect",
        };
    } else "collect";

    // TODO: Integrate with actual GC implementation
    // For now, return appropriate mock values based on option
    const result = if (std.mem.eql(u8, opt, "collect")) blk: {
        // Simulate garbage collection
        break :blk TValue{ .integer = 0 };
    } else if (std.mem.eql(u8, opt, "count")) blk: {
        // Return memory usage in KB (mock)
        break :blk TValue{ .number = 1024.0 };
    } else if (std.mem.eql(u8, opt, "step")) blk: {
        // Perform incremental collection step
        break :blk TValue{ .boolean = true };
    } else if (std.mem.eql(u8, opt, "setpause") or
        std.mem.eql(u8, opt, "setstepmul"))
    blk: {
        // Return previous value (mock)
        break :blk TValue{ .integer = 200 };
    } else if (std.mem.eql(u8, opt, "isrunning")) blk: {
        // GC is always "running" in our implementation
        break :blk TValue{ .boolean = true };
    } else blk: {
        // Unknown option
        break :blk TValue{ .nil = {} };
    };

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
}

/// Internal helper: Raise a Lua error with message
/// This bridges from Expression Layer to Sugar Layer error translation
fn raiseError(vm: anytype, message: []const u8) !void {
    _ = vm; // TODO: Use vm for proper stack unwinding context

    // TODO: This should:
    // 1. Create proper stack unwinding context
    // 2. Use Sugar Layer error formatting
    // 3. Integrate with VM error handling mechanism

    // For now, print error and return VM error
    const stderr = std.io.getStdErr().writer();
    try stderr.print("Lua error: {s}\n", .{message});

    // Return a VM error that will be caught by the Sugar Layer
    return RuntimeError.RuntimeError;
}

/// Error type for user-level errors raised by assert/error functions
pub const RuntimeError = error{
    RuntimeError, // Generic runtime error from user code
};
