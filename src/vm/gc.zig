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
const call_debug = @import("call_debug.zig");
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
    gc_ptr.markValue(vm.base_ci.error_handler);

    for (vm.callstack[0..vm.callstack_size]) |frame| {
        if (frame.closure) |closure| {
            gc_ptr.mark(&closure.header);
        } else {
            gc_ptr.markProtoObject(@constCast(frame.func));
        }
        gc_ptr.markValue(frame.error_handler);
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
    gc_ptr.markValue(vm.hooks.func_value);
    if (vm.hooks.func) |hook| {
        gc_ptr.mark(&hook.header);
    }
}

fn markTempRoots(vm: *const VM, gc_ptr: *GC) void {
    for (vm.temp_roots[0..vm.temp_roots_count]) |val| {
        gc_ptr.markValue(val);
    }
}

fn markTracebackSnapshot(vm: *const VM, gc_ptr: *GC) void {
    const n: usize = @intCast(vm.traceback.snapshot_count);
    for (vm.traceback.snapshot_names[0..n], 0..) |name, i| {
        gc_ptr.markValue(name);
        if (vm.traceback.snapshot_closures[i]) |closure| {
            gc_ptr.mark(&closure.header);
        }
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
    gc_ptr.markValue(vm.errors.lua_error_value);
    markTracebackSnapshot(vm, gc_ptr);
    if (vm.field_cache.last_field_key) |key| {
        gc_ptr.mark(&key.header);
    }
    if (vm.field_cache.int_repr_field_key) |key| {
        gc_ptr.mark(&key.header);
    }
    markHooks(vm, gc_ptr);
    markTempRoots(vm, gc_ptr);
}

fn vmCallValue(ctx: *anyopaque, func: *const TValue, args: []const TValue) anyerror!TValue {
    const vm: *VM = @ptrCast(@alignCast(ctx));
    call_debug.setNext(vm, "__gc", "metamethod");
    defer {
        call_debug.clearNext(vm);
    }
    return call.callValue(vm, func.*, args);
}

fn writeFinalizerWarningValue(stderr_file: std.fs.File, value: TValue) void {
    if (value.asString()) |s| {
        stderr_file.writeAll(s.asSlice()) catch {};
        return;
    }

    var buf: [64]u8 = undefined;
    switch (value) {
        .nil => stderr_file.writeAll("nil") catch {},
        .boolean => |b| stderr_file.writeAll(if (b) "true" else "false") catch {},
        .integer => |i| {
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return;
            stderr_file.writeAll(s) catch {};
        },
        .number => |n| {
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
            stderr_file.writeAll(s) catch {};
        },
        else => stderr_file.writeAll("(error object is not a string)") catch {},
    }
}

fn vmReportFinalizerError(ctx: *anyopaque) void {
    const vm: *VM = @ptrCast(@alignCast(ctx));
    if (!vm.rt.warnings_enabled) return;

    const stderr_file = std.fs.File.stderr();
    stderr_file.writeAll("Lua warning: error in __gc metamethod (") catch return;
    writeFinalizerWarningValue(stderr_file, vm.errors.lua_error_value);
    stderr_file.writeAll(")\n") catch {};
    vm.errors.lua_error_value = .nil;
}

pub fn finalizerExecutor(self: *VM) FinalizerExecutor {
    return FinalizerExecutor.init(@ptrCast(self), vmCallValue, vmReportFinalizerError);
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
