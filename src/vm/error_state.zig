//! Error State
//!
//! Error object storage and unwind bookkeeping for VM-level exception flow.

const TValue = @import("../runtime/value.zig").TValue;
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const VM = @import("vm.zig").VM;

pub const ErrorState = struct {
    // Current raised Lua-visible error object.
    lua_error_value: TValue = .nil,

    // Reentrancy / special-mode depth bookkeeping.
    close_metamethod_depth: u8 = 0,
    error_handling_depth: u8 = 0,
    native_call_depth: u16 = 0,

    // Deferred unwind state when protected error handling yields.
    pending_error_unwind: bool = false,
    pending_error_unwind_ci: ?*CallInfo = null,

    // Traceback hint: last error originated from the `error(...)` builtin.
    pending_error_from_error_builtin: bool = false,
};

// Raised-value accessors.
pub fn setRaisedValue(vm: *VM, value: TValue) void {
    vm.errors.lua_error_value = value;
}

pub fn getRaisedValue(vm: *const VM) TValue {
    return vm.errors.lua_error_value;
}

pub fn takeRaisedValue(vm: *VM) TValue {
    const value = vm.errors.lua_error_value;
    clearRaisedValue(vm);
    return value;
}

pub fn clearRaisedValue(vm: *VM) void {
    vm.errors.lua_error_value = .nil;
}

// Native-call depth tracks yieldability around native frames.
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

// Protected unwind state.
pub fn setPendingUnwind(vm: *VM, ci: *CallInfo) void {
    vm.errors.pending_error_unwind = true;
    vm.errors.pending_error_unwind_ci = ci;
}

pub fn clearPendingUnwind(vm: *VM) void {
    vm.errors.pending_error_unwind = false;
    vm.errors.pending_error_unwind_ci = null;
}

// Pending unwind only becomes actionable once execution returns to the frame
// that previously yielded during protected error handling.
pub fn hasPendingUnwindAtCurrentFrame(vm: *const VM) bool {
    return vm.errors.pending_error_unwind and
        vm.errors.pending_error_unwind_ci != null and
        vm.ci == vm.errors.pending_error_unwind_ci.?;
}

pub fn beginCloseMetamethod(vm: *VM) void {
    vm.errors.close_metamethod_depth +|= 1;
}

pub fn endCloseMetamethod(vm: *VM) void {
    if (vm.errors.close_metamethod_depth > 0) vm.errors.close_metamethod_depth -= 1;
}

pub fn isClosingMetamethod(vm: *const VM) bool {
    return vm.errors.close_metamethod_depth > 0;
}

// `error(...)` marks traceback formatting so the explicit error site can be
// preferred over wrapper frames.
pub fn markErrorBuiltin(vm: *VM) void {
    vm.errors.pending_error_from_error_builtin = true;
}

pub fn takeErrorBuiltinFlag(vm: *VM) bool {
    const flag = vm.errors.pending_error_from_error_builtin;
    vm.errors.pending_error_from_error_builtin = false;
    return flag;
}
