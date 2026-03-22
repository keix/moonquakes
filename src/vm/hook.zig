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

pub fn dispatchLine(vm: *VM, line: i64, invoke: anytype) !void {
    if (vm.hooks.in_hook) return;
    if ((vm.hooks.mask & 0x04) == 0) return;
    const hook = vm.hooks.func orelse return;
    if (line <= 0) return;
    if (vm.hooks.skip_next_line) return;

    const event_name = try vm.gc().allocString("line");
    const saved_top = vm.top;
    const saved_in_hook = vm.hooks.in_hook;
    vm.hooks.in_hook = true;
    defer {
        vm.hooks.in_hook = saved_in_hook;
        vm.top = saved_top;
    }

    _ = try invoke(vm, hook, &[_]TValue{
        TValue.fromString(event_name),
        .{ .integer = line },
    });
}

pub fn dispatchLineNil(vm: *VM, invoke: anytype) !void {
    if (vm.hooks.in_hook) return;
    if ((vm.hooks.mask & 0x04) == 0) return;
    const hook = vm.hooks.func orelse return;

    const event_name = try vm.gc().allocString("line");
    const saved_top = vm.top;
    const saved_in_hook = vm.hooks.in_hook;
    vm.hooks.in_hook = true;
    defer {
        vm.hooks.in_hook = saved_in_hook;
        vm.top = saved_top;
    }

    vm.hooks.skip_next_line = true;
    _ = try invoke(vm, hook, &[_]TValue{
        TValue.fromString(event_name),
        .nil,
    });
}

pub fn dispatchCount(vm: *VM, invoke: anytype) !void {
    if (vm.hooks.in_hook) return;
    if (vm.hooks.count == 0) return;
    const hook = vm.hooks.func orelse return;

    const event_name = try vm.gc().allocString("count");
    const saved_top = vm.top;
    const saved_in_hook = vm.hooks.in_hook;
    vm.hooks.in_hook = true;
    defer {
        vm.hooks.in_hook = saved_in_hook;
        vm.top = saved_top;
    }

    _ = try invoke(vm, hook, &[_]TValue{TValue.fromString(event_name)});
}

pub fn dispatchCall(vm: *VM, name_override: ?[]const u8, invoke: anytype) !void {
    if (vm.hooks.in_hook) return;
    if ((vm.hooks.mask & 0x01) == 0) return;
    const hook = vm.hooks.func orelse return;

    const event_name = try vm.gc().allocString("call");
    const saved_name_override = vm.hooks.name_override;
    const saved_top = vm.top;
    const saved_in_hook = vm.hooks.in_hook;
    vm.hooks.last_line = -1;
    vm.hooks.name_override = name_override;
    vm.hooks.in_hook = true;
    defer {
        vm.hooks.name_override = saved_name_override;
        vm.hooks.in_hook = saved_in_hook;
        vm.top = saved_top;
    }

    _ = try invoke(vm, hook, &[_]TValue{TValue.fromString(event_name)});
}

pub fn dispatchTailCall(vm: *VM, name_override: ?[]const u8, invoke: anytype) !void {
    if (vm.hooks.in_hook) return;
    if ((vm.hooks.mask & 0x01) == 0) return;
    const hook = vm.hooks.func orelse return;

    const event_name = try vm.gc().allocString("tail call");
    const saved_name_override = vm.hooks.name_override;
    const saved_top = vm.top;
    const saved_in_hook = vm.hooks.in_hook;
    vm.hooks.last_line = -1;
    vm.hooks.name_override = name_override;
    vm.hooks.in_hook = true;
    defer {
        vm.hooks.name_override = saved_name_override;
        vm.hooks.in_hook = saved_in_hook;
        vm.top = saved_top;
    }

    _ = try invoke(vm, hook, &[_]TValue{TValue.fromString(event_name)});
}

pub fn dispatchReturn(vm: *VM, name_override: ?[]const u8, close_name_override: ?[]const u8, invoke: anytype) !void {
    if (vm.hooks.in_hook) return;
    if ((vm.hooks.mask & 0x02) == 0) return;
    const hook = vm.hooks.func orelse return;
    if (name_override == null) {
        if (vm.ci) |ci| {
            if (ci.closure == null) return;
        }
    }

    const event_name = try vm.gc().allocString("return");
    const effective_name = if (name_override) |n| n else close_name_override;
    const saved_name_override = vm.hooks.name_override;
    const saved_top = vm.top;
    const saved_in_hook = vm.hooks.in_hook;
    vm.hooks.last_line = -1;
    vm.hooks.name_override = effective_name;
    vm.hooks.in_hook = true;
    defer {
        vm.hooks.name_override = saved_name_override;
        vm.hooks.in_hook = saved_in_hook;
        vm.top = saved_top;
    }

    _ = try invoke(vm, hook, &[_]TValue{TValue.fromString(event_name)});
}

pub fn dispatchReturnOnYield(vm: *VM, invoke: anytype) !void {
    try dispatchReturn(vm, null, if (vm.errors.close_metamethod_depth > 0) "close" else null, invoke);
}
