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
const TableObject = object.TableObject;
const FileObject = object.FileObject;
const UserdataObject = object.UserdataObject;
const ProtoObject = object.ProtoObject;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const Instruction = @import("../compiler/opcodes.zig").Instruction;
const metamethod = @import("metamethod.zig");
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const error_state = @import("error_state.zig");
const mnemonics = @import("mnemonics.zig");
const frame = @import("frame.zig");
const VM = @import("vm.zig").VM;

/// Error type for call operations
pub const CallError = error{
    NotCallable,
    CallStackOverflow,
    OutOfMemory,
};

pub const PreparedLuaCallFrame = struct {
    call_base: u32,
    vararg_base: u32,
    vararg_count: u32,
    frame_top: u32,
};

pub const PreparedNativeCallFrame = struct {
    call_base: u32,
    frame_top: u32,
};

pub const NativeCallResult = union(enum) {
    discard,
    first,
    first_to_abs: u32,
    into: []TValue,
    top_defined,
};

pub const NativeCallOutcome = union(enum) {
    none,
    first: TValue,
    multiple: []const TValue,
};

pub const NativeStackCallOutcome = struct {
    result_base: u32,
    result_end: u32,
    actual_count: u32,
};

pub const NativeReturnTransfer = union(enum) {
    stack: struct {
        start: u32,
        src_base: u32,
        count: u32,
    },
    value: struct {
        start: u32,
        value: TValue,
    },
    values: struct {
        start: u32,
        values: []const TValue,
    },
};

fn getIndexMetatable(vm: *VM, subject: TValue) ?*TableObject {
    if (subject.asTable()) |table| {
        return table.metatable;
    }
    if (subject.asFile()) |file_obj| {
        return file_obj.metatable;
    }
    if (subject.asUserdata()) |ud| {
        return ud.metatable;
    }
    return vm.gc().shared_mt.getForValue(subject);
}

fn lookupIndexValueSyncDepth(vm: *VM, subject: TValue, key: TValue, depth: u16) anyerror!?TValue {
    if (depth >= 2000) return error.InvalidTableOperation;

    if (subject.asTable()) |table| {
        if (table.get(key)) |value| return value;
    }

    const mt = getIndexMetatable(vm, subject) orelse {
        return if (subject.asTable() != null) null else error.NotATable;
    };
    const index_mm = mt.get(TValue.fromString(vm.gc().mm_keys.get(.index))) orelse {
        return if (subject.asTable() != null) null else error.NotATable;
    };

    if (index_mm.asTable()) |_| {
        return try lookupIndexValueSyncDepth(vm, index_mm, key, depth + 1);
    }
    if (index_mm.asClosure() != null or index_mm.asNativeClosure() != null) {
        return try callValueSafe(vm, index_mm, &[_]TValue{ subject, key });
    }

    try mnemonics.raiseIndexValueError(vm, index_mm);
    return error.LuaException;
}

pub fn lookupIndexValueSync(vm: *VM, subject: TValue, key: TValue) anyerror!?TValue {
    return try lookupIndexValueSyncDepth(vm, subject, key, 0);
}

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

pub fn stageLuaCallFrameFromArgs(vm: *VM, closure: *ClosureObject, args: []const TValue, call_base: u32) !PreparedLuaCallFrame {
    const proto = closure.proto;
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
        try frame.ensureStackTop(vm, vararg_base + vararg_count);
        var vi: u32 = 0;
        while (vi < vararg_count) : (vi += 1) {
            vm.stack[vararg_base + vi] = args[proto.numparams + vi];
        }
    }

    return .{
        .call_base = call_base,
        .vararg_base = vararg_base,
        .vararg_count = vararg_count,
        .frame_top = if (vararg_count > 0) vararg_base + vararg_count else call_base + proto.maxstacksize,
    };
}

