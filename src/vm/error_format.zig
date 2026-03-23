//! Error Formatting Helpers
//!
//! Lua-visible runtime error message construction and related type/name helpers.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const object = @import("../runtime/gc/object.zig");
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const field_cache = @import("field_cache.zig");
const name_resolver = @import("name_resolver.zig");
const VM = @import("vm.zig").VM;

fn valueTypeName(v: TValue) []const u8 {
    return switch (v) {
        .nil => "nil",
        .boolean => "boolean",
        .integer, .number => "number",
        .object => |obj| switch (obj.type) {
            .string => "string",
            .table => "table",
            .closure, .native_closure => "function",
            .userdata => "userdata",
            .thread => "thread",
            .file => "userdata",
            else => "userdata",
        },
    };
}

pub fn callableValueTypeName(v: TValue) []const u8 {
    return switch (v) {
        .nil => "nil",
        .boolean => "boolean",
        .integer, .number => "number",
        .object => |obj| switch (obj.type) {
            .string => "string",
            .table => "table",
            .closure, .native_closure => "function",
            .userdata, .file => "userdata",
            .thread => "thread",
            else => "userdata",
        },
    };
}

pub fn namedValueTypeName(vm: *VM, v: TValue) []const u8 {
    if (!v.isObject()) return valueTypeName(v);
    const mt_opt: ?*object.TableObject = switch (v.object.type) {
        .table => object.getObject(object.TableObject, v.object).metatable,
        .userdata => object.getObject(object.UserdataObject, v.object).metatable,
        .file => object.getObject(object.FileObject, v.object).metatable,
        else => null,
    };
    if (mt_opt) |mt| {
        if (mt.get(TValue.fromString(vm.gc().mm_keys.get(.name)))) |name_val| {
            if (name_val.asString()) |name_str| return name_str.asSlice();
        }
    }
    return valueTypeName(v);
}

const ForLoopArg = enum { init, limit, step };

fn forLoopArgValue(vm: *VM, inst: Instruction, arg: ForLoopArg) ?TValue {
    const op = inst.getOpCode();
    if (op != .FORPREP and op != .FORLOOP) return null;
    const a = inst.getA();
    const offset: u8 = switch (arg) {
        .init => 0,
        .limit => 1,
        .step => 2,
    };
    const idx = vm.base + a + offset;
    if (idx >= vm.stack.len) return null;
    return vm.stack[idx];
}

fn firstArithmeticBadOperand(vm: *VM, inst: Instruction) ?TValue {
    return switch (inst.getOpCode()) {
        .ADD, .SUB, .MUL, .DIV, .MOD, .POW, .IDIV, .BAND, .BOR, .BXOR, .SHL, .SHR => blk: {
            const vb = vm.stack[vm.base + inst.getB()];
            const vc = vm.stack[vm.base + inst.getC()];
            if (vb.toNumber() == null) break :blk vb;
            if (vc.toNumber() == null) break :blk vc;
            break :blk null;
        },
        .ADDI, .ADDK, .SUBK, .MULK, .DIVK, .IDIVK, .BANDK, .BORK, .BXORK, .SHLI, .SHRI, .UNM, .BNOT => blk: {
            const vb = vm.stack[vm.base + inst.getB()];
            if (vb.toNumber() == null) break :blk vb;
            break :blk null;
        },
        .MMBIN => blk: {
            const va = vm.stack[vm.base + inst.getA()];
            const vb = vm.stack[vm.base + inst.getB()];
            if (va.toNumber() == null) break :blk va;
            if (vb.toNumber() == null) break :blk vb;
            break :blk null;
        },
        .MMBINI, .MMBINK => blk: {
            const va = vm.stack[vm.base + inst.getA()];
            if (va.toNumber() == null) break :blk va;
            break :blk null;
        },
        else => null,
    };
}

fn customNamedArithmeticType(vm: *VM, inst: Instruction) ?[]const u8 {
    const bad = firstArithmeticBadOperand(vm, inst) orelse return null;
    const plain = valueTypeName(bad);
    const named = namedValueTypeName(vm, bad);
    if (std.mem.eql(u8, plain, named)) return null;
    return named;
}

