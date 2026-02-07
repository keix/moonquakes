const std = @import("std");
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;
const CallInfo = vm_mod.CallInfo;
const TValue = @import("../runtime/value.zig").TValue;
const opcodes = @import("../compiler/opcodes.zig");
const OpCode = opcodes.OpCode;
const Instruction = opcodes.Instruction;
const object = @import("../runtime/gc/object.zig");
const NativeClosureObject = object.NativeClosureObject;
const UpvalueObject = object.UpvalueObject;

/// Result of executing a single instruction.
/// Controls VM's main loop behavior.
pub const ExecuteResult = union(enum) {
    /// Normal instruction completed. Same frame, proceed to next.
    Continue,

    /// Frame changed (CALL pushed, RETURN popped). Restart loop with new ci.
    LoopContinue,

    /// Main function returned. Exit VM with this value.
    ReturnVM: VM.ReturnValue,
};

/// Execute a single instruction.
/// Called by VM's execute() loop after fetch.
pub fn do(vm: *VM, inst: Instruction) !ExecuteResult {
    const ci = vm.ci.?;

    switch (inst.getOpCode()) {
        .MOVE => {
            const a = inst.getA();
            const b = inst.getB();
            vm.stack[vm.base + a] = vm.stack[vm.base + b];
            return .Continue;
        },
        .LOADK => {
            const a = inst.getA();
            const bx = inst.getBx();
            vm.stack[vm.base + a] = ci.func.k[bx];
            return .Continue;
        },
        .LOADKX => {
            const a = inst.getA();
            const extraarg_inst = try ci.fetchExtraArg();
            const ax = extraarg_inst.getAx();
            vm.stack[vm.base + a] = ci.func.k[ax];
            return .Continue;
        },
        .LOADI => {
            const a = inst.getA();
            const sbx = inst.getSBx();
            vm.stack[vm.base + a] = .{ .integer = @as(i64, sbx) };
            return .Continue;
        },
        .LOADF => {
            const a = inst.getA();
            const sbx = inst.getSBx();
            vm.stack[vm.base + a] = .{ .number = @as(f64, @floatFromInt(sbx)) };
            return .Continue;
        },
        .LOADFALSE => {
            const a = inst.getA();
            vm.stack[vm.base + a] = .{ .boolean = false };
            return .Continue;
        },
        .LFALSESKIP => {
            const a = inst.getA();
            vm.stack[vm.base + a] = .{ .boolean = false };
            ci.skip();
            return .Continue;
        },
        .LOADTRUE => {
            const a = inst.getA();
            vm.stack[vm.base + a] = .{ .boolean = true };
            return .Continue;
        },
        .LOADNIL => {
            const a = inst.getA();
            const b = inst.getB();
            var i: u8 = 0;
            while (i <= b) : (i += 1) {
                vm.stack[vm.base + a + i] = .nil;
            }
            return .Continue;
        },
        .ADDI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const imm = @as(i8, @bitCast(@as(u8, sc)));

            if (vb.isInteger()) {
                const add_result = @addWithOverflow(vb.integer, @as(i64, imm));
                if (add_result[1] == 0) {
                    vm.stack[vm.base + a] = .{ .integer = add_result[0] };
                } else {
                    const n = @as(f64, @floatFromInt(vb.integer)) + @as(f64, @floatFromInt(imm));
                    vm.stack[vm.base + a] = .{ .number = n };
                }
            } else if (vb.toNumber()) |n| {
                vm.stack[vm.base + a] = .{ .number = n + @as(f64, @floatFromInt(imm)) };
            } else {
                return error.ArithmeticError;
            }
            return .Continue;
        },
        .SHLI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const vb = &vm.stack[vm.base + b];

            const value = if (vb.isInteger()) vb.integer else if (vb.toNumber()) |n| blk: {
                if (@floor(n) == n) {
                    break :blk @as(i64, @intFromFloat(n));
                } else {
                    return error.ArithmeticError;
                }
            } else {
                return error.ArithmeticError;
            };

            const shift = @as(u8, sc);
            vm.stack[vm.base + a] = .{ .integer = std.math.shl(i64, value, @as(u6, @intCast(shift))) };
            return .Continue;
        },
        .SHRI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const vb = &vm.stack[vm.base + b];

            const value = if (vb.isInteger()) vb.integer else if (vb.toNumber()) |n| blk: {
                if (@floor(n) == n) {
                    break :blk @as(i64, @intFromFloat(n));
                } else {
                    return error.ArithmeticError;
                }
            } else {
                return error.ArithmeticError;
            };

            const shift = @as(u8, sc);
            vm.stack[vm.base + a] = .{ .integer = std.math.shr(i64, value, @as(u6, @intCast(shift))) };
            return .Continue;
        },
        .ADDK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            if (vb.isInteger() and vc.isInteger()) {
                vm.stack[vm.base + a] = .{ .integer = vb.integer + vc.integer };
            } else {
                const nb = vb.toNumber() orelse return error.ArithmeticError;
                const nc = vc.toNumber() orelse return error.ArithmeticError;
                vm.stack[vm.base + a] = .{ .number = nb + nc };
            }
            return .Continue;
        },
        .SUBK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            if (vb.isInteger() and vc.isInteger()) {
                vm.stack[vm.base + a] = .{ .integer = vb.integer - vc.integer };
            } else {
                const nb = vb.toNumber() orelse return error.ArithmeticError;
                const nc = vc.toNumber() orelse return error.ArithmeticError;
                vm.stack[vm.base + a] = .{ .number = nb - nc };
            }
            return .Continue;
        },
        .MULK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            if (vb.isInteger() and vc.isInteger()) {
                vm.stack[vm.base + a] = .{ .integer = vb.integer * vc.integer };
            } else {
                const nb = vb.toNumber() orelse return error.ArithmeticError;
                const nc = vc.toNumber() orelse return error.ArithmeticError;
                vm.stack[vm.base + a] = .{ .number = nb * nc };
            }
            return .Continue;
        },
        .DIVK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            const nb = vb.toNumber() orelse return error.ArithmeticError;
            const nc = vc.toNumber() orelse return error.ArithmeticError;
            if (nc == 0) return error.ArithmeticError;
            vm.stack[vm.base + a] = .{ .number = nb / nc };
            return .Continue;
        },
        .IDIVK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            const nb = vb.toNumber() orelse return error.ArithmeticError;
            const nc = vc.toNumber() orelse return error.ArithmeticError;
            if (nc == 0) return error.ArithmeticError;
            vm.stack[vm.base + a] = .{ .number = VM.luaFloorDiv(nb, nc) };
            return .Continue;
        },
        .MODK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            const nb = vb.toNumber() orelse return error.ArithmeticError;
            const nc = vc.toNumber() orelse return error.ArithmeticError;
            if (nc == 0) return error.ArithmeticError;
            vm.stack[vm.base + a] = .{ .number = VM.luaMod(nb, nc) };
            return .Continue;
        },
        .POWK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            const nb = vb.toNumber() orelse return error.ArithmeticError;
            const nc = vc.toNumber() orelse return error.ArithmeticError;
            vm.stack[vm.base + a] = .{ .number = std.math.pow(f64, nb, nc) };
            return .Continue;
        },
        .BANDK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            const toInt = struct {
                fn convert(v: *const TValue) !i64 {
                    if (v.isInteger()) {
                        return v.integer;
                    } else if (v.toNumber()) |n| {
                        if (@floor(n) == n) {
                            return @as(i64, @intFromFloat(n));
                        }
                    }
                    return error.ArithmeticError;
                }
            }.convert;

            const ib = try toInt(vb);
            const ic = try toInt(vc);
            vm.stack[vm.base + a] = .{ .integer = ib & ic };
            return .Continue;
        },
        .BORK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            const toInt = struct {
                fn convert(v: *const TValue) !i64 {
                    if (v.isInteger()) {
                        return v.integer;
                    } else if (v.toNumber()) |n| {
                        if (@floor(n) == n) {
                            return @as(i64, @intFromFloat(n));
                        }
                    }
                    return error.ArithmeticError;
                }
            }.convert;

            const ib = try toInt(vb);
            const ic = try toInt(vc);
            vm.stack[vm.base + a] = .{ .integer = ib | ic };
            return .Continue;
        },
        .BXORK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            const toInt = struct {
                fn convert(v: *const TValue) !i64 {
                    if (v.isInteger()) {
                        return v.integer;
                    } else if (v.toNumber()) |n| {
                        if (@floor(n) == n) {
                            return @as(i64, @intFromFloat(n));
                        }
                    }
                    return error.ArithmeticError;
                }
            }.convert;

            const ib = try toInt(vb);
            const ic = try toInt(vc);
            vm.stack[vm.base + a] = .{ .integer = ib ^ ic };
            return .Continue;
        },
        .ADD => {
            try vm.arithBinary(inst, .add);
            return .Continue;
        },
        .SUB => {
            try vm.arithBinary(inst, .sub);
            return .Continue;
        },
        .MUL => {
            try vm.arithBinary(inst, .mul);
            return .Continue;
        },
        .DIV => {
            try vm.arithBinary(inst, .div);
            return .Continue;
        },
        .IDIV => {
            try vm.arithBinary(inst, .idiv);
            return .Continue;
        },
        .MOD => {
            try vm.arithBinary(inst, .mod);
            return .Continue;
        },
        .POW => {
            try vm.arithBinary(inst, .pow);
            return .Continue;
        },
        .BAND => {
            try vm.bitwiseBinary(inst, .band);
            return .Continue;
        },
        .BOR => {
            try vm.bitwiseBinary(inst, .bor);
            return .Continue;
        },
        .BXOR => {
            try vm.bitwiseBinary(inst, .bxor);
            return .Continue;
        },
        .SHL => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &vm.stack[vm.base + c];

            const toInt = struct {
                fn convert(v: *const TValue) !i64 {
                    if (v.isInteger()) {
                        return v.integer;
                    } else if (v.toNumber()) |n| {
                        if (@floor(n) == n) {
                            return @as(i64, @intFromFloat(n));
                        }
                    }
                    return error.ArithmeticError;
                }
            }.convert;

            const value = try toInt(vb);
            const shift = try toInt(vc);

            const result = if (shift >= 0) blk: {
                const s = std.math.cast(u6, shift) orelse 63;
                break :blk std.math.shl(i64, value, s);
            } else blk: {
                const s = std.math.cast(u6, -shift) orelse 63;
                break :blk std.math.shr(i64, value, s);
            };

            vm.stack[vm.base + a] = .{ .integer = result };
            return .Continue;
        },
        .SHR => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &vm.stack[vm.base + c];

            const toInt = struct {
                fn convert(v: *const TValue) !i64 {
                    if (v.isInteger()) {
                        return v.integer;
                    } else if (v.toNumber()) |n| {
                        if (@floor(n) == n) {
                            return @as(i64, @intFromFloat(n));
                        }
                    }
                    return error.ArithmeticError;
                }
            }.convert;

            const value = try toInt(vb);
            const shift = try toInt(vc);

            const result = if (shift >= 0) blk: {
                const s = std.math.cast(u6, shift) orelse 63;
                break :blk std.math.shr(i64, value, s);
            } else blk: {
                const s = std.math.cast(u6, -shift) orelse 63;
                break :blk std.math.shl(i64, value, s);
            };

            vm.stack[vm.base + a] = .{ .integer = result };
            return .Continue;
        },
        .UNM => {
            const a = inst.getA();
            const b = inst.getB();
            const vb = &vm.stack[vm.base + b];
            if (vb.isInteger()) {
                vm.stack[vm.base + a] = .{ .integer = -vb.integer };
            } else if (vb.toNumber()) |n| {
                vm.stack[vm.base + a] = .{ .number = -n };
            } else {
                return error.ArithmeticError;
            }
            return .Continue;
        },
        .NOT => {
            const a = inst.getA();
            const b = inst.getB();
            const vb = &vm.stack[vm.base + b];
            vm.stack[vm.base + a] = .{ .boolean = !vb.toBoolean() };
            return .Continue;
        },
        .BNOT => {
            const a = inst.getA();
            const b = inst.getB();
            const vb = &vm.stack[vm.base + b];

            if (vb.isInteger()) {
                vm.stack[vm.base + a] = .{ .integer = ~vb.integer };
            } else {
                if (vb.toNumber()) |n| {
                    if (@floor(n) == n) {
                        const i = @as(i64, @intFromFloat(n));
                        vm.stack[vm.base + a] = .{ .integer = ~i };
                    } else {
                        return error.ArithmeticError;
                    }
                } else {
                    return error.ArithmeticError;
                }
            }
            return .Continue;
        },
        .LEN => {
            const a = inst.getA();
            const b = inst.getB();
            const vb = &vm.stack[vm.base + b];

            if (vb.asString()) |str| {
                vm.stack[vm.base + a] = .{ .integer = @as(i64, @intCast(str.asSlice().len)) };
            } else if (vb.asTable()) |table| {
                var len: i64 = 0;
                var key_buffer: [32]u8 = undefined;
                while (true) {
                    const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{len + 1}) catch break;
                    const key = vm.gc.allocString(key_slice) catch break;
                    if (table.get(key) == null) break;
                    len += 1;
                }
                vm.stack[vm.base + a] = .{ .integer = len };
            } else {
                return error.LengthError;
            }
            return .Continue;
        },
        .CONCAT => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();

            var total_len: usize = 0;
            for (b..c + 1) |i| {
                const val = &vm.stack[vm.base + i];
                if (val.asString()) |str| {
                    total_len += str.asSlice().len;
                } else if (val.isInteger()) {
                    var buf: [32]u8 = undefined;
                    const str = std.fmt.bufPrint(&buf, "{d}", .{val.integer}) catch {
                        return error.ArithmeticError;
                    };
                    total_len += str.len;
                } else if (val.isNumber()) {
                    var buf: [32]u8 = undefined;
                    const str = std.fmt.bufPrint(&buf, "{d}", .{val.number}) catch {
                        return error.ArithmeticError;
                    };
                    total_len += str.len;
                } else {
                    return error.ArithmeticError;
                }
            }

            const result_buf = try vm.allocator.alloc(u8, total_len);
            defer vm.allocator.free(result_buf);
            var offset: usize = 0;

            for (b..c + 1) |i| {
                const val = &vm.stack[vm.base + i];
                if (val.asString()) |str| {
                    const str_slice = str.asSlice();
                    @memcpy(result_buf[offset .. offset + str_slice.len], str_slice);
                    offset += str_slice.len;
                } else if (val.isInteger()) {
                    const str = std.fmt.bufPrint(result_buf[offset..], "{d}", .{val.integer}) catch {
                        return error.ArithmeticError;
                    };
                    offset += str.len;
                } else if (val.isNumber()) {
                    const str = std.fmt.bufPrint(result_buf[offset..], "{d}", .{val.number}) catch {
                        return error.ArithmeticError;
                    };
                    offset += str.len;
                }
            }

            const result_str = try vm.gc.allocString(result_buf);
            vm.stack[vm.base + a] = TValue.fromString(result_str);
            return .Continue;
        },
        .EQ => {
            const negate = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const is_true = VM.eqOp(vm.stack[vm.base + b], vm.stack[vm.base + c]);
            if ((is_true and negate == 0) or (!is_true and negate != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        .LT => {
            const negate = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const is_true = VM.ltOp(vm.stack[vm.base + b], vm.stack[vm.base + c]) catch |err| switch (err) {
                error.OrderComparisonError => return error.ArithmeticError,
                else => return err,
            };
            if ((is_true and negate == 0) or (!is_true and negate != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        .LE => {
            const negate = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const is_true = VM.leOp(vm.stack[vm.base + b], vm.stack[vm.base + c]) catch |err| switch (err) {
                error.OrderComparisonError => return error.ArithmeticError,
                else => return err,
            };
            if ((is_true and negate == 0) or (!is_true and negate != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        .JMP => {
            const sj = inst.getsJ();
            try ci.jumpRel(sj);
            return .Continue;
        },
        .TEST => {
            const a = inst.getA();
            const k = inst.getk();
            const va = &vm.stack[vm.base + a];
            if (va.toBoolean() != k) {
                ci.skip();
            }
            return .Continue;
        },
        .TESTSET => {
            const a = inst.getA();
            const b = inst.getB();
            const k = inst.getk();
            const vb = &vm.stack[vm.base + b];
            if (vb.toBoolean() == k) {
                vm.stack[vm.base + a] = vb.*;
            } else {
                ci.skip();
            }
            return .Continue;
        },
        .FORPREP => {
            const a = inst.getA();
            const sbx = inst.getSBx();
            const v_init = vm.stack[vm.base + a];
            const v_limit = vm.stack[vm.base + a + 1];
            const v_step = vm.stack[vm.base + a + 2];

            if (v_init.isInteger() and v_limit.isInteger() and v_step.isInteger()) {
                const ii = v_init.integer;
                const is = v_step.integer;
                if (is == 0) return error.InvalidForLoopStep;

                const sub_result = @subWithOverflow(ii, is);
                if (sub_result[1] == 0) {
                    vm.stack[vm.base + a] = .{ .integer = sub_result[0] };
                } else {
                    const i = @as(f64, @floatFromInt(ii));
                    const s = @as(f64, @floatFromInt(is));
                    vm.stack[vm.base + a] = .{ .number = i - s };
                }
            } else {
                const i = v_init.toNumber() orelse return error.InvalidForLoopInit;
                const s = v_step.toNumber() orelse return error.InvalidForLoopStep;
                if (s == 0) return error.InvalidForLoopStep;
                vm.stack[vm.base + a] = .{ .number = i - s };
            }

            try ci.jumpRel(sbx);
            return .Continue;
        },
        .FORLOOP => {
            const a = inst.getA();
            const sbx = inst.getSBx();
            const idx = &vm.stack[vm.base + a];
            const limit = &vm.stack[vm.base + a + 1];
            const step = &vm.stack[vm.base + a + 2];

            if (idx.isInteger() and limit.isInteger() and step.isInteger()) {
                const i = idx.integer;
                const l = limit.integer;
                const s = step.integer;

                if (s > 0) {
                    if (i < l) {
                        const add_result = @addWithOverflow(i, s);
                        if (add_result[1] == 0 and add_result[0] <= l) {
                            const new_i = add_result[0];
                            idx.* = .{ .integer = new_i };
                            vm.stack[vm.base + a + 3] = .{ .integer = new_i };
                            if (sbx >= 0) ci.pc += @as(usize, @intCast(sbx)) else ci.pc -= @as(usize, @intCast(-sbx));
                        }
                    }
                } else if (s < 0) {
                    if (i > l) {
                        const add_result = @addWithOverflow(i, s);
                        if (add_result[1] == 0 and add_result[0] >= l) {
                            const new_i = add_result[0];
                            idx.* = .{ .integer = new_i };
                            vm.stack[vm.base + a + 3] = .{ .integer = new_i };
                            if (sbx >= 0) ci.pc += @as(usize, @intCast(sbx)) else ci.pc -= @as(usize, @intCast(-sbx));
                        }
                    }
                }
            } else {
                const i = idx.toNumber() orelse return error.InvalidForLoopInit;
                const l = limit.toNumber() orelse return error.InvalidForLoopLimit;
                const s = step.toNumber() orelse return error.InvalidForLoopStep;

                const new_i = i + s;
                const cont = if (s > 0) (new_i <= l) else (new_i >= l);
                if (cont) {
                    idx.* = .{ .number = new_i };
                    vm.stack[vm.base + a + 3] = .{ .number = new_i };
                    if (sbx >= 0) ci.pc += @as(usize, @intCast(sbx)) else ci.pc -= @as(usize, @intCast(-sbx));
                }
            }
            return .Continue;
        },
        .CALL => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();

            const func_val = &vm.stack[vm.base + a];

            if (func_val.isObject()) {
                const obj = func_val.object;
                if (obj.type == .native_closure) {
                    const nc = object.getObject(NativeClosureObject, obj);
                    const nargs: u32 = if (b > 0) b - 1 else 0;
                    const nresults: u32 = if (c > 0) c - 1 else 0;
                    try vm.callNative(nc.func.id, a, nargs, nresults);
                    return .LoopContinue;
                }
            }

            const closure = func_val.asClosure() orelse return error.NotAFunction;
            const func_proto = closure.proto;

            const nargs: u32 = if (b > 0) b - 1 else blk: {
                const arg_start = vm.base + a + 1;
                break :blk vm.top - arg_start;
            };

            const nresults: i16 = if (c > 0) @as(i16, @intCast(c - 1)) else -1;

            const new_base = vm.base + a;
            const ret_base = vm.base + a;

            if (nargs > 0) {
                var i: u32 = 0;
                while (i < nargs) : (i += 1) {
                    vm.stack[new_base + i] = vm.stack[new_base + 1 + i];
                }
            }

            var i: u32 = nargs;
            while (i < func_proto.numparams) : (i += 1) {
                vm.stack[new_base + i] = .nil;
            }

            _ = try vm.pushCallInfo(func_proto, closure, new_base, ret_base, nresults);

            vm.top = new_base + func_proto.maxstacksize;
            return .LoopContinue;
        },
        .RETURN => {
            const a = inst.getA();
            const b = inst.getB();

            if (vm.ci.?.previous != null) {
                const returning_ci = vm.ci.?;
                const nresults = returning_ci.nresults;
                const dst_base = returning_ci.ret_base;

                vm.closeUpvalues(returning_ci.base);
                vm.popCallInfo();

                if (b == 0) {
                    return error.VariableReturnNotImplemented;
                } else if (b == 1) {
                    if (nresults > 0) {
                        var i: u16 = 0;
                        while (i < nresults) : (i += 1) {
                            vm.stack[dst_base + i] = .nil;
                        }
                    }
                } else {
                    const ret_count = b - 1;

                    if (nresults < 0) {
                        var i: u16 = 0;
                        while (i < ret_count) : (i += 1) {
                            vm.stack[dst_base + i] = vm.stack[returning_ci.base + a + i];
                        }
                        vm.top = dst_base + ret_count;
                    } else {
                        var i: u16 = 0;
                        while (i < nresults) : (i += 1) {
                            if (i < ret_count) {
                                vm.stack[dst_base + i] = vm.stack[returning_ci.base + a + i];
                            } else {
                                vm.stack[dst_base + i] = .nil;
                            }
                        }
                    }
                }

                return .LoopContinue;
            }

            if (b == 0) {
                return .{ .ReturnVM = .none };
            } else if (b == 1) {
                return .{ .ReturnVM = .none };
            } else if (b == 2) {
                return .{ .ReturnVM = .{ .single = vm.stack[vm.base + a] } };
            } else {
                const count = b - 1;
                const values = vm.stack[vm.base + a .. vm.base + a + count];
                return .{ .ReturnVM = .{ .multiple = values } };
            }
        },
        .RETURN0 => {
            if (vm.ci.?.previous != null) {
                const returning_ci = vm.ci.?;
                const nresults = returning_ci.nresults;
                const dst_base = returning_ci.ret_base;

                vm.closeUpvalues(returning_ci.base);
                vm.popCallInfo();

                if (nresults > 0) {
                    var i: u16 = 0;
                    while (i < nresults) : (i += 1) {
                        vm.stack[dst_base + i] = .nil;
                    }
                }

                return .LoopContinue;
            }

            return .{ .ReturnVM = .none };
        },
        .RETURN1 => {
            const a = inst.getA();

            if (vm.ci.?.previous != null) {
                const returning_ci = vm.ci.?;
                const nresults = returning_ci.nresults;
                const dst_base = returning_ci.ret_base;

                vm.closeUpvalues(returning_ci.base);
                vm.popCallInfo();

                if (nresults < 0) {
                    vm.stack[dst_base] = vm.stack[returning_ci.base + a];
                    vm.top = dst_base + 1;
                } else {
                    if (nresults > 0) {
                        vm.stack[dst_base] = vm.stack[returning_ci.base + a];
                        var i: u16 = 1;
                        while (i < nresults) : (i += 1) {
                            vm.stack[dst_base + i] = .nil;
                        }
                    }
                }

                return .LoopContinue;
            }

            return .{ .ReturnVM = .{ .single = vm.stack[vm.base + a] } };
        },
        .GETTABUP => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            _ = b;

            const key_val = ci.func.k[c];
            if (key_val.asString()) |key| {
                const value = vm.globals.get(key) orelse .nil;
                vm.stack[vm.base + a] = value;
            } else {
                return error.InvalidTableKey;
            }
            return .Continue;
        },
        .SETTABUP => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            _ = a;

            const key_val = ci.func.k[b];
            const value = vm.stack[vm.base + c];
            if (key_val.asString()) |key| {
                try vm.globals.set(key, value);
            } else {
                return error.InvalidTableKey;
            }
            return .Continue;
        },
        .GETUPVAL => {
            const a = inst.getA();
            const b = inst.getB();
            if (ci.closure) |closure| {
                if (b < closure.upvalues.len) {
                    vm.stack[vm.base + a] = closure.upvalues[b].get();
                } else {
                    vm.stack[vm.base + a] = .nil;
                }
            } else {
                vm.stack[vm.base + a] = .nil;
            }
            return .Continue;
        },
        .SETUPVAL => {
            const a = inst.getA();
            const b = inst.getB();
            if (ci.closure) |closure| {
                if (b < closure.upvalues.len) {
                    closure.upvalues[b].set(vm.stack[vm.base + a]);
                }
            }
            return .Continue;
        },
        .GETTABLE => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const table_val = vm.stack[vm.base + b];
            const key_val = vm.stack[vm.base + c];

            if (table_val.asTable()) |table| {
                if (key_val.asString()) |key| {
                    const value = table.get(key) orelse .nil;
                    vm.stack[vm.base + a] = value;
                } else if (key_val.isInteger()) {
                    var key_buffer: [32]u8 = undefined;
                    const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{key_val.integer}) catch {
                        return error.InvalidTableKey;
                    };
                    const key = try vm.gc.allocString(key_slice);
                    const value = table.get(key) orelse .nil;
                    vm.stack[vm.base + a] = value;
                } else {
                    return error.InvalidTableOperation;
                }
            } else {
                return error.InvalidTableOperation;
            }
            return .Continue;
        },
        .SETTABLE => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const table_val = vm.stack[vm.base + a];
            const key_val = vm.stack[vm.base + b];
            const value = vm.stack[vm.base + c];

            if (table_val.asTable()) |table| {
                if (key_val.asString()) |key| {
                    try table.set(key, value);
                } else if (key_val.isInteger()) {
                    var key_buffer: [32]u8 = undefined;
                    const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{key_val.integer}) catch {
                        return error.InvalidTableOperation;
                    };
                    const key = try vm.gc.allocString(key_slice);
                    try table.set(key, value);
                } else {
                    return error.InvalidTableOperation;
                }
            } else {
                return error.InvalidTableOperation;
            }
            return .Continue;
        },
        .GETI => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const table_val = vm.stack[vm.base + b];

            if (table_val.asTable()) |table| {
                var key_buffer: [32]u8 = undefined;
                const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{c}) catch {
                    return error.InvalidTableKey;
                };
                const key = try vm.gc.allocString(key_slice);
                const value = table.get(key) orelse .nil;
                vm.stack[vm.base + a] = value;
            } else {
                return error.InvalidTableOperation;
            }
            return .Continue;
        },
        .SETI => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const table_val = vm.stack[vm.base + a];
            const value = vm.stack[vm.base + c];

            if (table_val.asTable()) |table| {
                var key_buffer: [32]u8 = undefined;
                const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{b}) catch {
                    return error.InvalidTableKey;
                };
                const key = try vm.gc.allocString(key_slice);
                try table.set(key, value);
            } else {
                return error.InvalidTableOperation;
            }
            return .Continue;
        },
        .GETFIELD => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const table_val = vm.stack[vm.base + b];
            const key_val = ci.func.k[c];

            if (table_val.asTable()) |table| {
                if (key_val.asString()) |key| {
                    const value = table.get(key) orelse .nil;
                    vm.stack[vm.base + a] = value;
                } else {
                    return error.InvalidTableOperation;
                }
            } else {
                return error.InvalidTableOperation;
            }
            return .Continue;
        },
        .SETFIELD => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const table_val = vm.stack[vm.base + a];
            const key_val = ci.func.k[b];
            const value = vm.stack[vm.base + c];

            if (table_val.asTable()) |table| {
                if (key_val.asString()) |key| {
                    try table.set(key, value);
                } else {
                    return error.InvalidTableOperation;
                }
            } else {
                return error.InvalidTableOperation;
            }
            return .Continue;
        },
        .NEWTABLE => {
            const a = inst.getA();
            const table = try vm.gc.allocTable();
            vm.stack[vm.base + a] = TValue.fromTable(table);
            return .Continue;
        },
        .EQK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const is_true = VM.eqOp(vm.stack[vm.base + b], ci.func.k[c]);
            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        .EQI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const imm = @as(i8, @bitCast(@as(u8, sc)));
            const imm_val = TValue{ .integer = @as(i64, imm) };
            const is_true = VM.eqOp(vm.stack[vm.base + b], imm_val);
            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        .LTI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const imm = @as(i8, @bitCast(@as(u8, sc)));
            const imm_val = TValue{ .integer = @as(i64, imm) };
            const is_true = VM.ltOp(vm.stack[vm.base + b], imm_val) catch |err| switch (err) {
                error.OrderComparisonError => return error.ArithmeticError,
                else => return err,
            };
            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        .LEI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const imm = @as(i8, @bitCast(@as(u8, sc)));
            const imm_val = TValue{ .integer = @as(i64, imm) };
            const is_true = VM.leOp(vm.stack[vm.base + b], imm_val) catch |err| switch (err) {
                error.OrderComparisonError => return error.ArithmeticError,
                else => return err,
            };
            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        .GTI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const imm = @as(i8, @bitCast(@as(u8, sc)));
            const imm_val = TValue{ .integer = @as(i64, imm) };
            const is_true = VM.ltOp(imm_val, vm.stack[vm.base + b]) catch |err| switch (err) {
                error.OrderComparisonError => return error.ArithmeticError,
                else => return err,
            };
            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        .GEI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const imm = @as(i8, @bitCast(@as(u8, sc)));
            const imm_val = TValue{ .integer = @as(i64, imm) };
            const is_true = VM.leOp(imm_val, vm.stack[vm.base + b]) catch |err| switch (err) {
                error.OrderComparisonError => return error.ArithmeticError,
                else => return err,
            };
            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        .CLOSE => {
            const a = inst.getA();
            vm.closeUpvalues(vm.base + a);
            return .Continue;
        },
        .TBC => {
            const a = inst.getA();
            _ = a;
            return .Continue;
        },
        .CLOSURE => {
            const a = inst.getA();
            const bx = inst.getBx();

            const child_proto = ci.func.protos[bx];

            var upvals_buf: [256]*UpvalueObject = undefined;
            const nups = child_proto.nups;

            for (child_proto.upvalues[0..nups], 0..) |upvaldesc, i| {
                if (upvaldesc.instack) {
                    const stack_slot = &vm.stack[vm.base + upvaldesc.idx];
                    upvals_buf[i] = try vm.getOrCreateUpvalue(stack_slot);
                } else {
                    if (ci.closure) |enclosing| {
                        upvals_buf[i] = enclosing.upvalues[upvaldesc.idx];
                    } else {
                        upvals_buf[i] = try vm.gc.allocUpvalue(&vm.stack[0]);
                    }
                }
            }

            const closure = try vm.gc.allocClosure(child_proto);
            @memcpy(closure.upvalues[0..nups], upvals_buf[0..nups]);

            vm.stack[vm.base + a] = TValue.fromClosure(closure);
            return .Continue;
        },
        .EXTRAARG => {
            return error.UnknownOpcode;
        },
        else => return error.UnknownOpcode,
    }
}
