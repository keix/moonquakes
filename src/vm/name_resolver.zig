//! Name Resolution Helpers
//!
//! Register-origin and source-context helpers used by runtime diagnostics.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const OpCode = opcodes.OpCode;
const object = @import("../runtime/gc/object.zig");
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const VM = @import("vm.zig").VM;

pub const CallNameKind = enum {
    global_name,
    field_name,
    method_name,
    local_name,
    upvalue_name,
};

pub const CallNameContext = struct {
    kind: CallNameKind,
    name: []const u8,
};

pub fn currentInstructionIndex(ci: *const CallInfo) ?usize {
    if (ci.func.code.len == 0) return null;
    const code_start = @intFromPtr(ci.func.code.ptr);
    const pc_addr = @intFromPtr(ci.pc);
    if (pc_addr <= code_start) return null;
    return (pc_addr - code_start) / @sizeOf(Instruction) - 1;
}

pub fn findNearestOpcodeBack(ci: *const CallInfo, from_idx: usize, op: OpCode) ?usize {
    var i: usize = from_idx + 1;
    while (i > 0) {
        i -= 1;
        if (ci.func.code[i].getOpCode() == op) return i;
    }
    return null;
}

pub fn findRegisterProducerBack(ci: *const CallInfo, from_idx: usize, reg: u8) ?usize {
    var target_reg = reg;
    var i = from_idx;
    var budget: u16 = 96;
    while (i > 0 and budget > 0) {
        i -= 1;
        budget -= 1;
        const prev = ci.func.code[i];
        if (prev.getA() != target_reg) continue;
        if (prev.getOpCode() == .MOVE) {
            target_reg = prev.getB();
            continue;
        }
        return i;
    }
    return null;
}

pub fn isNameSourceOp(op: OpCode) bool {
    return op == .GETTABUP or op == .GETUPVAL or op == .GETTABLE or op == .GETI or op == .GETFIELD or op == .SELF;
}

pub fn arithmeticNameOperandOperatorLine(ci: *const CallInfo, idx: usize, reg: u8) ?i64 {
    if (idx >= ci.func.lineinfo.len) return null;
    const cur_line = ci.func.lineinfo[idx];
    const producer_idx = findRegisterProducerBack(ci, idx, reg) orelse return null;
    if (producer_idx >= ci.func.lineinfo.len) return null;
    const producer_line = ci.func.lineinfo[producer_idx];
    const producer_op = ci.func.code[producer_idx].getOpCode();
    if (!isNameSourceOp(producer_op)) return null;
    if (cur_line > producer_line + 1) {
        return @intCast(producer_line + 1);
    }
    return null;
}

