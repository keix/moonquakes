//! Field Cache State
//!
//! Small optimization cache for recent field access context and integer
//! representation diagnostics.

const StringObject = @import("../runtime/gc/object.zig").StringObject;
const VM = @import("vm.zig").VM;

pub const FieldCache = struct {
    last_field_reg: ?u8 = null,
    last_field_key: ?*StringObject = null,
    last_field_is_global: bool = false,
    last_field_is_method: bool = false,
    last_field_tick: u64 = 0,
    int_repr_field_key: ?*StringObject = null,
    exec_tick: u64 = 0,
};

pub const LastFieldHint = struct {
    reg: u8,
    key: *StringObject,
    is_global: bool,
    is_method: bool,
};

pub fn reset(vm: *VM) void {
    vm.field_cache.last_field_reg = null;
    vm.field_cache.last_field_key = null;
    vm.field_cache.last_field_is_global = false;
    vm.field_cache.last_field_is_method = false;
    vm.field_cache.last_field_tick = 0;
    vm.field_cache.int_repr_field_key = null;
}

pub fn rememberFieldAccess(vm: *VM, reg: u8, key: *StringObject, is_global: bool, is_method: bool) void {
    vm.field_cache.last_field_reg = reg;
    vm.field_cache.last_field_key = key;
    vm.field_cache.last_field_is_global = is_global;
    vm.field_cache.last_field_is_method = is_method;
    vm.field_cache.last_field_tick = vm.field_cache.exec_tick;
}

pub fn rememberIntReprContext(vm: *VM, reg: u8) void {
    if (vm.field_cache.last_field_reg) |r| {
        if (r == reg) {
            vm.field_cache.int_repr_field_key = vm.field_cache.last_field_key;
        }
    }
}

pub fn clearLastFieldHint(vm: *VM) void {
    vm.field_cache.last_field_key = null;
}

pub fn takeLastFieldHint(vm: *VM) ?LastFieldHint {
    const key = vm.field_cache.last_field_key orelse return null;
    const hint = LastFieldHint{
        .reg = vm.field_cache.last_field_reg orelse 0,
        .key = key,
        .is_global = vm.field_cache.last_field_is_global,
        .is_method = vm.field_cache.last_field_is_method,
    };
    vm.field_cache.last_field_key = null;
    return hint;
}

pub fn takeIntReprFieldKey(vm: *VM) ?*StringObject {
    const key = vm.field_cache.int_repr_field_key orelse return null;
    vm.field_cache.int_repr_field_key = null;
    return key;
}
