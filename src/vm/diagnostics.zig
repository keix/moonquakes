//! Execution Diagnostics
//!
//! Source-location helpers for runtime error reporting.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const name_resolver = @import("name_resolver.zig");
const VM = @import("vm.zig").VM;

pub fn runtimeErrorLine(ci: *const CallInfo, inst: Instruction, err: anyerror) i64 {
    const idx = name_resolver.currentInstructionIndex(ci) orelse return -1;
    var line_idx = idx;
    var arithmetic_line_override: ?i64 = null;
    var call_line_override: ?i64 = null;

    if (err == error.InvalidForLoopInit or err == error.InvalidForLoopLimit or err == error.InvalidForLoopStep) {
        if (name_resolver.findNearestOpcodeBack(ci, idx, .FORPREP)) |prep_idx| {
            line_idx = prep_idx;
        }
    } else if (err == error.NotAFunction and inst.getOpCode() == .TFORCALL) {
        if (name_resolver.findNearestOpcodeBack(ci, idx, .TFORPREP)) |prep_idx| {
            line_idx = prep_idx;
        }
    } else if (err == error.NotAFunction and (inst.getOpCode() == .CALL or inst.getOpCode() == .TAILCALL)) {
        if (idx < ci.func.lineinfo.len) {
            const source_raw = ci.func.source;
            if (source_raw.len > 0 and source_raw[0] != '@' and source_raw[0] != '=') {
                call_line_override = name_resolver.findCallOpenParenLineInSource(source_raw, ci.func.lineinfo[idx]);
            }
        }
    } else if (err == error.ArithmeticError) {
        const op = inst.getOpCode();
        if ((op == .MMBIN or op == .MMBINI or op == .MMBINK) and idx > 0) {
            const prev_op = ci.func.code[idx - 1].getOpCode();
            if (prev_op == .ADD or prev_op == .SUB or prev_op == .MUL or prev_op == .DIV or prev_op == .MOD or prev_op == .POW or prev_op == .IDIV or
                prev_op == .BAND or prev_op == .BOR or prev_op == .BXOR or prev_op == .SHL or prev_op == .SHR or
                prev_op == .ADDI or prev_op == .ADDK or prev_op == .SUBK or prev_op == .MULK or prev_op == .DIVK or prev_op == .IDIVK or
                prev_op == .BANDK or prev_op == .BORK or prev_op == .BXORK or prev_op == .SHLI or prev_op == .SHRI or
                prev_op == .UNM or prev_op == .BNOT)
            {
                line_idx = idx - 1;
            }
        }
        if (op == .ADD or op == .SUB or op == .MUL or op == .DIV or op == .MOD or op == .POW or op == .IDIV or
            op == .BAND or op == .BOR or op == .BXOR or op == .SHL or op == .SHR)
        {
            const b_line = name_resolver.arithmeticNameOperandOperatorLine(ci, idx, inst.getB());
            const c_line = name_resolver.arithmeticNameOperandOperatorLine(ci, idx, inst.getC());
            arithmetic_line_override = if (b_line != null and c_line != null)
                @min(b_line.?, c_line.?)
            else
                (b_line orelse c_line);
        } else if (op == .ADDK or op == .ADDI or op == .SUBK or op == .MULK or op == .DIVK or op == .IDIVK or
            op == .BANDK or op == .BORK or op == .BXORK or op == .SHLI or op == .SHRI)
        {
            arithmetic_line_override = name_resolver.arithmeticNameOperandOperatorLine(ci, idx, inst.getB());
        } else if (op == .UNM or op == .BNOT) {
            if (name_resolver.findRegisterProducerBack(ci, idx, inst.getB())) |producer_idx| {
                if (producer_idx < ci.func.lineinfo.len) {
                    const operand_line = ci.func.lineinfo[producer_idx];
                    const source_raw = ci.func.source;
                    if (source_raw.len > 0 and source_raw[0] != '@' and source_raw[0] != '=') {
                        arithmetic_line_override = name_resolver.findUnaryOperatorLineInSource(source_raw, operand_line, op);
                    }
                }
            }
        }
    }

    if (ci.func.lineinfo.len == 0 or line_idx >= ci.func.lineinfo.len) return -1;
    const line_i: i64 = @intCast(ci.func.lineinfo[line_idx]);
    if (arithmetic_line_override) |line_override| return line_override;
    if (call_line_override) |line_override| return line_override;
    if (err == error.NotAFunction and inst.getOpCode() == .TFORCALL and line_i > 1) {
        return line_i - 1;
    }

    return line_i;
}

pub fn runtimeErrorWithLocation(ci: *const CallInfo, inst: Instruction, err: anyerror, msg: []const u8, out_buf: *[320]u8) []const u8 {
    const source_raw = ci.func.source;
    const source = if (source_raw.len == 0)
        "?"
    else if (source_raw[0] == '@' or source_raw[0] == '=')
        source_raw[1..]
    else
        source_raw;

    const line_i: i64 = runtimeErrorLine(ci, inst, err);

    if (std.fmt.bufPrint(out_buf, "{s}:{d}: {s}", .{ source, line_i, msg })) |full| {
        return full;
    } else |_| {
        const short_source = if (source_raw.len > 0 and source_raw[0] != '@' and source_raw[0] != '=') "[string]" else "?";
        return std.fmt.bufPrint(out_buf, "{s}:{d}: {s}", .{ short_source, line_i, msg }) catch msg;
    }
}

pub fn raiseWithLocation(vm: *VM, ci: *const CallInfo, inst: Instruction, err: anyerror, msg: []const u8) !void {
    var full_msg_buf: [320]u8 = undefined;
    const full_msg = runtimeErrorWithLocation(ci, inst, err, msg, &full_msg_buf);
    return vm.raiseString(full_msg);
}

pub fn runtimeErrorWithCurrentLocation(vm: *VM, inst: Instruction, err: anyerror, msg: []const u8, out_buf: *[320]u8) []const u8 {
    const ci = vm.ci orelse return msg;
    return runtimeErrorWithLocation(ci, inst, err, msg, out_buf);
}
