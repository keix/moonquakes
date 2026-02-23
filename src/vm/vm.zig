const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const gc_mod = @import("../runtime/gc/gc.zig");
const GC = gc_mod.GC;
const RootProvider = gc_mod.RootProvider;
const object = @import("../runtime/gc/object.zig");
const call = @import("call.zig");
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const UpvalueObject = object.UpvalueObject;
const ThreadObject = object.ThreadObject;
const ThreadStatus = object.ThreadStatus;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const builtin = @import("../builtin/dispatch.zig");
const metamethod = @import("metamethod.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;

pub const MetamethodKeys = metamethod.MetamethodKeys;

/// VM represents an execution thread (Lua "thread"/coroutine state).
///
/// Architecture: VM references Runtime (shared state) via pointer.
/// Multiple VMs (coroutines) share a single Runtime.
/// VM knows Runtime; Runtime does not know VM.
pub const VM = struct {
    stack: [256]TValue,
    top: u32,
    base: u32,
    ci: ?*CallInfo,
    base_ci: CallInfo,
    callstack: [35]CallInfo,
    callstack_size: u8,
    open_upvalues: ?*UpvalueObject,
    lua_error_value: TValue = .nil,

    // Yield state
    yield_base: u32 = 0,
    yield_count: u32 = 0,
    yield_ret_base: u32 = 0,
    yield_nresults: i32 = 0, // -1 = variable results

    rt: *Runtime,
    thread: *ThreadObject,

    /// Values not yet on stack (REPL, embedder API)
    temp_roots: [8]TValue = [_]TValue{.nil} ** 8,
    temp_roots_count: u8 = 0,

    hook_func: ?*ClosureObject = null,
    hook_mask: u8 = 0, // 1=call, 2=return, 4=line
    hook_count: u32 = 0,

    pub inline fn gc(self: *VM) *GC {
        return self.rt.gc;
    }

    pub inline fn globals(self: *VM) *TableObject {
        return self.rt.globals;
    }

    pub inline fn registry(self: *VM) *TableObject {
        return self.rt.registry;
    }

    pub inline fn getThread(self: *VM) *ThreadObject {
        return self.thread;
    }

    pub inline fn isMainThread(self: *VM) bool {
        return self.rt.main_thread == self.thread;
    }

    /// Initialize a VM with a shared Runtime.
    /// Main thread registers as GC root provider.
    /// Coroutine VMs are marked via ThreadObject instead.
    pub fn init(rt: *Runtime) !*VM {
        const self = try rt.allocator.create(VM);
        errdefer rt.allocator.destroy(self);

        const is_main = rt.main_thread == null;
        const initial_status: ThreadStatus = if (is_main) .running else .suspended;
        const free_vm: ?*const fn (*anyopaque, std.mem.Allocator) void = if (is_main) null else &vmFreeCallback;

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
            thread.mark_vm = &vmMarkCallback;
            rt.gc.trackAllocation(@sizeOf(VM));
        }

        if (is_main) {
            try rt.gc.addRootProvider(self.rootProvider());
            rt.setMainThread(thread);
        }

        return self;
    }

    /// Only called for main thread (via Runtime.deinit).
    /// Coroutine VMs are freed by GC when ThreadObject is collected.
    pub fn deinit(self: *VM) void {
        if (self.isMainThread()) {
            self.rt.gc.removeRootProvider(self.rootProvider());
        }
        self.rt.allocator.destroy(self);
    }

    pub fn closeUpvalues(self: *VM, level: u32) void {
        while (self.open_upvalues) |uv| {
            const uv_level = (@intFromPtr(uv.location) - @intFromPtr(&self.stack[0])) / @sizeOf(TValue);
            if (uv_level < level) break;
            self.open_upvalues = uv.next_open;
            uv.close();
        }
    }

    pub fn getOrCreateUpvalue(self: *VM, location: *TValue) !*UpvalueObject {
        var prev: ?*UpvalueObject = null;
        var current = self.open_upvalues;

        while (current) |uv| {
            if (@intFromPtr(uv.location) == @intFromPtr(location)) {
                return uv;
            }
            if (@intFromPtr(uv.location) < @intFromPtr(location)) {
                break; // List sorted by descending address
            }
            prev = uv;
            current = uv.next_open;
        }

        const new_uv = try self.gc().allocUpvalue(location);
        new_uv.next_open = current;
        if (prev) |p| {
            p.next_open = new_uv;
        } else {
            self.open_upvalues = new_uv;
        }
        return new_uv;
    }

    pub const LuaException = error{LuaException};

    /// Raise with value. pcall/xpcall catches this.
    pub fn raise(self: *VM, value: TValue) LuaException {
        self.lua_error_value = value;
        return error.LuaException;
    }

    /// Raise with string. OutOfMemory is NOT caught by pcall.
    pub fn raiseString(self: *VM, message: []const u8) (LuaException || error{OutOfMemory}) {
        const str = self.gc().allocString(message) catch return error.OutOfMemory;
        return self.raise(TValue.fromString(str));
    }

    pub fn callNative(self: *VM, id: NativeFnId, func_reg: u32, nargs: u32, nresults: u32) !void {
        try builtin.invoke(id, self, func_reg, nargs, nresults);
    }

    pub fn pushTempRoot(self: *VM, value: TValue) bool {
        if (self.temp_roots_count >= self.temp_roots.len) return false;
        self.temp_roots[self.temp_roots_count] = value;
        self.temp_roots_count += 1;
        return true;
    }

    pub fn popTempRoots(self: *VM, n: u8) void {
        if (n > self.temp_roots_count) {
            self.temp_roots_count = 0;
        } else {
            self.temp_roots_count -= n;
        }
        for (self.temp_roots[self.temp_roots_count..]) |*slot| {
            slot.* = .nil;
        }
    }

    pub fn collectGarbage(self: *VM) void {
        const gc_ptr = self.gc();
        const before = gc_ptr.bytes_allocated;
        gc_ptr.collect();
        if (@import("builtin").mode != .ReleaseFast) {
            std.log.info("GC: {} -> {} bytes, next at {}", .{ before, gc_ptr.bytes_allocated, gc_ptr.next_gc });
        }
    }

    pub fn rootProvider(self: *VM) RootProvider {
        return RootProvider.init(VM, self, &vmRootProviderVTable);
    }

    /// Reserve stack slots before GC-triggering operations.
    /// GC only scans slots below vm.top.
    pub inline fn reserveSlots(self: *VM, func_reg: u32, count: u32) void {
        const needed = self.base + func_reg + count;
        if (self.top < needed) self.top = needed;
    }
};

// GC Integration (Internal)
const vmRootProviderVTable = RootProvider.VTable{
    .markRoots = vmMarkRoots,
    .callValue = vmCallValue,
};

fn computeStackExtent(vm: *const VM) u32 {
    var extent = vm.top;
    if (vm.ci != null) {
        const base_max = vm.base_ci.base + vm.base_ci.func.maxstacksize;
        if (base_max > extent) extent = base_max;

        for (vm.callstack[0..vm.callstack_size]) |frame| {
            const frame_max = frame.base + frame.func.maxstacksize;
            if (frame_max > extent) extent = frame_max;
        }
    }
    return extent;
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

/// Coroutine VM cleanup (called by GC during sweep)
fn vmFreeCallback(vm_ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    vm.rt.gc.trackDeallocation(@sizeOf(VM));
    allocator.destroy(vm);
}

/// Wrapper to avoid circular import (anyopaque signature)
fn vmMarkCallback(vm_ptr: *anyopaque, gc_ptr: *anyopaque) void {
    vmMarkRoots(vm_ptr, @ptrCast(@alignCast(gc_ptr)));
}
