// Protected-call bootstrap helpers for pcall/xpcall.
//
// This module owns the synthetic CALL/RETURN frame that gives protected calls a
// normal Lua frame to unwind into, plus the small stack-layout rewrites needed
// for xpcall and tail-called protected calls.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const object = @import("../runtime/gc/object.zig");
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const ExecuteResult = execution.ExecuteResult;
const frame = @import("frame.zig");
const VM = @import("vm.zig").VM;

pub const PreparedXpcall = struct {
    total_args: u32,
    handler: TValue,
};

// Synthetic Lua frame used by pcall/xpcall:
// CALL R0, ... ; RETURN R0, ...
var bootstrap_code = [_]Instruction{
    Instruction.initABC(.CALL, 0, 0, 0),
    Instruction.initABC(.RETURN, 0, 0, 0),
};
var bootstrap_lineinfo = [_]u32{ 1, 1 };
var bootstrap_proto = object.ProtoObject{
    .header = object.GCObject.init(.proto, null),
    .k = &.{},
    .code = bootstrap_code[0..],
    .protos = &.{},
    .numparams = 0,
    .is_vararg = true,
    .maxstacksize = 2,
    .nups = 0,
    .upvalues = &.{},
    .allocator = std.heap.page_allocator,
    .source = "[protected call bootstrap]",
    .lineinfo = bootstrap_lineinfo[0..],
};

pub fn isBootstrapProto(func: *const object.ProtoObject) bool {
    return func == &bootstrap_proto;
}

// Push a synthetic protected frame around the user target so error unwinding
// can land on an ordinary Lua frame.
pub fn dispatch(vm: *VM, ci: *CallInfo, a: u8, total_args: u32, total_results: u32, handler: ?TValue, ret_base: u32) !ExecuteResult {
    if (total_args == 0) {
        vm.stack[vm.base + a] = .{ .boolean = false };
        vm.stack[vm.base + a + 1] = TValue.fromString(try vm.gc().allocString("bad argument #1 to 'pcall' (value expected)"));
        vm.top = if (total_results == 0) vm.base + a + 2 else vm.base + ci.func.maxstacksize;
        return .Continue;
    }

    const call_base = vm.base + a + 1;
    const user_nresults: u32 = if (total_results > 0) total_results - 1 else 0;
    const pcall_nresults: i16 = if (total_results > 0) @intCast(user_nresults) else -1;

    const new_ci = try frame.pushCallInfoVararg(
        vm,
        &bootstrap_proto,
        null,
        call_base,
        ret_base,
        pcall_nresults,
        0,
        0,
    );
    new_ci.is_protected = true;
    if (handler) |h| new_ci.error_handler = h;

    vm.top = call_base + total_args;
    return .LoopContinue;
}

// xpcall inserts a message handler before the real target. Normalize the stack
// so the protected bootstrap sees just func(...), while preserving the handler.
pub fn prepareXpcall(vm: *VM, a: u8, total_args: u32, fail_base: u32) !PreparedXpcall {
    if (total_args < 2) {
        vm.stack[fail_base] = .{ .boolean = false };
        vm.stack[fail_base + 1] = TValue.fromString(try vm.gc().allocString("bad argument #2 to 'xpcall' (value expected)"));
        return error.InvalidXpcallHandler;
    }

    const handler = vm.stack[vm.base + a + 2];
    const inner_total_args = total_args - 1;
    if (inner_total_args > 1) {
        var i: u32 = 0;
        const shift_count = inner_total_args - 1;
        while (i < shift_count) : (i += 1) {
            vm.stack[vm.base + a + 2 + i] = vm.stack[vm.base + a + 3 + i];
        }
    }

    return .{ .total_args = inner_total_args, .handler = handler };
}

// Tail-called pcall/xpcall reuses the current frame instead of pushing a new
// one, but it still needs the same synthetic bootstrap semantics.
pub fn reuseCurrentFrame(current_ci: *CallInfo, ret_base: u32, total_results: u32, handler: ?TValue, new_base: u32) void {
    const pcall_nresults: i16 = if (total_results > 0)
        @intCast(total_results - 1)
    else
        -1;
    current_ci.func = &bootstrap_proto;
    current_ci.closure = null;
    current_ci.pc = bootstrap_proto.code.ptr;
    current_ci.base = new_base;
    current_ci.ret_base = ret_base;
    current_ci.nresults = pcall_nresults;
    current_ci.was_tail_called = true;
    current_ci.vararg_base = 0;
    current_ci.vararg_count = 0;
    current_ci.is_protected = true;
    current_ci.error_handler = handler orelse .nil;
    current_ci.tbc_bitmap = 0;
    current_ci.pending_return_a = null;
    current_ci.pending_return_count = null;
    current_ci.pending_return_reexec = false;
    current_ci.pending_compare_active = false;
    current_ci.pending_compare_negate = 0;
    current_ci.pending_compare_invert = false;
    current_ci.pending_compare_result_slot = 0;
    current_ci.pending_concat_active = false;
    current_ci.pending_concat_a = 0;
    current_ci.pending_concat_b = 0;
    current_ci.pending_concat_i = -1;
}
