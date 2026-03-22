//! Yield State
//!
//! Suspension metadata used to resume coroutines after `coroutine.yield`.

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
