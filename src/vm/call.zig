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

fn computeSafeCallBase(vm: *VM) u32 {
    if (vm.ci) |ci| {
        var safe = ci.base + ci.func.maxstacksize;
        if (ci.vararg_count > 0) {
            safe = @max(safe, ci.vararg_base + ci.vararg_count);
        }
        return @max(vm.top, safe);
    }
    return vm.top;
}

/// Reentrant-safe call entry for native code executing inside the VM loop.
/// Ensures temporary call frames are placed above the active frame footprint.
pub fn callValueSafe(vm: *VM, func_val: TValue, args: []const TValue) anyerror!TValue {
    const saved_top = vm.top;

    const safe_base = computeSafeCallBase(vm);
    if (vm.top < safe_base) vm.top = safe_base;

    const result = callValue(vm, func_val, args) catch |err| {
        if (err != error.Yield) vm.top = saved_top;
        return err;
    };
    vm.top = saved_top;
    return result;
}

/// Reentrant-safe fixed-results call entry.
/// Fills `out` with fixed results (nil-padded as needed).
pub fn callValueInto(vm: *VM, func_val: TValue, args: []const TValue, out: []TValue) anyerror!void {
    const saved_top = vm.top;

    const safe_base = computeSafeCallBase(vm);
    if (vm.top < safe_base) vm.top = safe_base;

    callValueIntoUnsafe(vm, func_val, args, out) catch |err| {
        if (err != error.Yield) vm.top = saved_top;
        return err;
    };
    vm.top = saved_top;
}

/// Reentrant-safe fixed-results call entry that routes Lua return placement to `ret_base`.
/// Useful for native callers that may yield and need results to land in stable VM slots.
pub fn callValueIntoAt(vm: *VM, func_val: TValue, args: []const TValue, out: []TValue, ret_base: u32) anyerror!void {
    const saved_top = vm.top;

    const safe_base = computeSafeCallBase(vm);
    if (vm.top < safe_base) vm.top = safe_base;

    callValueIntoUnsafeAt(vm, func_val, args, out, ret_base) catch |err| {
        if (err != error.Yield) vm.top = saved_top;
        return err;
    };
    vm.top = saved_top;
}

fn callValueIntoUnsafe(vm: *VM, func_val: TValue, args: []const TValue, out: []TValue) anyerror!void {
    if (func_val.asNativeClosure()) |nc| {
        return callNativeClosureInto(vm, nc, args, out);
    }
    if (func_val.asClosure()) |closure| {
        return callClosureInto(vm, closure, args, out);
    }
    if (func_val.asTable()) |table| {
        if (table.metatable) |mt| {
            const call_key = TValue.fromString(vm.gc().mm_keys.get(.call));
            if (mt.get(call_key)) |call_mm| {
                const first = try callWithSelf(vm, call_mm, func_val, args);
                if (out.len > 0) out[0] = first;
                var i: usize = 1;
                while (i < out.len) : (i += 1) out[i] = .nil;
                return;
            }
        }
    }
    return CallError.NotCallable;
}