pub fn callNameContext(ci: *const CallInfo, call_reg: u8) ?CallNameContext {
    const cur_idx = currentInstructionIndex(ci) orelse return null;
    if (cur_idx == 0 or cur_idx > ci.func.code.len) return null;

    var target_reg = call_reg;
    var i = cur_idx;
    var budget: u16 = 48;
    while (i > 0 and budget > 0) {
        i -= 1;
        budget -= 1;
        const inst = ci.func.code[i];
        if (inst.getA() != target_reg) continue;

        switch (inst.getOpCode()) {
            .MOVE => {
                target_reg = inst.getB();
                continue;
            },
            .ADDI, .ADDK, .SUBK, .MULK, .DIVK, .IDIVK, .BANDK, .BORK, .BXORK, .SHLI, .SHRI, .UNM, .BNOT => {
                target_reg = inst.getB();
                continue;
            },
            .ADD, .SUB, .MUL, .DIV, .MOD, .POW, .IDIV, .BAND, .BOR, .BXOR, .SHL, .SHR => {
                target_reg = inst.getB();
                continue;
            },
            .MMBIN, .MMBINI, .MMBINK => {
                target_reg = inst.getA();
                continue;
            },
            .SELF => {
                const key_val = ci.func.k[inst.getC()];
                if (key_val.asString()) |key| {
                    return .{ .kind = .method_name, .name = key.asSlice() };
                }
                continue;
            },
            .GETFIELD => {
                const key_val = ci.func.k[inst.getC()];
                if (key_val.asString()) |key| {
                    const table_reg = inst.getB();
                    if (table_reg < ci.func.local_reg_names.len) {
                        if (ci.func.local_reg_names[table_reg]) |local_name| {
                            if (std.mem.eql(u8, local_name, "_ENV")) {
                                return .{ .kind = .global_name, .name = key.asSlice() };
                            }
                        }
                    }
                    return .{ .kind = .field_name, .name = key.asSlice() };
                }
                continue;
            },
            .GETTABUP => {
                if (inst.getB() != 0) return null;
                const key_val = ci.func.k[inst.getC()];
                if (key_val.asString()) |key| {
                    return .{ .kind = .global_name, .name = key.asSlice() };
                }
                continue;
            },
            .GETUPVAL => {
                const uv_idx = inst.getB();
                if (uv_idx >= ci.func.upvalues.len) return null;
                const uv_name = ci.func.upvalues[uv_idx].name orelse return null;
                return .{ .kind = .upvalue_name, .name = uv_name };
            },
            else => continue,
        }
    }
    if (target_reg < ci.func.local_reg_names.len) {
        if (ci.func.local_reg_names[target_reg]) |name| {
            return .{ .kind = .local_name, .name = name };
        }
    }
    return null;
}

pub fn traceNonMethodObjectContext(vm: *VM, ci: *const CallInfo, reg: u8) ?CallNameContext {
    const cur_idx = currentInstructionIndex(ci) orelse return null;
    if (cur_idx > ci.func.code.len) return null;

    var target_reg = reg;
    var i = cur_idx;
    var budget: u16 = 64;
    while (i > 0 and budget > 0) {
        i -= 1;
        budget -= 1;
        const inst = ci.func.code[i];
        if (inst.getOpCode() == .SELF and inst.getA() + 1 == target_reg) {
            target_reg = inst.getB();
            continue;
        }
        if (inst.getA() != target_reg) continue;

        switch (inst.getOpCode()) {
            .MOVE => {
                target_reg = inst.getB();
                continue;
            },
            .GETFIELD => {
                const key_val = ci.func.k[inst.getC()];
                if (key_val.asString()) |key| {
                    const table_reg = inst.getB();
                    const target_nil = vm.base + target_reg < vm.stack.len and vm.stack[vm.base + target_reg].isNil();
                    if (!target_nil and vm.base + table_reg < vm.stack.len and vm.stack[vm.base + table_reg].asTable() != null) {
                        return .{ .kind = .field_name, .name = key.asSlice() };
                    }
                    target_reg = table_reg;
                    continue;
                }
                continue;
            },
            .GETTABUP => {
                if (inst.getB() != 0) return null;
                const key_val = ci.func.k[inst.getC()];
                if (key_val.asString()) |key| {
                    return .{ .kind = .global_name, .name = key.asSlice() };
                }
                continue;
            },
            .GETUPVAL => {
                const uv_idx = inst.getB();
                if (uv_idx >= ci.func.upvalues.len) return null;
                const uv_name = ci.func.upvalues[uv_idx].name orelse return null;
                return .{ .kind = .upvalue_name, .name = uv_name };
            },
            .SELF => {
                const obj_reg = inst.getB();
                if (vm.base + obj_reg < vm.stack.len and vm.stack[vm.base + obj_reg].asTable() != null) {
                    const key_val = ci.func.k[inst.getC()];
                    if (key_val.asString()) |key| {
                        return .{ .kind = .method_name, .name = key.asSlice() };
                    }
                }
                target_reg = obj_reg;
                continue;
            },
            else => continue,
        }
    }

    if (target_reg < ci.func.local_reg_names.len) {
        if (ci.func.local_reg_names[target_reg]) |name| {
            return .{ .kind = .local_name, .name = name };
        }
    }
    return null;
}

