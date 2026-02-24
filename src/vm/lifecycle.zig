//! VM Lifecycle
//!
//! Initialization and cleanup.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const gc_mod = @import("../runtime/gc/gc.zig");
const object = @import("../runtime/gc/object.zig");
const ThreadStatus = object.ThreadStatus;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const VM = @import("vm.zig").VM;
const vm_gc = @import("gc.zig");

/// Initialize a VM with a shared Runtime.
/// Main thread registers as GC root provider.
/// Coroutine VMs are marked via ThreadObject instead.
pub fn init(rt: *Runtime) !*VM {
    const self = try rt.allocator.create(VM);
    errdefer rt.allocator.destroy(self);

    const is_main = rt.main_thread == null;
    const initial_status: ThreadStatus = if (is_main) .running else .suspended;
    const free_vm: ?*const fn (*anyopaque, std.mem.Allocator) void = if (is_main) null else &vm_gc.vmFreeCallback;

    // mark_vm = null initially; set after VM is initialized to avoid marking undefined fields
    const thread = try rt.gc.allocThread(@ptrCast(self), initial_status, null, free_vm);

    self.* = .{
        .rt = rt,
        .thread = thread,
        .stack = undefined,
        .top = 0,
        .base = 0,
        .ci = null,
        .base_ci = undefined,
        .callstack = undefined,
        .callstack_size = 0,
        .open_upvalues = null,
    };

    for (&self.stack) |*v| {
        v.* = .nil;
    }

    if (!is_main) {
        thread.mark_vm = &vm_gc.vmMarkCallback;
        rt.gc.trackAllocation(@sizeOf(VM));
    }

    if (is_main) {
        try rt.gc.addRootProvider(vm_gc.rootProvider(self));
        rt.gc.setFinalizerExecutor(vm_gc.finalizerExecutor(self));
        rt.setMainThread(thread);
    }

    return self;
}

/// Only called for main thread (via Runtime.deinit).
/// Coroutine VMs are freed by GC when ThreadObject is collected.
pub fn deinit(self: *VM) void {
    const is_main = self.rt.main_thread == self.thread;
    if (is_main) {
        self.rt.gc.setFinalizerExecutor(null);
        self.rt.gc.removeRootProvider(vm_gc.rootProvider(self));
    }
    self.rt.allocator.destroy(self);
}
