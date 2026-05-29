//! VM Public API
//!
//! Accessors, upvalue management, error handling, and GC operations.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const native_mod = @import("../runtime/native.zig");
const CFunction = native_mod.CFunction;
const NativeClosureObject = object.NativeClosureObject;
const CClosureObject = object.CClosureObject;
const gc_mod = @import("../runtime/gc/gc.zig");
const GC = gc_mod.GC;
const object = @import("../runtime/gc/object.zig");
const TableObject = object.TableObject;
const UpvalueObject = object.UpvalueObject;
const ThreadObject = object.ThreadObject;
const builtin_dispatch = @import("../builtin/dispatch.zig");
const error_state = @import("error_state.zig");
const VM = @import("vm.zig").VM;

const CApiState = struct {
    vm: *VM,
};

pub fn gc(self: *VM) *GC {
    return self.rt.gc;
}

pub fn globals(self: *VM) *TableObject {
    return self.rt.globals;
}

pub fn registry(self: *VM) *TableObject {
    return self.rt.registry;
}

pub fn getThread(self: *VM) *ThreadObject {
    return self.thread;
}

pub fn isMainThread(self: *VM) bool {
    return self.rt.main_thread == self.thread;
}

pub fn closeUpvalues(self: *VM, level: u32) void {
    while (self.open_upvalues) |uv| {
        const uv_level = (@intFromPtr(uv.location) - @intFromPtr(&self.stack[0])) / @sizeOf(TValue);
        if (uv_level < level) break;
        self.open_upvalues = uv.next_open;
        uv.close();
        self.gc().barrierBackValue(&uv.header, uv.closed);
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
            break;
        }
        prev = uv;
        current = uv.next_open;
    }

    const new_uv = try gc(self).allocUpvalue(location, self.thread);
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
    error_state.setRaisedValue(self, value);
    return error.LuaException;
}

/// Raise with string. OutOfMemory is NOT caught by pcall.
pub fn raiseString(self: *VM, message: []const u8) (LuaException || error{OutOfMemory}) {
    const str = gc(self).allocString(message) catch return error.OutOfMemory;
    return raise(self, TValue.fromString(str));
}

pub fn callNative(self: *VM, nc: *NativeClosureObject, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Clear slots that may become results without clobbering incoming arguments.
    // Native call layout is [func_reg]=callee/self, [func_reg+1 .. func_reg+nargs]=args.
    // Some natives read func_reg as self (e.g., __call handlers), so do not clear it.
    if (nresults > 0) {
        const base_slot = self.base + func_reg;
        const args_end = base_slot + 1 + nargs;
        const result_end = base_slot + nresults;
        if (result_end > args_end) {
            for (self.stack[args_end..result_end]) |*slot| {
                slot.* = .nil;
            }
        }
    }
    error_state.beginNativeCall(self);
    defer {
        error_state.endNativeCall(self);
    }
    try builtin_dispatch.invoke(nc.func.id, self, func_reg, nargs, nresults);
}

pub fn callCClosure(self: *VM, cc: *CClosureObject, func_reg: u32, nargs: u32, nresults: u32) !void {
    error_state.beginNativeCall(self);
    defer {
        error_state.endNativeCall(self);
    }
    try invokeCFunction(self, cc.func, func_reg, nargs, nresults);
}

