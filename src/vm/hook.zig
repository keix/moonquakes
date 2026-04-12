//! Hook State Helpers
//!
//! Small state-manipulation helpers for debug hook listener checks and
//! transfer-buffer management. Dispatch logic remains in `mnemonics.zig`.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const ClosureObject = @import("../runtime/gc/object.zig").ClosureObject;
const error_state = @import("error_state.zig");
const VM = @import("vm.zig").VM;

pub const HookState = struct {
    func: ?*ClosureObject = null,
    func_value: TValue = .nil,
    mask: u8 = 0, // 1=call, 2=return, 4=line
    count: u32 = 0,
    countdown: u32 = 0,
    in_hook: bool = false,
    transfer_start: u32 = 1,
    transfer_count: u32 = 0,
    transfer_values: [64]TValue = [_]TValue{.nil} ** 64,
    name_override: ?[]const u8 = null,
    skip_next_line: bool = false,
    last_line: i64 = -1,
};

pub const HookTransfer = union(enum) {
    cleared,
    stack: struct {
        start: u32,
        src_base: u32,
        count: u32,
    },
    values: struct {
        start: u32,
        values: []const TValue,
    },
};

fn clearTransfer(vm: *VM) void {
    vm.hooks.transfer_start = 1;
    vm.hooks.transfer_count = 0;
    for (&vm.hooks.transfer_values) |*slot| slot.* = .nil;
}

fn hasCallListener(vm: *const VM) bool {
    return !vm.hooks.in_hook and (vm.hooks.mask & 0x01) != 0 and vm.hooks.func != null;
}

fn hasReturnListener(vm: *const VM) bool {
    return !vm.hooks.in_hook and (vm.hooks.mask & 0x02) != 0 and vm.hooks.func != null;
}

fn setTransferFromStack(vm: *VM, start: u32, src_base: u32, count: u32) void {
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

fn setTransferFromValues(vm: *VM, start: u32, values: []const TValue) void {
    if (vm.hooks.in_hook) return;
    vm.hooks.transfer_start = start;
    const n: usize = @min(values.len, vm.hooks.transfer_values.len);
    vm.hooks.transfer_count = @intCast(n);
    for (&vm.hooks.transfer_values) |*slot| slot.* = .nil;
    for (values[0..n], 0..) |v, i| {
        vm.hooks.transfer_values[i] = v;
    }
}

fn applyTransfer(vm: *VM, transfer: HookTransfer) void {
    if (vm.hooks.in_hook) return;
    switch (transfer) {
        .cleared => clearTransfer(vm),
        .stack => |stack| setTransferFromStack(vm, stack.start, stack.src_base, stack.count),
        .values => |values| setTransferFromValues(vm, values.start, values.values),
    }
}

pub fn onLine(vm: *VM, line: i64, invoke: anytype) !void {
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

pub fn onLineNil(vm: *VM, invoke: anytype) !void {
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

pub fn onCount(vm: *VM, invoke: anytype) !void {
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

pub fn onCall(vm: *VM, name_override: ?[]const u8, invoke: anytype) !void {
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

pub fn onCallTransfer(vm: *VM, name_override: ?[]const u8, transfer: HookTransfer, invoke: anytype) !void {
    if (!hasCallListener(vm)) return;
    applyTransfer(vm, transfer);
    try onCall(vm, name_override, invoke);
}

pub fn onTailCall(vm: *VM, name_override: ?[]const u8, invoke: anytype) !void {
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

pub fn onTailCallTransfer(vm: *VM, name_override: ?[]const u8, transfer: HookTransfer, invoke: anytype) !void {
    if (!hasCallListener(vm)) return;
    applyTransfer(vm, transfer);
    try onTailCall(vm, name_override, invoke);
}

pub fn onReturn(vm: *VM, name_override: ?[]const u8, close_name_override: ?[]const u8, invoke: anytype) !void {
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

pub fn onReturnOnYield(vm: *VM, invoke: anytype) !void {
    try onReturn(vm, null, if (error_state.isClosingMetamethod(vm)) "close" else null, invoke);
}

pub fn onReturnTransfer(vm: *VM, name_override: ?[]const u8, close_name_override: ?[]const u8, transfer: HookTransfer, invoke: anytype) !void {
    if (!hasReturnListener(vm)) return;
    applyTransfer(vm, transfer);
    try onReturn(vm, name_override, close_name_override, invoke);
}
