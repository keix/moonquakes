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

    // Not a function - this is an error in Lua semantics
    return CallError.NotCallable;
}

/// Call a native closure with arguments.
/// Native closures use a different calling convention than Lua closures.
fn callNativeClosure(vm: *VM, nc: *NativeClosureObject, args: []const TValue) anyerror!TValue {
    const call_base = vm.top;
    const result_slot = call_base;

    // Native closures expect: [func_placeholder, arg0, arg1, ...]
    // Set up stack
    vm.stack[call_base] = TValue.fromNativeClosure(nc);
    for (args, 0..) |arg, i| {
        vm.stack[call_base + 1 + @as(u32, @intCast(i))] = arg;
    }

    vm.top = call_base + 1 + @as(u32, @intCast(args.len));

    // Call native function
    try vm.callNative(nc.func.id, 0, @intCast(args.len), 1);

    return vm.stack[result_slot];
}

/// Call a Lua closure with arguments.
/// Executes synchronously until the function returns.
fn callClosure(vm: *VM, closure: *ClosureObject, args: []const TValue) anyerror!TValue {
    const proto = closure.proto;
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

    // Execute until return
    return runUntilReturn(vm, proto, closure, call_base, result_slot);
}

/// Execute a Lua function until it returns to saved call depth.
/// This is the core reentrant execution loop.
fn runUntilReturn(
    vm: *VM,
    proto: *const @import("../compiler/proto.zig").Proto,
    closure: *ClosureObject,
    call_base: u32,
    result_slot: u32,
) anyerror!TValue {
    // Save current call depth for reentrancy
    const saved_depth = vm.callstack_size;

    // Push call info
    _ = try mnemonics.pushCallInfo(vm, proto, closure, call_base, result_slot, 1);

    // Execute until we return to saved depth
    while (vm.callstack_size > saved_depth) {
        const ci = &vm.callstack[vm.callstack_size - 1];
        const inst = ci.fetch() catch {
            // End of function - clean up
            vm.base = ci.ret_base;
            vm.top = ci.ret_base + 1;
            mnemonics.popCallInfo(vm);
            continue;
        };
        switch (try mnemonics.do(vm, inst)) {
            .Continue => {},
            .LoopContinue => {},
            .ReturnVM => break,
        }
    }

    return vm.stack[result_slot];
}