fn callValueIntoUnsafeAt(vm: *VM, func_val: TValue, args: []const TValue, out: []TValue, ret_base: u32) anyerror!void {
    if (func_val.asNativeClosure()) |nc| {
        // Native closures do not need custom ret_base placement.
        return callNativeClosureInto(vm, nc, args, out);
    }
    if (func_val.asClosure()) |closure| {
        return callClosureIntoWithResultBase(vm, closure, args, out, ret_base);
    }
    if (func_val.asTable()) |table| {
        if (table.metatable) |mt| {
            const call_key = TValue.fromString(vm.gc().mm_keys.get(.call));
            if (mt.get(call_key)) |call_mm| {
                const first = try callWithSelf(vm, call_mm, func_val, args);
                if (out.len > 0) out[0] = first;
                var i: usize = 1;
                while (i < out.len) : (i += 1) out[i] = .nil;
                return;
            }
        }
    }
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
        defer {
            vm.base = saved_base;
            vm.top = saved_top;
        }

        // nargs is args.len + 1 (includes self)
        try vm.callNative(nc.func.id, 0, @as(u32, @intCast(args.len)) + 1, 1);

        const result = vm.stack[result_slot];
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

        // Match CALL vararg frame layout and keep varargs out of the fixed frame scratch area.
        const total_args: u32 = 1 + @as(u32, @intCast(args.len));
        var vararg_base: u32 = 0;
        var vararg_count: u32 = 0;
        if (proto.is_vararg and total_args > proto.numparams) {
            vararg_count = total_args - proto.numparams;
            const min_vararg_base = call_base + proto.maxstacksize;
            vararg_base = @max(min_vararg_base, vm.top) + 32;
            var i: u32 = vararg_count;
            while (i > 0) {
                i -= 1;
                vm.stack[vararg_base + i] = vm.stack[call_base + proto.numparams + i];
            }
        }

        // Fill remaining params with nil (total params = 1 + args.len)
        var i: u32 = total_args;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[call_base + i] = .nil;
        }

        vm.top = if (vararg_count > 0) vararg_base + vararg_count else call_base + proto.maxstacksize;

        return runUntilReturn(vm, proto, closure, call_base, result_slot, saved_base, saved_top, vararg_base, vararg_count);
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
    defer {
        // Always restore caller frame even if native raises.
        vm.base = saved_base;
        vm.top = saved_top;
    }

    // Call native function (func_reg = 0 relative to new vm.base)
    try vm.callNative(nc.func.id, 0, @intCast(args.len), 1);

    // Get result from native frame.
    const result = vm.stack[result_slot];

    return result;
}

fn callNativeClosureInto(vm: *VM, nc: *NativeClosureObject, args: []const TValue, out: []TValue) anyerror!void {
    const saved_base = vm.base;
    const saved_top = vm.top;

    const call_base = vm.top;
    const result_slot = call_base;

    vm.stack[call_base] = TValue.fromNativeClosure(nc);
    for (args, 0..) |arg, i| {
        vm.stack[call_base + 1 + @as(u32, @intCast(i))] = arg;
    }

    vm.base = call_base;
    vm.top = call_base + 1 + @as(u32, @intCast(args.len));
    defer {
        vm.base = saved_base;
        vm.top = saved_top;
    }

    try vm.callNative(nc.func.id, 0, @intCast(args.len), @intCast(out.len));

    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        out[i] = vm.stack[result_slot + @as(u32, @intCast(i))];
    }
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

    const arg_count: u32 = @intCast(args.len);
    const params_to_copy: u32 = @min(arg_count, @as(u32, proto.numparams));

    // Set up fixed parameters
    var i: u32 = 0;
    while (i < params_to_copy) : (i += 1) {
        vm.stack[call_base + i] = args[i];
    }

    // Fill remaining params with nil
    i = params_to_copy;
    while (i < proto.numparams) : (i += 1) {
        vm.stack[call_base + i] = .nil;
    }

    // Match CALL vararg frame layout and keep varargs out of the fixed frame scratch area.
    var vararg_base: u32 = 0;
    var vararg_count: u32 = 0;
    if (proto.is_vararg and arg_count > proto.numparams) {
        vararg_count = arg_count - proto.numparams;
        const min_vararg_base = call_base + proto.maxstacksize;
        vararg_base = @max(min_vararg_base, vm.top) + 32;
        var vi: u32 = 0;
        while (vi < vararg_count) : (vi += 1) {
            vm.stack[vararg_base + vi] = args[proto.numparams + vi];
        }
    }

    vm.top = if (vararg_count > 0) vararg_base + vararg_count else call_base + proto.maxstacksize;

    // Execute until return, then restore caller's frame state
    return runUntilReturn(vm, proto, closure, call_base, result_slot, saved_base, saved_top, vararg_base, vararg_count);
}

fn callClosureInto(vm: *VM, closure: *ClosureObject, args: []const TValue, out: []TValue) anyerror!void {
    return callClosureIntoWithResultBase(vm, closure, args, out, vm.top);
}