fn findUniqueLocalNameByValue(ci: *const CallInfo, vm: *VM, value: TValue) ?[]const u8 {
    const max_regs = @min(ci.func.local_reg_names.len, ci.func.maxstacksize);
    var found: ?[]const u8 = null;
    var r: usize = 0;
    while (r < max_regs) : (r += 1) {
        const name = ci.func.local_reg_names[r] orelse continue;
        if (vm.base + r >= vm.stack.len) break;
        if (vm.stack[vm.base + r].eql(value)) {
            if (found != null) return null;
            found = name;
        }
    }
    return found;
}

pub fn formatIndexOnNonTableError(vm: *VM, inst: Instruction, msg_buf: *[128]u8) []const u8 {
    if (vm.ci) |cur_ci| {
        const reg_opt: ?u8 = switch (inst.getOpCode()) {
            .GETTABLE, .GETFIELD, .GETI, .SELF => inst.getB(),
            .SETTABLE, .SETFIELD, .SETI => inst.getA(),
            else => null,
        };
        if (reg_opt) |bad_reg| {
            if (name_resolver.resolveRegisterNameContext(cur_ci, bad_reg)) |ctx| {
                const kind = switch (ctx.kind) {
                    .global_name => "global",
                    .field_name => "field",
                    .method_name => "method",
                    .local_name => "local",
                    .upvalue_name => "upvalue",
                };
                const ty = callableValueTypeName(vm.stack[vm.base + bad_reg]);
                return std.fmt.bufPrint(msg_buf, "attempt to index a {s} value ({s} '{s}')", .{ ty, kind, ctx.name }) catch "attempt to index a non-table value";
            }
        }
    }
    if (field_cache.takeLastFieldHint(vm)) |hint| {
        const ty = if (vm.base + hint.reg < vm.stack.len) callableValueTypeName(vm.stack[vm.base + hint.reg]) else "non-table";
        const kind = if (hint.is_global) "global" else "field";
        return std.fmt.bufPrint(msg_buf, "attempt to index a {s} value ({s} '{s}')", .{ ty, kind, hint.key.asSlice() }) catch "attempt to index a non-table value";
    }
    return "attempt to index a non-table value";
}

