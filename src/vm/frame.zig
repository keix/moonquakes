//! Call Frame Helpers
//!
//! Stack-frame push/pop helpers and stack extent checks used by the execution loop.

const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;
const ProtoObject = object.ProtoObject;
const call_debug = @import("call_debug.zig");
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const field_cache = @import("field_cache.zig");
const VM = @import("vm.zig").VM;

pub fn pushCallInfo(vm: *VM, func: *const ProtoObject, closure: ?*ClosureObject, base: u32, ret_base: u32, nresults: i16) !*CallInfo {
    return pushCallInfoVararg(vm, func, closure, base, ret_base, nresults, 0, 0);
}

pub fn pushCallInfoVararg(vm: *VM, func: *const ProtoObject, closure: ?*ClosureObject, base: u32, ret_base: u32, nresults: i16, vararg_base: u32, vararg_count: u32) !*CallInfo {
    if (vm.callstack_size >= vm.callstack.len) {
        return error.CallStackOverflow;
    }

    const new_ci = &vm.callstack[vm.callstack_size];
    new_ci.* = CallInfo{
        .func = func,
        .closure = closure,
        .pc = func.code.ptr,
        .savedpc = null,
        .base = base,
        .ret_base = ret_base,
        .vararg_base = vararg_base,
        .vararg_count = vararg_count,
        .nresults = nresults,
        .previous = vm.ci,
    };
    call_debug.applyToCallInfo(vm, new_ci);

    vm.callstack_size += 1;
    vm.ci = new_ci;
    vm.base = base;
    field_cache.reset(vm);

    return new_ci;
}

pub fn popCallInfo(vm: *VM) void {
    if (vm.ci) |ci| {
        if (vm.callstack_size > 0) {
            vm.callstack_size -= 1;
        }
        if (ci.previous) |prev| {
            vm.ci = prev;
            vm.base = prev.base;
        } else {
            vm.ci = null;
        }
        field_cache.reset(vm);
    }
}

pub fn ensureStackTop(vm: *VM, needed_top: u32) !void {
    const stack_limit: u32 = @intCast(vm.stack.len);
    if (needed_top > stack_limit) return error.CallStackOverflow;
}
