const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Lua 5.4 Coroutine Library
/// Corresponds to Lua manual chapter "Coroutines"
/// Reference: https://www.lua.org/manual/5.4/manual.html#2.6
/// coroutine.create(f) - Creates a new coroutine with body f
pub fn nativeCoroutineCreate(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement coroutine.create
    // f must be a function, returns new coroutine (thread)
}

/// coroutine.resume(co [, val1, ...]) - Starts or continues coroutine co
pub fn nativeCoroutineResume(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement coroutine.resume
    // Returns success status and any yielded/returned values
}

/// coroutine.running() - Returns running coroutine plus boolean indicating main thread
pub fn nativeCoroutineRunning(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement coroutine.running
    // Returns current coroutine and true if it's the main thread
}

/// coroutine.status(co) - Returns status of coroutine co
pub fn nativeCoroutineStatus(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement coroutine.status
    // Returns "running", "suspended", "normal", or "dead"
}

/// coroutine.wrap(f) - Creates a coroutine and returns a function that resumes it
pub fn nativeCoroutineWrap(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement coroutine.wrap
    // Like create but returns function instead of thread
}

/// coroutine.yield(...) - Suspends execution of calling coroutine
pub fn nativeCoroutineYield(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement coroutine.yield
    // Can only be called from inside a coroutine
}

/// coroutine.isyieldable() - Returns true if running coroutine can yield
pub fn nativeCoroutineIsYieldable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement coroutine.isyieldable
    // Returns false for main thread and C functions
}

/// coroutine.close(co) - Closes coroutine co (Lua 5.4 feature)
pub fn nativeCoroutineClose(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement coroutine.close
    // Closes coroutine and runs to-be-closed variables
}