pub fn formatArithmeticError(vm: *VM, inst: Instruction, msg_buf: *[128]u8, toIntForBitwise: fn (*const TValue) anyerror!i64) []const u8 {
    const op_name: ?[]const u8 = switch (inst.getOpCode()) {
        .BAND, .BANDK => "'band'",
        .BOR, .BORK => "'bor'",
        .BXOR, .BXORK => "'bxor'",
        .BNOT => "'bnot'",
        .SHL, .SHLI => "'shl'",
        .SHR, .SHRI => "'shr'",
        else => null,
    };
    if (op_name) |name| {
        const bad_ty: []const u8 = blkty: {
            switch (inst.getOpCode()) {
                .BNOT => break :blkty namedValueTypeName(vm, vm.stack[vm.base + inst.getB()]),
                .BAND, .BOR, .BXOR, .SHL, .SHR => {
                    const rb = inst.getB();
                    const rc = inst.getC();
                    var vb = vm.stack[vm.base + rb];
                    var vc = vm.stack[vm.base + rc];
                    if (toIntForBitwise(&vb)) |_| {} else |_| break :blkty namedValueTypeName(vm, vb);
                    if (toIntForBitwise(&vc)) |_| {} else |_| break :blkty namedValueTypeName(vm, vc);
                    break :blkty "non-numeric";
                },
                .BANDK, .BORK, .BXORK, .SHLI, .SHRI => break :blkty namedValueTypeName(vm, vm.stack[vm.base + inst.getB()]),
                else => break :blkty "non-numeric",
            }
        };
        return std.fmt.bufPrint(msg_buf, "attempt to perform bitwise operation {s} on a {s} value", .{ name, bad_ty }) catch "attempt to perform arithmetic on a non-numeric value";
    }

    if (customNamedArithmeticType(vm, inst)) |ty| {
        return std.fmt.bufPrint(msg_buf, "attempt to perform arithmetic on a {s} value", .{ty}) catch "attempt to perform arithmetic on a non-numeric value";
    }

    if (vm.ci) |cur_ci| {
        const op = inst.getOpCode();
        if (op == .ADD or op == .SUB or op == .MUL or op == .DIV or op == .MOD or op == .POW or op == .IDIV or
            op == .BAND or op == .BOR or op == .BXOR or op == .SHL or op == .SHR or
            op == .MMBIN or op == .MMBINI or op == .MMBINK)
        {
            const r1: u8 = switch (op) {
                .MMBIN, .MMBINI, .MMBINK => inst.getA(),
                else => inst.getB(),
            };
            const r2: ?u8 = switch (op) {
                .MMBIN => inst.getB(),
                .MMBINI, .MMBINK => null,
                else => inst.getC(),
            };

            var best_ctx: ?name_resolver.CallNameContext = null;
            var best_score: u8 = 0;
            var ctx1_opt: ?name_resolver.CallNameContext = null;
            var ctx2_opt: ?name_resolver.CallNameContext = null;

            const v1 = vm.stack[vm.base + r1];
            if (v1.toNumber() == null) {
                if (name_resolver.resolveRegisterNameContext(cur_ci, r1)) |ctx| {
                    ctx1_opt = ctx;
                    const score: u8 = switch (ctx.kind) {
                        .local_name => 3,
                        .upvalue_name => if (std.mem.eql(u8, ctx.name, "_ENV")) 0 else 3,
                        .global_name, .field_name, .method_name => 2,
                    };
                    if (score > 0) {
                        best_ctx = ctx;
                        best_score = score;
                    }
                }
                if (findUniqueLocalNameByValue(cur_ci, vm, v1)) |lname| {
                    if (best_ctx == null or best_score < 3) {
                        best_ctx = .{ .kind = .local_name, .name = lname };
                        best_score = 3;
                    }
                }
            }
            if (r2) |rr| {
                const v2 = vm.stack[vm.base + rr];
                if (v2.toNumber() == null) {
                    if (name_resolver.resolveRegisterNameContext(cur_ci, rr)) |ctx| {
                        ctx2_opt = ctx;
                        const score: u8 = switch (ctx.kind) {
                            .local_name => 3,
                            .upvalue_name => if (std.mem.eql(u8, ctx.name, "_ENV")) 0 else 3,
                            .global_name, .field_name, .method_name => 2,
                        };
                        if (score > 0 and (best_ctx == null or score > best_score)) {
                            best_ctx = ctx;
                            best_score = score;
                        }
                    }
                    if (findUniqueLocalNameByValue(cur_ci, vm, v2)) |lname| {
                        if (best_ctx == null or best_score < 3) {
                            best_ctx = .{ .kind = .local_name, .name = lname };
                            best_score = 3;
                        }
                    }
                }
            }

            if (ctx1_opt) |ctx1| {
                if (ctx2_opt) |ctx2| {
                    if (ctx1.kind == ctx2.kind and std.mem.eql(u8, ctx1.name, ctx2.name) and
                        (ctx1.kind == .global_name or ctx1.kind == .field_name))
                    {
                        best_ctx = null;
                    }
                }
            }

            if (best_ctx) |ctx| {
                const kind = switch (ctx.kind) {
                    .global_name => "global",
                    .field_name => "field",
                    .method_name => "method",
                    .local_name => "local",
                    .upvalue_name => "upvalue",
                };
                return std.fmt.bufPrint(msg_buf, "attempt to perform arithmetic on a non-numeric value ({s} '{s}')", .{ kind, ctx.name }) catch "attempt to perform arithmetic on a non-numeric value";
            }
        }
    }

    if (vm.field_cache.last_field_key) |key| {
        var suppress_field_hint = false;
        switch (inst.getOpCode()) {
            .ADD, .SUB, .MUL, .DIV, .MOD, .POW, .IDIV, .BAND, .BOR, .BXOR, .SHL, .SHR => {
                const rb = inst.getB();
                const rc = inst.getC();
                const vb = vm.stack[vm.base + rb];
                const vc = vm.stack[vm.base + rc];
                suppress_field_hint = (vb.toNumber() == null and vc.toNumber() == null and vb.eql(vc));
            },
            .MMBIN => {
                const ra = inst.getA();
                const rb = inst.getB();
                const va = vm.stack[vm.base + ra];
                const vb = vm.stack[vm.base + rb];
                suppress_field_hint = (va.toNumber() == null and vb.toNumber() == null and va.eql(vb));
            },
            else => {},
        }
        if (suppress_field_hint) {
            field_cache.clearLastFieldHint(vm);
            return "attempt to perform arithmetic on a non-numeric value";
        }
        const kind = if (vm.field_cache.last_field_is_global) "global" else "field";
        field_cache.clearLastFieldHint(vm);
        return std.fmt.bufPrint(msg_buf, "attempt to perform arithmetic on a non-numeric value ({s} '{s}')", .{ kind, key.asSlice() }) catch "attempt to perform arithmetic on a non-numeric value";
    }

    if (firstArithmeticBadOperand(vm, inst)) |bad| {
        const ty = namedValueTypeName(vm, bad);
        return std.fmt.bufPrint(msg_buf, "attempt to perform arithmetic on a non-numeric value ({s} value)", .{ty}) catch "attempt to perform arithmetic on a non-numeric value";
    }
    return "attempt to perform arithmetic on a non-numeric value";
}

