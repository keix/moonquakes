// Protected-call bootstrap helpers for pcall/xpcall.
//
// This module owns the synthetic CALL/RETURN frame that gives protected calls a
// normal Lua frame to unwind into, plus the small stack-layout rewrites needed
// for xpcall and tail-called protected calls.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const ExecuteResult = execution.ExecuteResult;
const frame = @import("frame.zig");
const synthetic_frame = @import("synthetic_frame.zig");
const VM = @import("vm.zig").VM;

pub const PreparedXpcall = struct {
    total_args: u32,
    handler: TValue,
};

// Synthetic Lua frame used by pcall/xpcall:
// CALL R0, ... ; RETURN R0, ...
var bootstrap_proto = synthetic_frame.initCallReturnProto("[protected call bootstrap]", 2);

pub fn isBootstrapProto(func: *const object.ProtoObject) bool {
    return func == &bootstrap_proto;
}

pub fn writeSuccessTupleFromStack(vm: *VM, ret_base: u32, nresults: i16, payload_base: u32, payload_count: u32, caller_frame_top: u32) void {
    const expected: u32 = if (nresults < 0) 0 else @intCast(nresults);
    const copy_count: u32 = if (nresults < 0) payload_count else @min(payload_count, expected);

    vm.stack[ret_base] = .{ .boolean = true };
    if (copy_count > 0) {
        for (0..copy_count) |i| {
            vm.stack[ret_base + 1 + i] = vm.stack[payload_base + i];
        }
    }
    if (nresults >= 0 and expected > copy_count) {
        for (vm.stack[ret_base + 1 + copy_count ..][0 .. expected - copy_count]) |*slot| {
            slot.* = .nil;
        }
    }
    vm.top = if (nresults < 0) ret_base + 1 + copy_count else caller_frame_top;
}

pub fn writeErrorTuple(vm: *VM, ret_base: u32, nresults: i16, err_value: TValue, caller_frame_top: u32) void {
    vm.stack[ret_base] = .{ .boolean = false };
    vm.stack[ret_base + 1] = err_value;
    if (nresults >= 0) {
        const expected: u32 = @intCast(nresults);
        if (expected > 1) {
            var i: u32 = 1;
            while (i < expected) : (i += 1) {
                vm.stack[ret_base + 1 + i] = .nil;
            }
        }
    }
    vm.top = if (nresults < 0) ret_base + 2 else caller_frame_top;
}

// Push a synthetic protected frame around the user target so error unwinding
// can land on an ordinary Lua frame.
pub fn dispatch(vm: *VM, ci: *CallInfo, a: u8, total_args: u32, total_results: u32, handler: ?TValue, ret_base: u32) !ExecuteResult {
    const pcall_nresults: i16 = if (total_results > 0) @intCast(total_results - 1) else -1;
    if (total_args == 0) {
        writeErrorTuple(vm, vm.base + a, pcall_nresults, TValue.fromString(try vm.gc().allocString("bad argument #1 to 'pcall' (value expected)")), vm.base + ci.func.maxstacksize);
        return .Continue;
    }

    const call_base = vm.base + a + 1;

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
    current_ci.reset(&bootstrap_proto, null, new_base, ret_base, pcall_nresults, current_ci.previous, 0, 0);
    current_ci.was_tail_called = true;
    current_ci.is_protected = true;
    current_ci.error_handler = handler orelse .nil;
}
