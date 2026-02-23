//! VM Call API
//!
//! Provides reentrant function calling from native code.
//! Used by: gsub, table.sort, metamethods, future C API (mq_call)
//!
//! This is a VM core API, not instruction semantics.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;
const ProtoObject = object.ProtoObject;
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const mnemonics = @import("mnemonics.zig");
const VM = @import("vm.zig").VM;

/// Error type for call operations
pub const CallError = error{
    NotCallable,
    CallStackOverflow,
    OutOfMemory,
};

/// Call a Lua/native function value with given arguments and return first result.
///
/// Used by standard library functions (gsub, table.sort, etc.) that need to call user functions.
///
/// Handles:
/// - Lua closures: executes synchronously until return
/// - Native closures: calls directly
///
/// Returns: first return value, or nil if function returns nothing
///
/// Errors: NotCallable if value is not a function
///
/// GC Safety: Caller must ensure args are rooted before call.
/// The call itself may trigger GC during execution.
pub fn callValue(vm: *VM, func_val: TValue, args: []const TValue) anyerror!TValue {
    // Handle native closure
    if (func_val.asNativeClosure()) |nc| {
        return callNativeClosure(vm, nc, args);
    }

    // Handle Lua closure
    if (func_val.asClosure()) |closure| {
        return callClosure(vm, closure, args);
    }

    // Handle table with __call metamethod
    if (func_val.asTable()) |table| {
        if (table.metatable) |mt| {
            const call_key = TValue.fromString(vm.gc().mm_keys.get(.call));
            if (mt.get(call_key)) |call_mm| {
                // __call can be a native closure or Lua closure
                // Call as: __call(table, args...)
                return callWithSelf(vm, call_mm, func_val, args);
            }
        }
    }

    // Not a function - this is an error in Lua semantics
    return CallError.NotCallable;
}

/// Call a function with self prepended to arguments.
/// Used for __call metamethod: __call(self, args...)
fn callWithSelf(vm: *VM, func_val: TValue, self: TValue, args: []const TValue) anyerror!TValue {
    // Handle native closure __call
    if (func_val.asNativeClosure()) |nc| {
        // GC SAFETY: Save caller's frame state
        const saved_base = vm.base;
        const saved_top = vm.top;

        const call_base = vm.top;
        const result_slot = call_base;

        // Stack layout: [self, arg0, arg1, ...]
        // (native function sees self at func_reg, args at func_reg+1...)
        vm.stack[call_base] = self;
        for (args, 0..) |arg, i| {
            vm.stack[call_base + 1 + @as(u32, @intCast(i))] = arg;
        }

        vm.base = call_base;
        vm.top = call_base + 1 + @as(u32, @intCast(args.len));

        // nargs is args.len + 1 (includes self)
        try vm.callNative(nc.func.id, 0, @as(u32, @intCast(args.len)) + 1, 1);

        const result = vm.stack[result_slot];
        vm.base = saved_base;
        vm.top = saved_top;

        return result;
    }

    // Handle Lua closure __call
    if (func_val.asClosure()) |closure| {
        const proto = closure.proto;

        const saved_base = vm.base;
        const saved_top = vm.top;

        const call_base = vm.top;
        const result_slot = call_base;

        // Stack layout: [self, arg0, arg1, ...]
        vm.stack[call_base] = self;
        for (args, 0..) |arg, i| {
            vm.stack[call_base + 1 + @as(u32, @intCast(i))] = arg;
        }

        // Fill remaining params with nil (total params = 1 + args.len)
        var i: u32 = 1 + @as(u32, @intCast(args.len));
        while (i < proto.numparams) : (i += 1) {
            vm.stack[call_base + i] = .nil;
        }

        vm.top = call_base + proto.maxstacksize;

        return runUntilReturn(vm, proto, closure, call_base, result_slot, saved_base, saved_top);
    }

    return CallError.NotCallable;
}

/// Call a native closure with arguments.
/// Native closures use a different calling convention than Lua closures.
fn callNativeClosure(vm: *VM, nc: *NativeClosureObject, args: []const TValue) anyerror!TValue {
    // GC SAFETY: Save caller's frame state for restoration after call
    const saved_base = vm.base;
    const saved_top = vm.top;

    const call_base = vm.top;
    const result_slot = call_base;

    // Native closures expect: [func_placeholder, arg0, arg1, ...]
    // Set up stack
    vm.stack[call_base] = TValue.fromNativeClosure(nc);
    for (args, 0..) |arg, i| {
        vm.stack[call_base + 1 + @as(u32, @intCast(i))] = arg;
    }

    // Set vm.base to call_base so native function sees correct stack layout
    // (native functions use vm.base + func_reg to access their frame)
    vm.base = call_base;
    vm.top = call_base + 1 + @as(u32, @intCast(args.len));

    // Call native function (func_reg = 0 relative to new vm.base)
    try vm.callNative(nc.func.id, 0, @intCast(args.len), 1);

    // Get result before restoring frame state
    const result = vm.stack[result_slot];

    // GC SAFETY: Restore caller's frame state
    // This ensures the caller's full stack frame is visible to GC
    vm.base = saved_base;
    vm.top = saved_top;

    return result;
}