pub fn formatIntegerRepresentationError(vm: *VM, inst: Instruction, msg_buf: *[128]u8, toIntForBitwise: fn (*const TValue) anyerror!i64) []const u8 {
    if (vm.ci) |cur_ci| {
        const reg_opt: ?u8 = switch (inst.getOpCode()) {
            .BNOT => inst.getB(),
            .SHLI, .SHRI, .BANDK, .BORK, .BXORK => inst.getB(),
            .BAND, .BOR, .BXOR, .SHL, .SHR => badreg: {
                const rb = inst.getB();
                const rc = inst.getC();
                var vb = vm.stack[vm.base + rb];
                var vc = vm.stack[vm.base + rc];
                if (toIntForBitwise(&vb)) |_| {} else |_| break :badreg rb;
                if (toIntForBitwise(&vc)) |_| {} else |_| break :badreg rc;
                break :badreg null;
            },
            else => null,
        };
        if (reg_opt) |bad_reg| {
            if (name_resolver.resolveRegisterNameContext(cur_ci, bad_reg)) |ctx| {
                const kind = switch (ctx.kind) {
                    .global_name => "global",
                    .field_name => "field",
                    .method_name => "method",
                    .local_name => "local",
                    .upvalue_name => "upvalue",
                };
                if (ctx.kind == .local_name) {
                    return std.fmt.bufPrint(msg_buf, "number has no integer representation (local {s})", .{ctx.name}) catch "number has no integer representation";
                }
                return std.fmt.bufPrint(msg_buf, "number has no integer representation ({s} '{s}')", .{ kind, ctx.name }) catch "number has no integer representation";
            }
            if (findUniqueLocalNameByValue(cur_ci, vm, vm.stack[vm.base + bad_reg])) |lname| {
                return std.fmt.bufPrint(msg_buf, "number has no integer representation (local {s})", .{lname}) catch "number has no integer representation";
            }
        }
    }

    if (field_cache.takeIntReprFieldKey(vm)) |key| {
        return std.fmt.bufPrint(msg_buf, "number has no integer representation (field '{s}')", .{key.asSlice()}) catch "number has no integer representation";
    }
    return "number has no integer representation";
}

