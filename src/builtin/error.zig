//! Error-related builtin functions and shared formatting helpers.
//!
//! Internal helpers stay near the top of the file.
//! Dispatcher entrypoints remain grouped at the bottom.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const error_state = @import("../vm/error_state.zig");
const VM = @import("../vm/vm.zig").VM;
const execution = @import("../vm/execution.zig");
const CallInfo = execution.CallInfo;
const Instruction = @import("../compiler/opcodes.zig").Instruction;

fn formatAssertFailure(vm: *VM, msg: []const u8, out_buf: *[320]u8) []const u8 {
    const ci = vm.ci orelse return msg;
    const target = ci;
    var source_raw = target.func.source;
    var line = callInfoLine(target) orelse 0;

    // Native assert can run with synthetic/empty source on current frame.
    // Borrow caller source name if needed, but keep current call-site line.
    if (target.previous != null) {
        if (source_raw.len == 0) {
            source_raw = target.previous.?.func.source;
        }
        if (line == 0) {
            line = callInfoLine(target.previous.?) orelse line;
        }
    }

    const source = if (source_raw.len == 0)
        "chunk.lua"
    else if (source_raw[0] == '@' or source_raw[0] == '=')
        source_raw[1..]
    else if (source_raw[0] == '[')
        "chunk.lua"
    else
        source_raw;

    if (line == 0) return msg;
    return std.fmt.bufPrint(out_buf, "{s}:{d}: {s}", .{ source, line, msg }) catch msg;
}

fn currentInstructionIndex(ci: *const CallInfo) ?usize {
    if (ci.func.code.len == 0) return null;
    const code_start = @intFromPtr(ci.func.code.ptr);
    const pc_addr = @intFromPtr(ci.pc);
    if (pc_addr <= code_start) return null;
    return (pc_addr - code_start) / @sizeOf(Instruction) - 1;
}

fn callInfoLine(ci: *const CallInfo) ?u32 {
    const idx = currentInstructionIndex(ci) orelse return null;
    if (idx >= ci.func.lineinfo.len) return null;
    const line = ci.func.lineinfo[idx];
    if (idx > 0) {
        const op = ci.func.code[idx].getOpCode();
        if (op == .CALL and line > ci.func.lineinfo[idx - 1]) {
            return ci.func.lineinfo[idx - 1];
        }
        if ((op == .RETURN or op == .RETURN0 or op == .RETURN1) and line > ci.func.lineinfo[idx - 1]) {
            return ci.func.lineinfo[idx - 1];
        }
    }
    return line;
}

fn callInfoForLevel(vm: *VM, level: i64) ?*CallInfo {
    if (level <= 0) return null;
    var target = vm.ci orelse return null;
    var remain = level;
    while (remain > 1) : (remain -= 1) {
        target = target.previous orelse return null;
    }
    return target;
}

fn errorMessageWithLevel(vm: *VM, msg: []const u8, level: i64, out_buf: *[320]u8) ?[]const u8 {
    const target = callInfoForLevel(vm, level) orelse return null;
    var line = callInfoLine(target) orelse return null;
    if (level > 2) {
        if (currentInstructionIndex(target)) |idx| {
            if (idx > 0 and idx < target.func.lineinfo.len and target.func.lineinfo[idx] > target.func.lineinfo[idx - 1]) {
                line = target.func.lineinfo[idx - 1];
            }
        }
    }
    const source_raw = target.func.source;
    const source = if (source_raw.len == 0)
        "?"
    else if (source_raw[0] == '@' or source_raw[0] == '=')
        source_raw[1..]
    else
        source_raw;
    return std.fmt.bufPrint(out_buf, "{s}:{d}: {s}", .{ source, line, msg }) catch null;
}

// Dispatcher entrypoints.

/// Lua signature: assert(v [, message])
/// If v is false or nil, raises an error with optional message.
pub fn nativeAssert(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs == 0) {
        return vm.raiseString("value expected");
    }

    var value = vm.stack[vm.base + func_reg + 1];
    if (nargs == 1 and value.isNil()) {
        const alt = vm.stack[vm.base + func_reg + 2];
        if (!alt.isNil()) {
            value = alt;
        }
    }

    const is_truthy = switch (value) {
        .nil => false,
        .boolean => |b| b,
        else => true,
    };

    if (!is_truthy) {
        if (nargs >= 2) {
            const msg_arg = vm.stack[vm.base + func_reg + 2];
            return vm.raise(msg_arg);
        }
        var msg_buf: [320]u8 = undefined;
        return vm.raiseString(formatAssertFailure(vm, "assertion failed!", &msg_buf));
    }

    if (nresults > 0) {
        const actual_results = @min(nargs, nresults);
        var i: u32 = 0;
        while (i < actual_results) : (i += 1) {
            vm.stack[vm.base + func_reg + i] = vm.stack[vm.base + func_reg + 1 + i];
        }
        while (i < nresults) : (i += 1) {
            vm.stack[vm.base + func_reg + i] = .nil;
        }
    }
}

/// Lua signature: error(message [, level])
/// Raises an error with the given message (can be any value).
pub fn nativeError(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;
    error_state.markErrorBuiltin(vm);

    const error_value = if (nargs > 0)
        vm.stack[vm.base + func_reg + 1]
    else
        .nil;

    const level_i: i64 = if (nargs >= 2) blk: {
        const level_arg = vm.stack[vm.base + func_reg + 2];
        break :blk level_arg.toInteger() orelse return vm.raiseString("bad argument #2 to 'error' (number expected)");
    } else 1;

    if (level_i > 0) {
        if (error_value.asString()) |msg_obj| {
            var full_msg_buf: [320]u8 = undefined;
            if (errorMessageWithLevel(vm, msg_obj.asSlice(), level_i, &full_msg_buf)) |full_msg| {
                return vm.raiseString(full_msg);
            }
        }
    }

    return vm.raise(error_value);
}
