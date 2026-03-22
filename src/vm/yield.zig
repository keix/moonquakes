//! Yield State
//!
//! Suspension metadata used to resume coroutines after `coroutine.yield`.

const TValue = @import("../runtime/value.zig").TValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const VM = @import("vm.zig").VM;

pub const YieldState = struct {
    base: u32 = 0,
    count: u32 = 0,
    ret_base: u32 = 0,
    nresults: i32 = 0, // -1 = variable results
    from_tailcall: bool = false,
};

pub const YieldResult = struct {
    base: u32,
    count: u32,
};

pub fn saveSuspendPoint(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) void {
    vm.yield.base = vm.base + func_reg + 1;
    vm.yield.count = nargs;

    const ci = vm.ci orelse return;
    const is_tailcall_site = blk: {
        const code_start = @intFromPtr(ci.func.code.ptr);
        const pc_addr = @intFromPtr(ci.pc);
        if (pc_addr <= code_start) break :blk false;
        const prev_inst: Instruction = (ci.pc - 1)[0];
        break :blk prev_inst.getOpCode() == .TAILCALL;
    };

    vm.yield.from_tailcall = is_tailcall_site;
    vm.yield.ret_base = if (is_tailcall_site) ci.ret_base else vm.base + func_reg;
    vm.yield.nresults = if (nresults == 0) -1 else @as(i32, @intCast(nresults));
}

pub fn clearTailcallResume(vm: *VM) bool {
    if (!vm.yield.from_tailcall) return false;
    vm.yield.from_tailcall = false;
    return true;
}

pub fn resumeWithValues(vm: *VM, caller_stack: []TValue, arg_base: u32, num_args: u32, pop_call_info: anytype) void {
    if (clearTailcallResume(vm)) {
        const ci = vm.ci orelse return;
        const dst_base = ci.ret_base;
        const nresults = ci.nresults;

        if (ci.previous != null) {
            if (nresults < 0) {
                var i: u32 = 0;
                while (i < num_args) : (i += 1) {
                    vm.stack[dst_base + i] = caller_stack[arg_base + i];
                }
            } else {
                const expected: u32 = @intCast(nresults);
                const copy_count = @min(num_args, expected);
                var i: u32 = 0;
                while (i < copy_count) : (i += 1) {
                    vm.stack[dst_base + i] = caller_stack[arg_base + i];
                }
                while (i < expected) : (i += 1) {
                    vm.stack[dst_base + i] = .nil;
                }
            }
            pop_call_info(vm);
            const caller_frame_max = vm.base + vm.ci.?.func.maxstacksize;
            vm.top = if (nresults < 0) dst_base + num_args else caller_frame_max;
            return;
        }
    }

    const ret_base = vm.yield.ret_base;
    const nres = vm.yield.nresults;

    if (nres < 0) {
        var i: u32 = 0;
        while (i < num_args) : (i += 1) {
            vm.stack[ret_base + i] = caller_stack[arg_base + i];
        }
        vm.top = ret_base + num_args;
    } else {
        const max_copy = @as(u32, @intCast(nres));
        var i: u32 = 0;
        while (i < num_args and i < max_copy) : (i += 1) {
            vm.stack[ret_base + i] = caller_stack[arg_base + i];
        }
        while (i < max_copy) : (i += 1) {
            vm.stack[ret_base + i] = .nil;
        }
    }
}

pub fn currentResult(vm: *const VM) YieldResult {
    return .{
        .base = vm.yield.base,
        .count = vm.yield.count,
    };
}
