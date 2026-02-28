//! VM Public API
//!
//! Accessors, upvalue management, error handling, and GC operations.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const gc_mod = @import("../runtime/gc/gc.zig");
const GC = gc_mod.GC;
const object = @import("../runtime/gc/object.zig");
const TableObject = object.TableObject;
const UpvalueObject = object.UpvalueObject;
const ThreadObject = object.ThreadObject;
const builtin_dispatch = @import("../builtin/dispatch.zig");
const VM = @import("vm.zig").VM;

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

    const new_uv = try gc(self).allocUpvalue(location);
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
    const str = gc(self).allocString(message) catch return error.OutOfMemory;
    return raise(self, TValue.fromString(str));
}

pub fn callNative(self: *VM, id: NativeFnId, func_reg: u32, nargs: u32, nresults: u32) !void {
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
    try builtin_dispatch.invoke(id, self, func_reg, nargs, nresults);
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
