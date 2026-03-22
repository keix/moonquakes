//! Call Debug State
//!
//! Deferred debug naming hints for the next pushed call frame.

const VM = @import("vm.zig").VM;
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;

pub const CallDebugState = struct {
    next_name: ?[]const u8 = null,
    next_namewhat: ?[]const u8 = null,
};

pub fn setNext(vm: *VM, name: []const u8, namewhat: []const u8) void {
    vm.call_debug.next_name = name;
    vm.call_debug.next_namewhat = namewhat;
}

pub fn clearNext(vm: *VM) void {
    vm.call_debug.next_name = null;
    vm.call_debug.next_namewhat = null;
}

pub fn applyToCallInfo(vm: *VM, ci: *CallInfo) void {
    if (vm.call_debug.next_name) |name| {
        ci.debug_name = name;
        ci.debug_namewhat = vm.call_debug.next_namewhat orelse "";
        clearNext(vm);
    }
}
