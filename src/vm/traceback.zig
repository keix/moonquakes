//! Traceback State
//!
//! Snapshot storage for Lua-visible traceback reporting during error unwinding.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const ClosureObject = @import("../runtime/gc/object.zig").ClosureObject;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const error_state = @import("error_state.zig");
const VM = @import("vm.zig").VM;

pub const TracebackState = struct {
    snapshot_lines: [256]u32 = [_]u32{0} ** 256,
    snapshot_names: [256]TValue = [_]TValue{.nil} ** 256,
    snapshot_closures: [256]?*ClosureObject = [_]?*ClosureObject{null} ** 256,
    snapshot_sources: [256][]const u8 = [_][]const u8{""} ** 256,
    snapshot_def_lines: [256]u32 = [_]u32{0} ** 256,
    snapshot_count: u16 = 0,
    snapshot_has_error_frame: bool = false,
};

const snapshot_cap = 256;

fn currentInstructionIndex(ci: *const CallInfo) ?usize {
    if (ci.func.code.len == 0) return null;
    const code_start = @intFromPtr(ci.func.code.ptr);
    const pc_addr = @intFromPtr(ci.pc);
    if (pc_addr <= code_start) return null;
    return (pc_addr - code_start) / @sizeOf(Instruction) - 1;
}

fn inferGlobalName(vm: *VM, closure: *ClosureObject) ?TValue {
    var it = vm.globals().hash_part.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        const c = value.asClosure() orelse continue;
        if (c != closure) continue;
        const k = key.asString() orelse continue;
        return TValue.fromString(k);
    }
    return null;
}

fn frameLine(ci: *const CallInfo) ?u32 {
    const idx_opt = currentInstructionIndex(ci);
    if (idx_opt == null) {
        if (ci.func.lineinfo.len == 0) return null;
        if (ci.func.lineinfo.len >= 2) return ci.func.lineinfo[ci.func.lineinfo.len - 2];
        return ci.func.lineinfo[0];
    }
    const idx = idx_opt.?;
    if (idx >= ci.func.lineinfo.len) return null;
    var line = ci.func.lineinfo[idx];
    if (idx > 0) {
        const op = ci.func.code[idx].getOpCode();
        if (op == .CALL and line > ci.func.lineinfo[idx - 1]) {
            line = ci.func.lineinfo[idx - 1];
        }
    }
    return line;
}

fn appendSnapshotFrame(vm: *VM, ci: *const CallInfo, count: *usize) void {
    if (count.* >= snapshot_cap) return;
    const line = frameLine(ci) orelse return;
    vm.traceback.snapshot_lines[count.*] = line;
    vm.traceback.snapshot_names[count.*] = .nil;
    vm.traceback.snapshot_closures[count.*] = ci.closure;
    vm.traceback.snapshot_sources[count.*] = ci.func.source;
    vm.traceback.snapshot_def_lines[count.*] = if (ci.func.lineinfo.len > 0) ci.func.lineinfo[0] else line;
    if (ci.closure) |cl| {
        if (inferGlobalName(vm, cl)) |name| {
            vm.traceback.snapshot_names[count.*] = name;
        }
    }
    count.* += 1;
}

pub fn captureSnapshot(vm: *VM, stop_before: ?*CallInfo) void {
    var count: usize = 0;
    if (vm.callstack_size > 0) {
        var i: i32 = @as(i32, @intCast(vm.callstack_size)) - 1;
        while (i >= 0) : (i -= 1) {
            const ci = &vm.callstack[@intCast(i)];
            if (ci == stop_before) break;
            if (count >= snapshot_cap) break;
            appendSnapshotFrame(vm, ci, &count);
        }
    } else {
        var cur = vm.ci;
        while (cur) |ci| : (cur = ci.previous) {
            if (cur == stop_before) break;
            if (count >= snapshot_cap) break;
            appendSnapshotFrame(vm, ci, &count);
        }
    }
    vm.traceback.snapshot_count = @intCast(count);
    vm.traceback.snapshot_has_error_frame = error_state.takeErrorBuiltinFlag(vm);
}

pub fn lastSnapshotLine(vm: *const VM) ?u32 {
    if (vm.traceback.snapshot_count == 0) return null;
    return vm.traceback.snapshot_lines[vm.traceback.snapshot_count - 1];
}

pub fn formatSnapshotFrame(
    host_vm: *VM,
    target_vm: *VM,
    index: usize,
    out_buf: []u8,
    infer_global: anytype,
    infer_declared: anytype,
    infer_enclosing: anytype,
) []const u8 {
    var snapshot_name: ?[]const u8 = null;
    if (target_vm.traceback.snapshot_names[index].asString()) |name| {
        snapshot_name = name.asSlice();
    }
    if (snapshot_name == null) {
        if (target_vm.traceback.snapshot_closures[index]) |cl| {
            if (infer_global(target_vm, cl)) |name| {
                snapshot_name = name;
            }
        }
    }
    if (snapshot_name == null) {
        var decl_buf: [128]u8 = undefined;
        if (infer_declared(
            host_vm,
            target_vm.traceback.snapshot_sources[index],
            target_vm.traceback.snapshot_def_lines[index],
            &decl_buf,
        )) |name| {
            snapshot_name = name;
        } else if (infer_enclosing(
            host_vm,
            target_vm.traceback.snapshot_sources[index],
            target_vm.traceback.snapshot_lines[index],
            &decl_buf,
        )) |name2| {
            snapshot_name = name2;
        }
    }

    return if (snapshot_name) |name|
        (std.fmt.bufPrint(out_buf, "[string]:{d}: in function '{s}'", .{ target_vm.traceback.snapshot_lines[index], name }) catch "[Lua function]")
    else
        (std.fmt.bufPrint(out_buf, "[string]:{d}: in function <[string]:{d}>", .{ target_vm.traceback.snapshot_lines[index], target_vm.traceback.snapshot_def_lines[index] }) catch "[Lua function]");
}