pub fn stageLuaCallFrameFromStack(vm: *VM, closure: *ClosureObject, call_base: u32, nargs: u32) !PreparedLuaCallFrame {
    const proto = closure.proto;

    if (proto.is_vararg and nargs > proto.numparams) {
        const vararg_count = nargs - proto.numparams;
        const min_vararg_base = call_base + proto.maxstacksize;
        const vararg_base = @max(min_vararg_base, vm.top) + 32;
        try frame.ensureStackTop(vm, vararg_base + vararg_count);

        var i: u32 = vararg_count;
        while (i > 0) {
            i -= 1;
            vm.stack[vararg_base + i] = vm.stack[call_base + 1 + proto.numparams + i];
        }

        const params_to_copy = @min(nargs, @as(u32, proto.numparams));
        if (params_to_copy > 0) {
            var pi: u32 = 0;
            while (pi < params_to_copy) : (pi += 1) {
                vm.stack[call_base + pi] = vm.stack[call_base + 1 + pi];
            }
        }

        if (nargs < proto.numparams) {
            for (vm.stack[call_base + nargs ..][0 .. proto.numparams - nargs]) |*slot| {
                slot.* = .nil;
            }
        }

        return .{
            .call_base = call_base,
            .vararg_base = vararg_base,
            .vararg_count = vararg_count,
            .frame_top = vararg_base + vararg_count,
        };
    }

    const params_to_copy = @min(nargs, @as(u32, proto.numparams));
    if (params_to_copy > 0) {
        var i: u32 = 0;
        while (i < params_to_copy) : (i += 1) {
            vm.stack[call_base + i] = vm.stack[call_base + 1 + i];
        }
    }
    var i: u32 = params_to_copy;
    while (i < proto.numparams) : (i += 1) {
        vm.stack[call_base + i] = .nil;
    }

    return .{
        .call_base = call_base,
        .vararg_base = 0,
        .vararg_count = 0,
        .frame_top = call_base + proto.maxstacksize,
    };
}

pub fn activateLuaCallFrame(
    vm: *VM,
    closure: *ClosureObject,
    prepared: PreparedLuaCallFrame,
    ret_base: u32,
    nresults: i16,
) !*CallInfo {
    const ci = try mnemonics.pushCallInfoVararg(
        vm,
        closure.proto,
        closure,
        prepared.call_base,
        ret_base,
        nresults,
        prepared.vararg_base,
        prepared.vararg_count,
    );
    vm.top = prepared.frame_top;
    return ci;
}

pub fn stageNativeCallFrame(vm: *VM, callable: TValue, args: []const TValue, call_base: u32) PreparedNativeCallFrame {
    vm.stack[call_base] = callable;
    for (args, 0..) |arg, i| {
        vm.stack[call_base + 1 + @as(u32, @intCast(i))] = arg;
    }
    const frame_top = call_base + 1 + @as(u32, @intCast(args.len));
    vm.top = frame_top;
    return .{ .call_base = call_base, .frame_top = frame_top };
}

pub fn invokeNativeOnStack(
    vm: *VM,
    nc: *NativeClosureObject,
    func_slot: u32,
    nargs: u32,
    requested_results: u32,
    top_defined: bool,
) !NativeStackCallOutcome {
    try vm.callNative(nc.func.id, func_slot, nargs, requested_results);

    const result_base = vm.base + func_slot;
    if (top_defined) {
        const result_end = vm.top;
        return .{
            .result_base = result_base,
            .result_end = result_end,
            .actual_count = if (result_end > result_base) result_end - result_base else 0,
        };
    }

    if (requested_results > 0 and vm.top == result_base) {
        for (vm.stack[result_base .. result_base + requested_results]) |*slot| {
            slot.* = .nil;
        }
        vm.top = result_base + requested_results;
    }

    return .{
        .result_base = result_base,
        .result_end = result_base + requested_results,
        .actual_count = requested_results,
    };
}

