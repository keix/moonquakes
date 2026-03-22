//! Error State
//!
//! Error object storage and unwind bookkeeping for VM-level exception flow.

const TValue = @import("../runtime/value.zig").TValue;
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const VM = @import("vm.zig").VM;

pub const ErrorState = struct {
    lua_error_value: TValue = .nil,
    close_metamethod_depth: u8 = 0,
    pending_error_unwind: bool = false,
    pending_error_unwind_ci: ?*CallInfo = null,
    error_handling_depth: u8 = 0,
    pending_error_from_error_builtin: bool = false,
    native_call_depth: u16 = 0,
};

pub fn setRaisedValue(vm: *VM, value: TValue) void {
    vm.errors.lua_error_value = value;
}

pub fn clearRaisedValue(vm: *VM) void {
    vm.errors.lua_error_value = .nil;
}

pub fn beginNativeCall(vm: *VM) void {
    vm.errors.native_call_depth +|= 1;
}

pub fn endNativeCall(vm: *VM) void {
    if (vm.errors.native_call_depth > 0) vm.errors.native_call_depth -= 1;
}

pub fn beginHandling(vm: *VM) void {
    vm.errors.error_handling_depth +|= 1;
}

pub fn endHandling(vm: *VM) void {
    if (vm.errors.error_handling_depth > 0) vm.errors.error_handling_depth -= 1;
}

pub fn setPendingUnwind(vm: *VM, ci: *CallInfo) void {
    vm.errors.pending_error_unwind = true;
    vm.errors.pending_error_unwind_ci = ci;
}

pub fn clearPendingUnwind(vm: *VM) void {
    vm.errors.pending_error_unwind = false;
    vm.errors.pending_error_unwind_ci = null;
}