pub fn formatForLoopError(vm: *VM, inst: Instruction, err: anyerror, msg_buf: *[128]u8) []const u8 {
    return switch (err) {
        error.InvalidForLoopInit => blk: {
            if (forLoopArgValue(vm, inst, .init)) |v| {
                const ty = namedValueTypeName(vm, v);
                break :blk std.fmt.bufPrint(msg_buf, "'for' initial value must be a number (got {s})", .{ty}) catch "'for' initial value must be a number";
            }
            break :blk "'for' initial value must be a number";
        },
        error.InvalidForLoopLimit => blk: {
            if (forLoopArgValue(vm, inst, .limit)) |v| {
                const ty = namedValueTypeName(vm, v);
                break :blk std.fmt.bufPrint(msg_buf, "'for' limit must be a number (got {s})", .{ty}) catch "'for' limit must be a number";
            }
            break :blk "'for' limit must be a number";
        },
        error.InvalidForLoopStep => blk: {
            if (forLoopArgValue(vm, inst, .step)) |v| {
                if (v.toNumber()) |n| {
                    if (n == 0) break :blk "'for' step is zero";
                }
                const ty = namedValueTypeName(vm, v);
                break :blk std.fmt.bufPrint(msg_buf, "'for' step must be a number (got {s})", .{ty}) catch "'for' step must be a number";
            }
            break :blk "'for' step must be a number";
        },
        else => "runtime error",
    };
}

pub fn formatNoCloseMetamethodError(vm: *VM, inst: Instruction, msg_buf: *[128]u8) []const u8 {
    const reg = inst.getA();
    const ci = vm.ci orelse return "variable got a non-closable value";
    const name = if (reg < ci.func.local_reg_names.len and ci.func.local_reg_names[reg] != null)
        ci.func.local_reg_names[reg].?
    else
        "?";
    return std.fmt.bufPrint(msg_buf, "variable '{s}' got a non-closable value", .{name}) catch "variable got a non-closable value";
}

pub fn buildCallNotFunctionMessage(vm: *VM, ci: *const CallInfo, call_reg: u8, called: TValue, out_buf: []u8) []const u8 {
    const ty = callableValueTypeName(called);
    var ctx_opt = name_resolver.callNameContext(ci, call_reg);
    if (ctx_opt != null and ctx_opt.?.kind == .method_name and vm.base + call_reg + 1 < vm.stack.len) {
        const self_obj = vm.stack[vm.base + call_reg + 1];
        if (self_obj.asTable() == null) {
            if (name_resolver.traceNonMethodObjectContext(vm, ci, call_reg + 1)) |obj_ctx| {
                if (obj_ctx.kind != .method_name) {
                    ctx_opt = obj_ctx;
                }
            }
        }
    }
    if (ctx_opt) |ctx| {
        if (ctx.kind == .upvalue_name and std.mem.eql(u8, ctx.name, "_ENV")) {} else if ((ctx.kind == .global_name or ctx.kind == .field_name) and std.mem.eql(u8, ty, "table")) {} else {
            const kind = switch (ctx.kind) {
                .global_name => "global",
                .field_name => "field",
                .method_name => "method",
                .local_name => "local",
                .upvalue_name => "upvalue",
            };
            return std.fmt.bufPrint(out_buf, "attempt to call a {s} value ({s} '{s}')", .{ ty, kind, ctx.name }) catch "attempt to call a non-function value";
        }
    }
    if (findUniqueLocalNameByValue(ci, vm, called)) |lname| {
        return std.fmt.bufPrint(out_buf, "attempt to call a {s} value (local '{s}')", .{ ty, lname }) catch "attempt to call a non-function value";
    }
    if (vm.field_cache.last_field_key != null and vm.field_cache.exec_tick - vm.field_cache.last_field_tick <= 64) {
        const key = vm.field_cache.last_field_key.?;
        const self_reg = vm.base + call_reg + 1;
        const has_self_table = self_reg < vm.stack.len and vm.stack[self_reg].asTable() != null;
        if (vm.field_cache.last_field_is_method or has_self_table) {
            return std.fmt.bufPrint(out_buf, "attempt to call a {s} value (method '{s}')", .{ ty, key.asSlice() }) catch "attempt to call a non-function value";
        }
    }
    return std.fmt.bufPrint(out_buf, "attempt to call a {s} value", .{ty}) catch "attempt to call a non-function value";
}