pub fn describeNativeReturnTransfer(
    id: NativeFnId,
    native_call_args: []const TValue,
    stack_result: NativeStackCallOutcome,
) NativeReturnTransfer {
    switch (id) {
        .math_sin => {
            const arg = if (native_call_args.len > 0) native_call_args[0].toNumber() orelse 0 else 0;
            return .{ .value = .{
                .start = 2,
                .value = TValue{ .number = std.math.sin(arg) },
            } };
        },
        .select => {
            var idx_u: u32 = 1;
            if (native_call_args.len > 0) {
                const idx_val = native_call_args[0].toInteger() orelse 1;
                if (idx_val >= 1) idx_u = @intCast(idx_val);
            }
            const arg_count: u32 = @intCast(native_call_args.len);
            const native_transfer_count: u32 = if (arg_count >= idx_u) arg_count - idx_u else 0;
            const src_idx: usize = @min(@as(usize, @intCast(idx_u)), native_call_args.len);
            return .{ .values = .{
                .start = idx_u + 1,
                .values = native_call_args[src_idx .. src_idx + @as(usize, @intCast(native_transfer_count))],
            } };
        },
        else => return .{ .stack = .{
            .start = 2,
            .src_base = stack_result.result_base + 1,
            .count = if (stack_result.actual_count > 0) stack_result.actual_count - 1 else 0,
        } },
    }
}

pub fn callNativeWithResult(
    vm: *VM,
    callable: TValue,
    nc: *NativeClosureObject,
    args: []const TValue,
    result: NativeCallResult,
) !NativeCallOutcome {
    const prepared = stageNativeCallFrame(vm, callable, args, vm.top);
    defer vm.top = prepared.call_base;

    const requested_results: u32 = switch (result) {
        .discard => 0,
        .first, .first_to_abs => 1,
        .into => |out| @intCast(out.len),
        .top_defined => 0,
    };
    const stack_result = try invokeNativeOnStack(
        vm,
        nc,
        @intCast(prepared.call_base - vm.base),
        @intCast(args.len),
        requested_results,
        result == .top_defined,
    );

    switch (result) {
        .discard => return .none,
        .first => return .{ .first = vm.stack[stack_result.result_base] },
        .first_to_abs => |ret_abs| {
            vm.stack[ret_abs] = vm.stack[stack_result.result_base];
            return .none;
        },
        .into => |out| {
            var i: usize = 0;
            while (i < out.len) : (i += 1) {
                out[i] = vm.stack[stack_result.result_base + @as(u32, @intCast(i))];
            }
            return .none;
        },
        .top_defined => return .{ .multiple = vm.stack[stack_result.result_base..stack_result.result_end] },
    }
}

fn cleanupRunState(vm: *VM, saved_depth: u8, saved_base: u32, saved_top: u32) void {
    while (vm.callstack_size > saved_depth) {
        mnemonics.popCallInfo(vm);
    }
    vm.base = saved_base;
    vm.top = saved_top;
}

// Reentrant call helpers translate shared LuaException semantics into the
// HandledException/LuaException boundary used by callValue*.
fn handleLuaExceptionAtDepth(vm: *VM, saved_depth: u8) error{Yield}!mnemonics.LuaExceptionDisposition {
    return try mnemonics.classifyLuaException(vm, saved_depth);
}

fn convertVmRuntimeErrorToLuaException(vm: *VM, inst: Instruction, err: anyerror) !void {
    var msg_buf: [128]u8 = undefined;
    const msg = mnemonics.formatVmRuntimeErrorMessage(vm, inst, err, &msg_buf);
    var full_msg_buf: [320]u8 = undefined;
    const full_msg = mnemonics.runtimeErrorWithCurrentLocation(vm, inst, err, msg, &full_msg_buf);
    vm.errors.lua_error_value = TValue.fromString(try vm.gc().allocString(full_msg));
}

