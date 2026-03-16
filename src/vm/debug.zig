//! VM Debug Introspection API (read-only)
//!
//! Internal VM-facing helpers used by builtin/debug.
//! Keeps call-frame details (CallInfo) inside vm/ layer.

const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;
const CallInfo = @import("execution.zig").CallInfo;
const VM = @import("vm.zig").VM;
const std = @import("std");

fn getCallInfoAtLevel(self: *VM, level: i64) ?*const CallInfo {
    if (level < 1) return null;
    var ci_opt = self.ci;
    var seen: i64 = 0;
    while (ci_opt) |ci| {
        if (std.mem.eql(u8, ci.func.source, "[coroutine bootstrap]")) {
            ci_opt = ci.previous;
            continue;
        }
        seen += 1;
        if (seen == level) return ci;
        ci_opt = ci.previous;
    }
    return null;
}

pub const DebugFrameInfo = struct {
    closure: ?*ClosureObject,
    current_line: i64,
    istailcall: bool,
    is_main: bool,
    debug_name: ?[]const u8,
    debug_namewhat: ?[]const u8,
};

pub fn debugGetFrameInfoAtLevel(self: *VM, level: i64) ?DebugFrameInfo {
    const ci = getCallInfoAtLevel(self, level) orelse return null;
    const proto = ci.func;
    var current_line: i64 = -1;
    if (proto.code.len > 0 and proto.lineinfo.len > 0) {
        const pc_ptr = @intFromPtr(ci.pc);
        const code_ptr = @intFromPtr(proto.code.ptr);
        if (pc_ptr >= code_ptr) {
            const pc_off_bytes = pc_ptr - code_ptr;
            const pc_off_instr: usize = @intCast(pc_off_bytes / @sizeOf(@TypeOf(proto.code[0])));
            var idx = if (pc_off_instr > 0) pc_off_instr - 1 else pc_off_instr;
            // For suspended coroutines, top frame pc points past YIELD/return boundary.
            // Report line of the yielding instruction (Lua-compatible currentline).
            if (self.thread.status == .suspended and self.ci != null and ci == self.ci.? and idx > 0) {
                idx -= 1;
            }
            const safe_idx = @min(idx, proto.lineinfo.len - 1);
            current_line = @intCast(proto.lineinfo[safe_idx]);
        }
    }
    return .{
        .closure = ci.closure,
        .current_line = current_line,
        .istailcall = ci.was_tail_called,
        .is_main = (ci.previous == null),
        .debug_name = ci.debug_name,
        .debug_namewhat = ci.debug_namewhat,
    };
}

pub const DebugLocalMeta = struct {
    is_for_state: bool,
};

/// Best-effort function name inference from caller frame locals.
/// For debug.getinfo(level): inspect frame at level+1 and try to find a local
/// whose value is exactly the closure of frame `level`.
pub fn debugInferFunctionNameAtLevel(self: *VM, level: i64, target_closure: *ClosureObject) ?[]const u8 {
    if (level < 1) return null;
    const caller = getCallInfoAtLevel(self, level + 1) orelse return null;

    var found: ?[]const u8 = null;
    var r: usize = 0;
    while (r < caller.func.local_reg_names.len) : (r += 1) {
        const name = caller.func.local_reg_names[r] orelse continue;
        const stack_pos = caller.base + @as(u32, @intCast(r));
        if (stack_pos >= self.stack.len) break;
        const clo = self.stack[stack_pos].asClosure() orelse continue;
        if (clo != target_closure) continue;
        if (found == null) {
            found = name;
        } else if (!std.mem.eql(u8, found.?, name)) {
            // Ambiguous in caller scope.
            return null;
        }
    }

    return found;
}

/// Write local value at (level, local_idx) directly into caller frame dst slot.
/// Returns metadata used by debug library (currently only generic-for marker).
pub fn debugWriteLocalAtLevel(self: *VM, level: i64, local_idx: u32, dst_slot: u32) ?DebugLocalMeta {
    const ci = getCallInfoAtLevel(self, level) orelse return null;
    if (local_idx >= ci.func.maxstacksize) return null;
    const stack_pos = ci.base + local_idx;
    self.stack[self.base + dst_slot] = self.stack[stack_pos];

    var is_for_state = false;
    if (ci.getHighestTBC(0)) |tbc_reg| {
        const reg_idx: u8 = @intCast(local_idx);
        const start = tbc_reg -| 3;
        is_for_state = reg_idx >= start and reg_idx <= tbc_reg;
    }

    return .{
        .is_for_state = is_for_state,
    };
}
