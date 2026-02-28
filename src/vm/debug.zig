//! VM Debug Introspection API (read-only)
//!
//! Internal VM-facing helpers used by builtin/debug.
//! Keeps call-frame details (CallInfo) inside vm/ layer.

const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;
const CallInfo = @import("execution.zig").CallInfo;
const VM = @import("vm.zig").VM;

fn getCallInfoAtLevel(self: *VM, level: i64) ?*const CallInfo {
    if (level < 1) return null;
    var ci_opt = self.ci;
    var remaining: i64 = level - 1;
    while (remaining > 0) : (remaining -= 1) {
        ci_opt = if (ci_opt) |ci| ci.previous else null;
    }
    return ci_opt;
}

pub const DebugFrameInfo = struct {
    closure: ?*ClosureObject,
    current_line: i64,
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
            const idx = if (pc_off_instr > 0) pc_off_instr - 1 else pc_off_instr;
            const safe_idx = @min(idx, proto.lineinfo.len - 1);
            current_line = @intCast(proto.lineinfo[safe_idx]);
        }
    }
    return .{
        .closure = ci.closure,
        .current_line = current_line,
    };
}

pub const DebugLocalMeta = struct {
    is_for_state: bool,
};

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
