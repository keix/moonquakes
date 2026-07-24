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
const error_state = @import("error_state.zig");
const VM = @import("vm.zig").VM;
const CallInfo = @import("execution.zig").CallInfo;

pub fn rootProvider(self: *VM) RootProvider {
    return RootProvider.init(VM, self, &vmRootProviderVTable);
}

pub const vmRootProviderVTable = RootProvider.VTable{
    .markRoots = vmMarkRoots,
};

fn computeStackExtent(vm: *const VM) u32 {
    // IMPORTANT: Only mark up to vm.top, not base + maxstacksize.
    // Slots beyond top may contain stale leftovers from expired scopes and
    // popped frames; marking them would keep semantically dead values alive
    // (visible through weak tables — gc.lua's weak tests fail if the whole
    // frame window is marked). Frame setup and returns keep vm.top at the
    // frame ceiling during Lua execution, and calls keep live caller
    // registers below the staging area, so [0, top) covers every live slot
    // at allocation points. clearDeadStackSlice below prevents the stale
    // slots from ever surviving a sweep and being re-exposed by a later
    // top raise.
    return vm.top;
}

fn markCallFrames(vm: *const VM, gc_ptr: *GC) void {
    if (vm.ci == null) return;

    // Reentrant executors (CLI -l requires, callValue from natives) push
    // callstack frames before setupMainFrame ever runs; base_ci is still
    // uninitialized then and its func pointer is garbage.
    if (vm.base_ci_valid) {
        if (vm.base_ci.closure) |closure| {
            gc_ptr.mark(&closure.header);
        } else {
            gc_ptr.markProtoObject(@constCast(vm.base_ci.func));
        }
        gc_ptr.markValue(vm.base_ci.error_handler);
        markFrameVarargs(vm, gc_ptr, &vm.base_ci);
    }

    for (vm.callstack[0..vm.callstack_size]) |frame| {
        if (frame.closure) |closure| {
            gc_ptr.mark(&closure.header);
        } else {
            gc_ptr.markProtoObject(@constCast(frame.func));
        }
        gc_ptr.markValue(frame.error_handler);
        markFrameVarargs(vm, gc_ptr, &frame);
    }
}

fn markFrameVarargs(vm: *const VM, gc_ptr: *GC, frame: *const CallInfo) void {
    // A frame's varargs live at vararg_base, ABOVE base + maxstacksize —
    // and above vm.top while a callee is executing. The stack sweep up to
    // vm.top (computeStackExtent) never reaches them, so they must be
    // marked per frame or they are collected while still readable via
    // VARARG after the callee returns.
    if (frame.vararg_count == 0) return;
    for (vm.stack[frame.vararg_base..][0..frame.vararg_count]) |value| {
        gc_ptr.markValue(value);
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
    const inline_count = @min(vm.temp_roots_count, vm.temp_roots_inline.len);
    for (vm.temp_roots_inline[0..inline_count]) |val| {
        gc_ptr.markValue(val);
    }
    const spill_count = vm.temp_roots_count - inline_count;
    for (vm.temp_roots_spill.items[0..spill_count]) |val| {
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

/// PUC's "clear dead stack slice": slots above vm.top hold leftovers from
/// popped frames and expired temporaries. This cycle's sweep may free
/// their referents, and a later top raise (a call, or syncTopForAlloc)
/// would re-expose them to markStack as dangling pointers. Nil everything
/// above the extent — except live vararg regions, which intentionally sit
/// above the frame windows while a callee executes.
///
/// Clearing down to vm.top is safe because every GC entry point keeps the
/// invariant "no live register above vm.top": in-VM allocating opcodes
/// raise top over the frame window first (mnemonics.syncTopForAlloc), and
/// native-call triggers run with top just past the staged args, above all
/// live caller registers.
fn clearDeadStackSlice(vm: *VM, stack_extent: u32) void {
    // Collect live vararg intervals above the extent (sorted by start).
    var starts: [vm.callstack.len + 1]u32 = undefined;
    var ends: [vm.callstack.len + 1]u32 = undefined;
    var n: usize = 0;
    var fi: usize = 0;
    // Like markCallFrames: with no active frame (e.g. a coroutine VM before
    // its first resume) base_ci is uninitialized and there are no varargs.
    const frame_count: usize = if (vm.ci == null) 0 else vm.callstack_size + 1;
    while (fi < frame_count) : (fi += 1) {
        // Same guard as markCallFrames: base_ci may be uninitialized while
        // reentrant frames run before the main chunk is staged.
        if (fi == 0 and !vm.base_ci_valid) continue;
        const frame: *const CallInfo = if (fi == 0) &vm.base_ci else &vm.callstack[fi - 1];
        if (frame.vararg_count == 0) continue;
        const s = frame.vararg_base;
        const e = frame.vararg_base + frame.vararg_count;
        if (e <= stack_extent) continue;
        // Insertion sort by start; frame vararg regions never overlap.
        var j = n;
        while (j > 0 and starts[j - 1] > s) : (j -= 1) {
            starts[j] = starts[j - 1];
            ends[j] = ends[j - 1];
        }
        starts[j] = s;
        ends[j] = e;
        n += 1;
    }

    var pos = stack_extent;
    for (starts[0..n], ends[0..n]) |s, e| {
        const gap_end = @min(@max(s, pos), @as(u32, @intCast(vm.stack.len)));
        @memset(vm.stack[pos..gap_end], TValue.nil);
        pos = @max(pos, e);
    }
    if (pos < vm.stack.len) {
        @memset(vm.stack[pos..], TValue.nil);
    }
}

/// VM marks thread-local state only.
/// Runtime marks globals/registry.
fn vmMarkRoots(ctx: *anyopaque, gc_ptr: *GC) void {
    const vm: *VM = @ptrCast(@alignCast(ctx));
    const stack_extent = computeStackExtent(vm);

    gc_ptr.markStack(vm.stack[0..stack_extent]);
    clearDeadStackSlice(vm, stack_extent);
    markCallFrames(vm, gc_ptr);
    markUpvalues(vm, gc_ptr);
    gc_ptr.markValue(error_state.getRaisedValue(vm));
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
    switch (value.kind()) {
        .nil => stderr_file.writeAll("nil") catch {},
        .boolean => stderr_file.writeAll(if (value.asBool()) "true" else "false") catch {},
        .integer => {
            const i = value.asInt();
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return;
            stderr_file.writeAll(s) catch {};
        },
        .number => {
            const n = value.asFloat();
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
    writeFinalizerWarningValue(stderr_file, error_state.getRaisedValue(vm));
    stderr_file.writeAll(")\n") catch {};
    error_state.clearRaisedValue(vm);
}

pub fn finalizerExecutor(self: *VM) FinalizerExecutor {
    return FinalizerExecutor.init(@ptrCast(self), vmCallValue, vmReportFinalizerError);
}

/// Coroutine VM cleanup (called by GC during sweep)
pub fn vmFreeCallback(vm_ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    vm.temp_roots_spill.deinit(allocator);
    vm.rt.gc.trackDeallocation(@sizeOf(VM));
    allocator.destroy(vm);
}

/// Wrapper to avoid circular import (anyopaque signature)
pub fn vmMarkCallback(vm_ptr: *anyopaque, gc_ptr: *anyopaque) void {
    vmMarkRoots(vm_ptr, @ptrCast(@alignCast(gc_ptr)));
}
