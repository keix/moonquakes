//! GC Integration for VM
//!
//! Root provider, mark functions, and GC callbacks.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const gc_mod = @import("../runtime/gc/gc.zig");
const GC = gc_mod.GC;
const RootProvider = gc_mod.RootProvider;
const FinalizerExecutor = gc_mod.FinalizerExecutor;
const object = @import("../runtime/gc/object.zig");
const call = @import("call.zig");
const VM = @import("vm.zig").VM;

pub fn rootProvider(self: *VM) RootProvider {
    return RootProvider.init(VM, self, &vmRootProviderVTable);
}

pub const vmRootProviderVTable = RootProvider.VTable{
    .markRoots = vmMarkRoots,
};

fn computeStackExtent(vm: *const VM) u32 {
    // IMPORTANT: Only mark up to vm.top, not base + maxstacksize.
    // Slots beyond top may contain stale pointers from previous function calls
    // that have already returned. Those objects may have been freed.
    return vm.top;
}

fn markCallFrames(vm: *const VM, gc_ptr: *GC) void {
    if (vm.ci == null) return;

    if (vm.base_ci.closure) |closure| {
        gc_ptr.mark(&closure.header);
    } else {
        gc_ptr.markProtoObject(@constCast(vm.base_ci.func));
    }

    for (vm.callstack[0..vm.callstack_size]) |frame| {
        if (frame.closure) |closure| {
            gc_ptr.mark(&closure.header);
        } else {
            gc_ptr.markProtoObject(@constCast(frame.func));
        }
    }
}

fn markUpvalues(vm: *const VM, gc_ptr: *GC) void {
    var upval = vm.open_upvalues;
    while (upval) |uv| {
        gc_ptr.mark(&uv.header);
        upval = uv.next_open;
    }
}

fn markHooks(vm: *const VM, gc_ptr: *GC) void {
    if (vm.hook_func) |hook| {
        gc_ptr.mark(&hook.header);
    }
}

fn markTempRoots(vm: *const VM, gc_ptr: *GC) void {
    for (vm.temp_roots[0..vm.temp_roots_count]) |val| {
        gc_ptr.markValue(val);
    }
}

/// VM marks thread-local state only.
/// Runtime marks globals/registry.
fn vmMarkRoots(ctx: *anyopaque, gc_ptr: *GC) void {
    const vm: *VM = @ptrCast(@alignCast(ctx));
    const stack_extent = computeStackExtent(vm);

    gc_ptr.markStack(vm.stack[0..stack_extent]);
    markCallFrames(vm, gc_ptr);
    markUpvalues(vm, gc_ptr);
    gc_ptr.markValue(vm.lua_error_value);
    markHooks(vm, gc_ptr);
    markTempRoots(vm, gc_ptr);
}

fn vmCallValue(ctx: *anyopaque, func: *const TValue, args: []const TValue) anyerror!TValue {
    const vm: *VM = @ptrCast(@alignCast(ctx));
    return call.callValue(vm, func.*, args);
}

pub fn finalizerExecutor(self: *VM) FinalizerExecutor {
    return FinalizerExecutor.init(@ptrCast(self), vmCallValue);
}

/// Coroutine VM cleanup (called by GC during sweep)
pub fn vmFreeCallback(vm_ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    vm.rt.gc.trackDeallocation(@sizeOf(VM));
    allocator.destroy(vm);
}

/// Wrapper to avoid circular import (anyopaque signature)
pub fn vmMarkCallback(vm_ptr: *anyopaque, gc_ptr: *anyopaque) void {
    vmMarkRoots(vm_ptr, @ptrCast(@alignCast(gc_ptr)));
}