/// Dispatch an external C function registered via `mq_pushcfunction`.
///
/// Stack layout on entry (in the caller's frame):
///   [vm.base + func_reg]      = callable
///   [vm.base + func_reg + 1..] = nargs arguments
///
/// Convention: the C callee sees a frame where index 1 = first arg
/// (`mq_gettop(L) == nargs`). It pushes M results and returns M; the
/// dispatcher transfers the top M slots back into the caller's frame
/// starting at `vm.base + func_reg`. A negative return value raises
/// `error.LuaException` with whatever the callee left on top of its frame
/// (or a synthesized message when the frame is empty).
fn invokeCFunction(
    self: *VM,
    fp: CFunction,
    func_reg: u32,
    nargs: u32,
    nresults: u32,
) !void {
    var fallback_state = CApiState{ .vm = self };
    const state_opaque = self.c_state_opaque orelse @as(*anyopaque, @ptrCast(&fallback_state));

    const caller_base = self.base;
    const callable_slot = caller_base + func_reg;
    const frame_base = callable_slot + 1;

    self.base = frame_base;
    self.top = frame_base + nargs;
    defer self.base = caller_base;

    const returned = fp(state_opaque);

    if (returned < 0) {
        const top_now = self.top;
        const raised: TValue = if (top_now > self.base) self.stack[top_now - 1] else blk: {
            const msg = gc(self).allocString("C function returned error") catch {
                error_state.setRaisedValue(self, .nil);
                self.top = callable_slot;
                return error.LuaException;
            };
            break :blk TValue.fromString(msg);
        };
        error_state.setRaisedValue(self, raised);
        self.top = callable_slot;
        return error.LuaException;
    }

    const claimed: u32 = @intCast(returned);
    const top_now = self.top;
    const available: u32 = if (top_now >= self.base) top_now - self.base else 0;
    const actual = @min(claimed, available);
    const result_src_base = top_now - actual;

    // Move results down to the callable slot in the caller's frame.
    var i: u32 = 0;
    while (i < actual) : (i += 1) {
        self.stack[callable_slot + i] = self.stack[result_src_base + i];
    }

    // Re-publish vm.top so the wrapper (`invokeNativeOnStack`) can read either
    // `top_defined` (uses vm.top) or fixed-count (nil-pads up to nresults).
    if (nresults == 0) {
        self.top = callable_slot + actual;
    } else {
        var pad_to: u32 = callable_slot + actual;
        const target = callable_slot + nresults;
        while (pad_to < target) : (pad_to += 1) {
            self.stack[pad_to] = .nil;
        }
        self.top = target;
    }
}

pub fn pushTempRoot(self: *VM, value: TValue) bool {
    if (self.temp_roots_count < self.temp_roots_inline.len) {
        self.temp_roots_inline[self.temp_roots_count] = value;
        self.temp_roots_count += 1;
        return true;
    }

    self.temp_roots_spill.append(self.rt.allocator, value) catch return false;
    self.temp_roots_count += 1;
    return true;
}

pub fn popTempRoots(self: *VM, n: u8) void {
    const old_count = self.temp_roots_count;
    if (n > self.temp_roots_count) {
        self.temp_roots_count = 0;
    } else {
        self.temp_roots_count -= n;
    }

    const inline_len: u32 = @intCast(self.temp_roots_inline.len);
    const old_inline_count = @min(old_count, inline_len);
    const new_inline_count = @min(self.temp_roots_count, inline_len);
    if (new_inline_count < old_inline_count) {
        for (self.temp_roots_inline[new_inline_count..old_inline_count]) |*slot| {
            slot.* = .nil;
        }
    }

    const old_spill_count = old_count - old_inline_count;
    const new_spill_count = self.temp_roots_count - new_inline_count;
    if (new_spill_count < old_spill_count) {
        for (self.temp_roots_spill.items[new_spill_count..old_spill_count]) |*slot| {
            slot.* = .nil;
        }
        self.temp_roots_spill.items.len = new_spill_count;
    }
}

pub fn collectGarbage(self: *VM) void {
    const gc_ptr = gc(self);
    gc_ptr.collect();
    // Run queued finalizers at this safe point
    gc_ptr.drainFinalizers();
}

/// Reserve stack slots before GC-triggering operations.
/// GC only scans slots below vm.top.
pub fn reserveSlots(self: *VM, func_reg: u32, count: u32) void {
    const needed = self.base + func_reg + count;
    if (self.top < needed) self.top = needed;
}

/// Begin a VM-level GC guard for sensitive sections.
/// Must be paired with endGCGuard(), typically via defer.
pub fn beginGCGuard(self: *VM) void {
    gc(self).inhibitGC();
}

/// End a VM-level GC guard started by beginGCGuard().
pub fn endGCGuard(self: *VM) void {
    gc(self).allowGC();
}