fn callClosureIntoWithResultBase(vm: *VM, closure: *ClosureObject, args: []const TValue, out: []TValue, result_slot_override: u32) anyerror!void {
    const proto = closure.proto;

    const saved_base = vm.base;
    const saved_top = vm.top;

    const call_base = vm.top;
    const result_slot = result_slot_override;

    const arg_count: u32 = @intCast(args.len);
    const params_to_copy: u32 = @min(arg_count, @as(u32, proto.numparams));

    var i: u32 = 0;
    while (i < params_to_copy) : (i += 1) {
        vm.stack[call_base + i] = args[i];
    }

    i = params_to_copy;
    while (i < proto.numparams) : (i += 1) {
        vm.stack[call_base + i] = .nil;
    }

    var vararg_base: u32 = 0;
    var vararg_count: u32 = 0;
    if (proto.is_vararg and arg_count > proto.numparams) {
        vararg_count = arg_count - proto.numparams;
        const min_vararg_base = call_base + proto.maxstacksize;
        vararg_base = @max(min_vararg_base, vm.top) + 32;
        var vi: u32 = 0;
        while (vi < vararg_count) : (vi += 1) {
            vm.stack[vararg_base + vi] = args[proto.numparams + vi];
        }
    }

    vm.top = if (vararg_count > 0) vararg_base + vararg_count else call_base + proto.maxstacksize;

    return runUntilReturnInto(vm, proto, closure, call_base, result_slot, saved_base, saved_top, vararg_base, vararg_count, out);
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
    vararg_base: u32,
    vararg_count: u32,
) anyerror!TValue {
    const cleanupOnError = struct {
        fn run(vm2: *VM, saved_depth2: u32, saved_base2: u32, saved_top2: u32) void {
            while (vm2.callstack_size > saved_depth2) {
                mnemonics.popCallInfo(vm2);
            }
            vm2.base = saved_base2;
            vm2.top = saved_top2;
        }
    }.run;

    // Save current call depth for reentrancy
    const saved_depth = vm.callstack_size;

    // Push call info
    _ = try mnemonics.pushCallInfoVararg(vm, proto, closure, call_base, result_slot, 1, vararg_base, vararg_count);

    // Execute until we return to saved depth
    var direct_result: ?TValue = null;
    while (vm.callstack_size > saved_depth) {
        if (vm.pending_error_unwind and vm.pending_error_unwind_ci != null and vm.ci == vm.pending_error_unwind_ci.?) {
            if (try mnemonics.handleLuaException(vm)) continue;
            cleanupOnError(vm, saved_depth, saved_base, saved_top);
            return error.LuaException;
        }
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
            vm.top = prev_ci.ret_base + prev_ci.func.maxstacksize + prev_ci.vararg_count;
            continue;
        };
        const result = mnemonics.do(vm, inst) catch |err| {
            // Preserve call frames on coroutine yield; resume needs intact state.
            if (err == error.Yield) return error.Yield;
            // Handle LuaException by unwinding to protected frames (pcall)
            if (err == error.LuaException and try mnemonics.handleLuaException(vm)) continue;
            if (err == error.LuaException) {
                while (vm.callstack_size > saved_depth) {
                    const unwind_ci = &vm.callstack[vm.callstack_size - 1];
                    mnemonics.closeTBCVariables(vm, unwind_ci, 0, vm.lua_error_value) catch {};
                    vm.closeUpvalues(unwind_ci.base);
                    mnemonics.popCallInfo(vm);
                }
                mnemonics.captureCurrentTracebackSnapshot(vm);
                cleanupOnError(vm, saved_depth, saved_base, saved_top);
                return error.LuaException;
            }
            // Convert VM errors to LuaException for pcall catchability
            if (err == error.CallStackOverflow or
                err == error.ArithmeticError or
                err == error.DivideByZero or
                err == error.ModuloByZero or
                err == error.IntegerRepresentation or
                err == error.OrderComparisonError or
                err == error.LengthError or
                err == error.NotATable or
                err == error.NotAFunction or
                err == error.InvalidTableKey or
                err == error.InvalidTableOperation or
                err == error.InvalidForLoopInit or
                err == error.InvalidForLoopLimit or
                err == error.InvalidForLoopStep or
                err == error.NoCloseMetamethod or
                err == error.FormatError)
            {
                // Set error message and try to handle as LuaException
                var msg_buf: [128]u8 = undefined;
                const msg = switch (err) {
                    error.CallStackOverflow => if (vm.error_handling_depth > 0) "error in error handling" else "stack overflow",
                    error.ArithmeticError => mnemonics.formatArithmeticError(vm, inst, &msg_buf),
                    error.DivideByZero => "divide by zero",
                    error.ModuloByZero => "attempt to perform 'n%0'",
                    error.IntegerRepresentation => mnemonics.formatIntegerRepresentationError(vm, inst, &msg_buf),
                    error.NotATable => mnemonics.formatIndexOnNonTableError(vm, inst, &msg_buf),
                    error.NotAFunction => "attempt to call a non-function value",
                    error.OrderComparisonError => "attempt to compare values",
                    error.LengthError => "attempt to get length of a value",
                    error.InvalidTableKey => "table index is nil or NaN",
                    error.InvalidTableOperation => mnemonics.formatIndexOnNonTableError(vm, inst, &msg_buf),
                    error.InvalidForLoopInit => mnemonics.formatForLoopError(vm, inst, err, &msg_buf),
                    error.InvalidForLoopLimit => mnemonics.formatForLoopError(vm, inst, err, &msg_buf),
                    error.InvalidForLoopStep => mnemonics.formatForLoopError(vm, inst, err, &msg_buf),
                    error.NoCloseMetamethod => mnemonics.formatNoCloseMetamethodError(vm, inst, &msg_buf),
                    error.FormatError => "bad argument to string format",
                    else => "runtime error",
                };
                var full_msg_buf: [320]u8 = undefined;
                const full_msg = mnemonics.runtimeErrorWithCurrentLocation(vm, inst, err, msg, &full_msg_buf);
                vm.lua_error_value = TValue.fromString(vm.gc().allocString(full_msg) catch {
                    cleanupOnError(vm, saved_depth, saved_base, saved_top);
                    return err; // OOM: can't convert, propagate original error
                });
                if (try mnemonics.handleLuaException(vm)) continue;
                mnemonics.captureCurrentTracebackSnapshot(vm);
                cleanupOnError(vm, saved_depth, saved_base, saved_top);
                return error.LuaException;
            }
            cleanupOnError(vm, saved_depth, saved_base, saved_top);
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

fn runUntilReturnInto(
    vm: *VM,
    proto: *const ProtoObject,
    closure: *ClosureObject,
    call_base: u32,
    result_slot: u32,
    saved_base: u32,
    saved_top: u32,
    vararg_base: u32,
    vararg_count: u32,
    out: []TValue,
) anyerror!void {
    const cleanupOnError = struct {
        fn run(vm2: *VM, saved_depth2: u32, saved_base2: u32, saved_top2: u32) void {
            while (vm2.callstack_size > saved_depth2) {
                mnemonics.popCallInfo(vm2);
            }
            vm2.base = saved_base2;
            vm2.top = saved_top2;
        }
    }.run;

    const saved_depth = vm.callstack_size;
    _ = try mnemonics.pushCallInfoVararg(vm, proto, closure, call_base, result_slot, @intCast(out.len), vararg_base, vararg_count);

    var direct_single: ?TValue = null;
    var direct_none = false;
    var direct_written = false;

    while (vm.callstack_size > saved_depth) {
        if (vm.pending_error_unwind and vm.pending_error_unwind_ci != null and vm.ci == vm.pending_error_unwind_ci.?) {
            if (try mnemonics.handleLuaException(vm)) continue;
            cleanupOnError(vm, saved_depth, saved_base, saved_top);
            return error.LuaException;
        }
        const ci = &vm.callstack[vm.callstack_size - 1];
        const inst = ci.fetch() catch {
            mnemonics.popCallInfo(vm);
            if (vm.callstack_size == saved_depth) break;
            const prev_ci = &vm.callstack[vm.callstack_size - 1];
            vm.base = prev_ci.ret_base;
            vm.top = prev_ci.ret_base + prev_ci.func.maxstacksize + prev_ci.vararg_count;
            continue;
        };
        const result = mnemonics.do(vm, inst) catch |err| {
            if (err == error.Yield) return error.Yield;
            if (err == error.LuaException and try mnemonics.handleLuaException(vm)) continue;
            if (err == error.LuaException) {
                while (vm.callstack_size > saved_depth) {
                    const unwind_ci = &vm.callstack[vm.callstack_size - 1];
                    mnemonics.closeTBCVariables(vm, unwind_ci, 0, vm.lua_error_value) catch {};
                    vm.closeUpvalues(unwind_ci.base);
                    mnemonics.popCallInfo(vm);
                }
                mnemonics.captureCurrentTracebackSnapshot(vm);
                cleanupOnError(vm, saved_depth, saved_base, saved_top);
                return error.LuaException;
            }
            // Convert VM errors to LuaException for pcall/xpcall catchability
            if (err == error.CallStackOverflow or
                err == error.ArithmeticError or
                err == error.DivideByZero or
                err == error.ModuloByZero or
                err == error.IntegerRepresentation or
                err == error.OrderComparisonError or
                err == error.LengthError or
                err == error.NotATable or
                err == error.NotAFunction or
                err == error.InvalidTableKey or
                err == error.InvalidTableOperation or
                err == error.InvalidForLoopInit or
                err == error.InvalidForLoopLimit or
                err == error.InvalidForLoopStep or
                err == error.NoCloseMetamethod or
                err == error.FormatError)
            {
                var msg_buf: [128]u8 = undefined;
                const msg = switch (err) {
                    error.CallStackOverflow => if (vm.error_handling_depth > 0) "error in error handling" else "stack overflow",
                    error.ArithmeticError => mnemonics.formatArithmeticError(vm, inst, &msg_buf),
                    error.DivideByZero => "divide by zero",
                    error.ModuloByZero => "attempt to perform 'n%0'",
                    error.IntegerRepresentation => mnemonics.formatIntegerRepresentationError(vm, inst, &msg_buf),
                    error.NotATable => mnemonics.formatIndexOnNonTableError(vm, inst, &msg_buf),
                    error.NotAFunction => "attempt to call a non-function value",
                    error.OrderComparisonError => "attempt to compare values",
                    error.LengthError => "attempt to get length of a value",
                    error.InvalidTableKey => "table index is nil or NaN",
                    error.InvalidTableOperation => mnemonics.formatIndexOnNonTableError(vm, inst, &msg_buf),
                    error.InvalidForLoopInit => mnemonics.formatForLoopError(vm, inst, err, &msg_buf),
                    error.InvalidForLoopLimit => mnemonics.formatForLoopError(vm, inst, err, &msg_buf),
                    error.InvalidForLoopStep => mnemonics.formatForLoopError(vm, inst, err, &msg_buf),
                    error.NoCloseMetamethod => mnemonics.formatNoCloseMetamethodError(vm, inst, &msg_buf),
                    error.FormatError => "bad argument to string format",
                    else => "runtime error",
                };
                var full_msg_buf: [320]u8 = undefined;
                const full_msg = mnemonics.runtimeErrorWithCurrentLocation(vm, inst, err, msg, &full_msg_buf);
                vm.lua_error_value = TValue.fromString(vm.gc().allocString(full_msg) catch {
                    cleanupOnError(vm, saved_depth, saved_base, saved_top);
                    return err;
                });
                if (try mnemonics.handleLuaException(vm)) continue;
                mnemonics.captureCurrentTracebackSnapshot(vm);
                cleanupOnError(vm, saved_depth, saved_base, saved_top);
                return error.LuaException;
            }
            if (err == error.LuaException) {
                mnemonics.captureCurrentTracebackSnapshot(vm);
            }
            cleanupOnError(vm, saved_depth, saved_base, saved_top);
            return err;
        };
        switch (result) {
            .Continue => {},
            .LoopContinue => {},
            .ReturnVM => |ret| {
                switch (ret) {
                    .none => {
                        direct_none = true;
                    },
                    .single => |v| {
                        direct_single = v;
                    },
                    .multiple => |vs| {
                        var i: usize = 0;
                        while (i < out.len) : (i += 1) {
                            out[i] = if (i < vs.len) vs[i] else .nil;
                        }
                        direct_written = true;
                    },
                }
                mnemonics.popCallInfo(vm);
                break;
            },
        }
    }

    if (direct_written) {
        // already copied from ReturnVM.multiple
    } else if (direct_none) {
        var i: usize = 0;
        while (i < out.len) : (i += 1) out[i] = .nil;
    } else if (direct_single) |v| {
        if (out.len > 0) out[0] = v;
        var i: usize = 1;
        while (i < out.len) : (i += 1) out[i] = .nil;
    } else {
        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            out[i] = vm.stack[result_slot + @as(u32, @intCast(i))];
        }
    }

    vm.base = saved_base;
    vm.top = saved_top;
}
