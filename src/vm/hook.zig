//! Hook State Helpers
//!
//! Small state-manipulation helpers for debug hook listener checks and
//! transfer-buffer management. Dispatch logic remains in `mnemonics.zig`.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("vm.zig").VM;

pub fn clearTransfer(vm: *VM) void {
    if (vm.hooks.in_hook) return;
    vm.hooks.transfer_start = 1;
    vm.hooks.transfer_count = 0;
    for (&vm.hooks.transfer_values) |*slot| slot.* = .nil;
}

pub inline fn hasCallListener(vm: *const VM) bool {
    return !vm.hooks.in_hook and (vm.hooks.mask & 0x01) != 0 and vm.hooks.func != null;
}

pub inline fn hasReturnListener(vm: *const VM) bool {
    return !vm.hooks.in_hook and (vm.hooks.mask & 0x02) != 0 and vm.hooks.func != null;
}

pub fn setTransferFromStack(vm: *VM, start: u32, src_base: u32, count: u32) void {
    if (vm.hooks.in_hook) return;
    vm.hooks.transfer_start = start;
    const cap: usize = vm.hooks.transfer_values.len;
    const n: usize = @min(@as(usize, @intCast(count)), cap);
    vm.hooks.transfer_count = @intCast(n);
    for (&vm.hooks.transfer_values) |*slot| slot.* = .nil;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        vm.hooks.transfer_values[i] = vm.stack[src_base + @as(u32, @intCast(i))];
    }
}

pub fn setTransferFromValues(vm: *VM, start: u32, values: []const TValue) void {
    if (vm.hooks.in_hook) return;
    vm.hooks.transfer_start = start;
    const n: usize = @min(values.len, vm.hooks.transfer_values.len);
    vm.hooks.transfer_count = @intCast(n);
    for (&vm.hooks.transfer_values) |*slot| slot.* = .nil;
    for (values[0..n], 0..) |v, i| {
        vm.hooks.transfer_values[i] = v;
    }
}