/// Reentrant-safe call entry for native code executing inside the VM loop.
/// Ensures temporary call frames are placed above the active frame footprint.
pub fn callValueSafe(vm: *VM, func_val: TValue, args: []const TValue) anyerror!TValue {
    const saved_top = vm.top;

    const safe_base = computeSafeCallBase(vm);
    if (vm.top < safe_base) vm.top = safe_base;

    const result = callValue(vm, func_val, args) catch |err| {
        if (err != error.Yield and err != error.HandledException) vm.top = saved_top;
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
        if (err != error.Yield and err != error.HandledException) vm.top = saved_top;
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
        if (err != error.Yield and err != error.HandledException) vm.top = saved_top;
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
        vm.base = call_base;
        defer {
            vm.base = saved_base;
            vm.top = saved_top;
        }

        return switch (try callNativeWithResult(vm, self, nc, args, .first)) {
            .first => |value| value,
            else => unreachable,
        };
    }

    // Handle Lua closure __call
    if (func_val.asClosure()) |closure| {
        const proto = closure.proto;

        const saved_base = vm.base;
        const saved_top = vm.top;

        const call_base = vm.top;
        const result_slot = call_base;
        const total_args: u32 = 1 + @as(u32, @intCast(args.len));
        vm.stack[call_base + 1] = self;
        for (args, 0..) |arg, i| {
            vm.stack[call_base + 2 + @as(u32, @intCast(i))] = arg;
        }
        const prepared = try stageLuaCallFrameFromStack(vm, closure, call_base, total_args);
        return runUntilReturn(vm, proto, closure, prepared.call_base, result_slot, saved_base, saved_top, prepared.vararg_base, prepared.vararg_count);
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
    vm.base = call_base;
    defer {
        // Always restore caller frame even if native raises.
        vm.base = saved_base;
        vm.top = saved_top;
    }
    return switch (try callNativeWithResult(vm, TValue.fromNativeClosure(nc), nc, args, .first)) {
        .first => |value| value,
        else => unreachable,
    };
}

fn callNativeClosureInto(vm: *VM, nc: *NativeClosureObject, args: []const TValue, out: []TValue) anyerror!void {
    const saved_base = vm.base;
    const saved_top = vm.top;

    const call_base = vm.top;
    vm.base = call_base;
    defer {
        vm.base = saved_base;
        vm.top = saved_top;
    }
    _ = try callNativeWithResult(vm, TValue.fromNativeClosure(nc), nc, args, .{ .into = out });
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
    const prepared = try stageLuaCallFrameFromArgs(vm, closure, args, call_base);

    // Execute until return, then restore caller's frame state
    return runUntilReturn(vm, proto, closure, prepared.call_base, result_slot, saved_base, saved_top, prepared.vararg_base, prepared.vararg_count);
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
    const prepared = try stageLuaCallFrameFromArgs(vm, closure, args, call_base);

    return runUntilReturnInto(vm, proto, closure, prepared.call_base, result_slot, saved_base, saved_top, prepared.vararg_base, prepared.vararg_count, out);
}

const ReentrantCallResult = union(enum) {
    stack,
    none,
    single: TValue,
    multiple: []const TValue,
};

fn restorePreviousFrame(vm: *VM, saved_depth: u8) bool {
    mnemonics.popCallInfo(vm);
    if (vm.callstack_size == saved_depth) {
        return true;
    }

    const prev_ci = &vm.callstack[vm.callstack_size - 1];
    vm.base = prev_ci.ret_base;
    vm.top = prev_ci.ret_base + prev_ci.func.maxstacksize + prev_ci.vararg_count;
    return false;
}

fn handleCallLoopError(vm: *VM, inst: Instruction, err: anyerror, saved_depth: u8, saved_base: u32, saved_top: u32) anyerror {
    if (err == error.Yield) return error.Yield;
    if (err == error.HandledException) return error.HandledException;
    if (err == error.LuaException) {
        return switch (try handleLuaExceptionAtDepth(vm, saved_depth)) {
            .continue_loop => error.WouldBlock,
            .handled_at_boundary => error.HandledException,
            .unhandled => blk: {
                mnemonics.unwindErrorFramesIgnoringCloseErrors(vm, saved_depth, vm.errors.lua_error_value);
                mnemonics.captureCurrentTracebackSnapshot(vm);
                cleanupRunState(vm, saved_depth, saved_base, saved_top);
                break :blk error.LuaException;
            },
        };
    }
    if (mnemonics.isVmRuntimeError(err)) {
        convertVmRuntimeErrorToLuaException(vm, inst, err) catch |convert_err| {
            cleanupRunState(vm, saved_depth, saved_base, saved_top);
            return convert_err;
        };
        return switch (try handleLuaExceptionAtDepth(vm, saved_depth)) {
            .continue_loop => error.WouldBlock,
            .handled_at_boundary => error.HandledException,
            .unhandled => blk: {
                mnemonics.captureCurrentTracebackSnapshot(vm);
                cleanupRunState(vm, saved_depth, saved_base, saved_top);
                break :blk error.LuaException;
            },
        };
    }
    cleanupRunState(vm, saved_depth, saved_base, saved_top);
    return err;
}

fn runUntilReturnCommon(
    vm: *VM,
    proto: *const ProtoObject,
    closure: *ClosureObject,
    call_base: u32,
    result_slot: u32,
    saved_base: u32,
    saved_top: u32,
    vararg_base: u32,
    vararg_count: u32,
    nresults: i16,
) anyerror!ReentrantCallResult {
    const saved_depth = vm.callstack_size;
    _ = try mnemonics.pushCallInfoVararg(vm, proto, closure, call_base, result_slot, nresults, vararg_base, vararg_count);

    while (vm.callstack_size > saved_depth) {
        if (error_state.hasPendingUnwindAtCurrentFrame(vm)) {
            switch (try handleLuaExceptionAtDepth(vm, saved_depth)) {
                .continue_loop => continue,
                .handled_at_boundary => return error.HandledException,
                .unhandled => {
                    cleanupRunState(vm, saved_depth, saved_base, saved_top);
                    return error.LuaException;
                },
            }
        }

        const ci = &vm.callstack[vm.callstack_size - 1];
        const inst = ci.fetch() catch {
            if (restorePreviousFrame(vm, saved_depth)) break;
            continue;
        };

        const result = mnemonics.do(vm, inst) catch |err| switch (handleCallLoopError(vm, inst, err, saved_depth, saved_base, saved_top)) {
            error.WouldBlock => continue,
            else => |loop_err| return loop_err,
        };

        switch (result) {
            .Continue, .LoopContinue => {},
            .ReturnVM => |ret| {
                _ = restorePreviousFrame(vm, saved_depth);
                return switch (ret) {
                    .none => .none,
                    .single => |v| .{ .single = v },
                    .multiple => |vs| .{ .multiple = vs },
                };
            },
        }
    }

    return .stack;
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
    const result = switch (try runUntilReturnCommon(vm, proto, closure, call_base, result_slot, saved_base, saved_top, vararg_base, vararg_count, 1)) {
        .stack => vm.stack[result_slot],
        .none => TValue.nil,
        .single => |v| v,
        .multiple => |vs| if (vs.len > 0) vs[0] else TValue.nil,
    };

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
    switch (try runUntilReturnCommon(vm, proto, closure, call_base, result_slot, saved_base, saved_top, vararg_base, vararg_count, @intCast(out.len))) {
        .none => {
            var i: usize = 0;
            while (i < out.len) : (i += 1) out[i] = .nil;
        },
        .single => |v| {
            if (out.len > 0) out[0] = v;
            var i: usize = 1;
            while (i < out.len) : (i += 1) out[i] = .nil;
        },
        .multiple => |vs| {
            var i: usize = 0;
            while (i < out.len) : (i += 1) {
                out[i] = if (i < vs.len) vs[i] else .nil;
            }
        },
        .stack => {
            var i: usize = 0;
            while (i < out.len) : (i += 1) {
                out[i] = vm.stack[result_slot + @as(u32, @intCast(i))];
            }
        },
    }

    vm.base = saved_base;
    vm.top = saved_top;
}