pub fn resolveRegisterNameContext(ci: *const CallInfo, reg: u8) ?CallNameContext {
    const cur_idx = currentInstructionIndex(ci) orelse return null;
    if (cur_idx > ci.func.code.len) return null;

    var target_reg = reg;
    var i = cur_idx;
    var budget: u16 = 64;
    while (i > 0 and budget > 0) {
        i -= 1;
        budget -= 1;
        const inst = ci.func.code[i];
        if (inst.getA() != target_reg) continue;

        switch (inst.getOpCode()) {
            .MOVE => {
                target_reg = inst.getB();
                continue;
            },
            .SELF => {
                const key_val = ci.func.k[inst.getC()];
                if (key_val.asString()) |key| {
                    return .{ .kind = .method_name, .name = key.asSlice() };
                }
                continue;
            },
            .GETFIELD => {
                const key_val = ci.func.k[inst.getC()];
                if (key_val.asString()) |key| {
                    const table_reg = inst.getB();
                    if (table_reg < ci.func.local_reg_names.len) {
                        if (ci.func.local_reg_names[table_reg]) |local_name| {
                            if (std.mem.eql(u8, local_name, "_ENV")) {
                                return .{ .kind = .global_name, .name = key.asSlice() };
                            }
                        }
                    }
                    return .{ .kind = .field_name, .name = key.asSlice() };
                }
                continue;
            },
            .GETTABUP => {
                if (inst.getB() != 0) return null;
                const key_val = ci.func.k[inst.getC()];
                if (key_val.asString()) |key| {
                    return .{ .kind = .global_name, .name = key.asSlice() };
                }
                continue;
            },
            .GETUPVAL => {
                const uv_idx = inst.getB();
                if (uv_idx >= ci.func.upvalues.len) return null;
                const uv_name = ci.func.upvalues[uv_idx].name orelse return null;
                return .{ .kind = .upvalue_name, .name = uv_name };
            },
            else => continue,
        }
    }

    if (target_reg < ci.func.local_reg_names.len) {
        if (ci.func.local_reg_names[target_reg]) |name| {
            return .{ .kind = .local_name, .name = name };
        }
    }
    return null;
}

pub fn trimAsciiSpace(slice: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = slice.len;
    while (start < end and std.ascii.isWhitespace(slice[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(slice[end - 1])) : (end -= 1) {}
    return slice[start..end];
}

pub fn sourceLineSlice(source: []const u8, target_line: u32) ?[]const u8 {
    if (target_line == 0) return null;
    var line_no: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        if (i == source.len or source[i] == '\n') {
            if (line_no == target_line) return source[line_start..i];
            line_no += 1;
            line_start = i + 1;
        }
    }
    return null;
}

pub fn findUnaryOperatorLineInSource(source: []const u8, operand_line: u32, op: OpCode) ?i64 {
    if (operand_line <= 1) return null;
    const op_text = switch (op) {
        .UNM => "-",
        .BNOT => "~",
        else => return null,
    };
    var look_line = operand_line - 1;
    var budget: u8 = 5;
    while (look_line > 0 and budget > 0) : (look_line -= 1) {
        budget -= 1;
        const line = sourceLineSlice(source, look_line) orelse continue;
        const trimmed = trimAsciiSpace(line);
        if (std.mem.eql(u8, trimmed, op_text)) return @intCast(look_line);
    }
    return null;
}

pub fn findCallOpenParenLineInSource(source: []const u8, from_line: u32) ?i64 {
    if (from_line == 0) return null;
    var look_line = from_line;
    var budget: u8 = 10;
    while (look_line > 0 and budget > 0) : (look_line -= 1) {
        budget -= 1;
        const line = sourceLineSlice(source, look_line) orelse continue;
        const trimmed = trimAsciiSpace(line);
        if (std.mem.indexOfScalar(u8, trimmed, '(') != null) return @intCast(look_line);
    }
    return null;
}