/// Call a Lua closure with arguments.
/// Executes synchronously until the function returns.
fn callClosure(vm: *VM, closure: *ClosureObject, args: []const TValue) anyerror!TValue {
    const proto = closure.proto;

    // GC SAFETY: Save caller's frame state for restoration after call
    const saved_base = vm.base;
    const saved_top = vm.top;

    const call_base = vm.top;
    const result_slot = call_base;

    // Set up arguments
    for (args, 0..) |arg, i| {
        vm.stack[call_base + @as(u32, @intCast(i))] = arg;
    }

    // Fill remaining params with nil
    var i: u32 = @intCast(args.len);
    while (i < proto.numparams) : (i += 1) {
        vm.stack[call_base + i] = .nil;
    }

    vm.top = call_base + proto.maxstacksize;

    // Execute until return, then restore caller's frame state
    return runUntilReturn(vm, proto, closure, call_base, result_slot, saved_base, saved_top);
}

/// Execute a Lua function until it returns to saved call depth.
/// This is the core reentrant execution loop.
///
/// GC Safety: saved_base and saved_top are the caller's frame state,
/// which must be restored after the call completes to ensure the caller's
/// full stack frame is visible to GC.
fn runUntilReturn(
    vm: *VM,
    proto: *const ProtoObject,
    closure: *ClosureObject,
    call_base: u32,
    result_slot: u32,
    saved_base: u32,
    saved_top: u32,
) anyerror!TValue {
    // Save current call depth for reentrancy
    const saved_depth = vm.callstack_size;

    // Push call info
    _ = try mnemonics.pushCallInfo(vm, proto, closure, call_base, result_slot, 1);

    // CRITICAL: Ensure vm.base and vm.top are restored even on error
    // Without this, errors in called functions leave the VM in a corrupt state
    errdefer {
        // Pop any frames we pushed
        while (vm.callstack_size > saved_depth) {
            mnemonics.popCallInfo(vm);
        }
        // Restore caller's frame state
        vm.base = saved_base;
        vm.top = saved_top;
    }

    // Execute until we return to saved depth
    var direct_result: ?TValue = null;
    while (vm.callstack_size > saved_depth) {
        const ci = &vm.callstack[vm.callstack_size - 1];
        const inst = ci.fetch() catch {
            // End of function - pop this frame
            mnemonics.popCallInfo(vm);

            // If we're back to the original depth, restore caller's frame
            if (vm.callstack_size == saved_depth) {
                break;
            }

            // Otherwise, restore to the previous frame in the callstack
            const prev_ci = &vm.callstack[vm.callstack_size - 1];
            vm.base = prev_ci.ret_base;
            vm.top = prev_ci.ret_base + prev_ci.func.maxstacksize;
            continue;
        };
        const result = mnemonics.do(vm, inst) catch |err| {
            // Handle LuaException by unwinding to protected frames (pcall)
            if (err == error.LuaException and mnemonics.handleLuaException(vm)) continue;
            // Convert VM errors to LuaException for pcall catchability
            if (err == error.ArithmeticError or
                err == error.NotATable or
                err == error.NotAFunction or
                err == error.InvalidTableKey or
                err == error.InvalidTableOperation or
                err == error.FormatError)
            {
                // Set error message and try to handle as LuaException
                const msg = switch (err) {
                    error.ArithmeticError => "attempt to perform arithmetic on a non-numeric value",
                    error.NotATable => "attempt to index a non-table value",
                    error.NotAFunction => "attempt to call a non-function value",
                    error.InvalidTableKey => "table index is nil or NaN",
                    error.InvalidTableOperation => "attempt to index a non-table value",
                    error.FormatError => "bad argument to string format",
                    else => "runtime error",
                };
                vm.lua_error_value = TValue.fromString(vm.gc().allocString(msg) catch {
                    return err; // OOM: can't convert, propagate original error
                });
                if (mnemonics.handleLuaException(vm)) continue;
                return error.LuaException;
            }
            return err;
        };
        switch (result) {
            .Continue => {},
            .LoopContinue => {},
            .ReturnVM => |ret| {
                // Top-level return: extract value from ReturnVM and pop frame
                direct_result = switch (ret) {
                    .none => TValue.nil,
                    .single => |v| v,
                    .multiple => |vs| if (vs.len > 0) vs[0] else TValue.nil,
                };
                mnemonics.popCallInfo(vm);
                break;
            },
        }
    }

    // Get result: either from direct return or from result_slot
    const result = direct_result orelse vm.stack[result_slot];

    // GC SAFETY: Restore caller's frame state
    vm.base = saved_base;
    vm.top = saved_top;

    return result;
}
