//! Hot instruction loop
//!
//! A restricted inner interpreter that executes runs of straight-line
//! fast-path opcodes with the program counter held in a local, using a
//! labeled-switch dispatch (each arm jumps directly to the next opcode's
//! arm). Everything outside the fast set — calls, returns, table access,
//! metamethods, float fallbacks, errors — exits back to the full dispatch
//! loop in mnemonics.zig.
//!
//! Contract:
//!   - Only entered when no debug hooks are active and the frame has no
//!     pending continuation.
//!   - Fast ops never allocate, never error, never change the frame, and
//!     never grow the stack, so `vm.stack`, `vm.base`, and `ci` are stable
//!     for the whole run.
//!   - On exit, ci.pc points at the first instruction that was NOT
//!     executed; the outer loop resumes with its normal fetch + dispatch.
//!   - Backward jumps (loop back-edges) poll the slow-work signal and the
//!     interrupt flag and exit so the outer loop can service them — the
//!     same safepoint granularity PUC Lua uses.

const builtin = @import("builtin");
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("vm.zig").VM;
const CallInfo = @import("execution.zig").CallInfo;
const interrupt = @import("../interrupt.zig");

pub fn run(vm: *VM, ci: *CallInfo) void {
    // Safe builds validate the PC on every fetch (CallInfo.validatePC);
    // this loop assumes valid bytecode like ReleaseFast fetch does, so it
    // only runs in optimized builds. Coverage comes from the ReleaseFast
    // passing/all.lua run.
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) return;

    var pc = ci.pc;
    defer ci.pc = pc;

    // Stable for the whole run: fast ops cannot reallocate the stack or
    // switch frames.
    const stack = &vm.stack;
    const base = vm.base;
    const k = ci.func.k;

    var inst = pc[0];
    dispatch: switch (inst.getOpCode()) {
        .MOVE => {
            stack[base + inst.getA()] = stack[base + inst.getB()];
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LOADI => {
            stack[base + inst.getA()] = .{ .integer = @as(i64, inst.getSBx()) };
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LOADF => {
            stack[base + inst.getA()] = .{ .number = @as(f64, @floatFromInt(inst.getSBx())) };
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LOADK => {
            stack[base + inst.getA()] = k[inst.getBx()];
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LOADTRUE => {
            stack[base + inst.getA()] = .{ .boolean = true };
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LOADFALSE => {
            stack[base + inst.getA()] = .{ .boolean = false };
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LFALSESKIP => {
            stack[base + inst.getA()] = .{ .boolean = false };
            pc += 2;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LOADNIL => {
            const a = inst.getA();
            const b = inst.getB();
            var i: u8 = 0;
            while (i <= b) : (i += 1) {
                stack[base + a + i] = .nil;
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .JMP => {
            const sj = inst.getsJ();
            pc += 1;
            if (sj >= 0) {
                pc += @as(usize, @intCast(sj));
            } else {
                pc -= @as(usize, @intCast(-sj));
                // Loop back-edge: safepoint.
                if (vm.slow_work_signal or interrupt.isPending()) return;
            }
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .FORLOOP => {
            const a = inst.getA();
            const idx = &stack[base + a];
            const limit = &stack[base + a + 1];
            const step = &stack[base + a + 2];
            if (!(idx.isInteger() and limit.isInteger() and step.isInteger())) {
                // Float loop state: leave pc at the FORLOOP itself so the
                // outer loop re-executes it through the full handler.
                return;
            }
            const i = idx.integer;
            const l = limit.integer;
            const s = step.integer;
            const sbx = inst.getSBx();
            pc += 1;
            var continues = false;
            if (s > 0) {
                if (i < l) {
                    const add_result = @addWithOverflow(i, s);
                    if (add_result[1] == 0 and add_result[0] <= l) {
                        const new_i = add_result[0];
                        idx.* = .{ .integer = new_i };
                        stack[base + a + 3] = .{ .integer = new_i };
                        continues = true;
                    }
                }
            } else if (s < 0) {
                if (i > l) {
                    const add_result = @addWithOverflow(i, s);
                    if (add_result[1] == 0 and add_result[0] >= l) {
                        const new_i = add_result[0];
                        idx.* = .{ .integer = new_i };
                        stack[base + a + 3] = .{ .integer = new_i };
                        continues = true;
                    }
                }
            }
            if (continues) {
                if (sbx >= 0) {
                    pc += @as(usize, @intCast(sbx));
                } else {
                    pc -= @as(usize, @intCast(-sbx));
                }
                // Loop back-edge: safepoint.
                if (vm.slow_work_signal or interrupt.isPending()) return;
            }
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .CLOSE => {
            // Emitted at every loop back-edge by the compiler. With no
            // to-be-closed slots on this frame and no open upvalues at all,
            // there is nothing to close.
            if (ci.tbc_bitmap != 0 or vm.open_upvalues != null) return;
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .GETUPVAL => {
            const closure = ci.closure orelse return;
            const b = inst.getB();
            stack[base + inst.getA()] = if (b < closure.upvalues.len)
                closure.upvalues[b].get()
            else
                .nil;
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .TEST => {
            const skip = stack[base + inst.getA()].toBoolean() != inst.getk();
            pc += if (skip) 2 else 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .ADD, .SUB, .MUL => {
            const vb = &stack[base + inst.getB()];
            const vc = &stack[base + inst.getC()];
            if (vb.isInteger() and vc.isInteger()) {
                const res = switch (inst.getOpCode()) {
                    .ADD => vb.integer +% vc.integer,
                    .SUB => vb.integer -% vc.integer,
                    .MUL => vb.integer *% vc.integer,
                    else => unreachable,
                };
                stack[base + inst.getA()] = .{ .integer = res };
            } else if (vb.isNumber() and vc.isNumber()) {
                const res = switch (inst.getOpCode()) {
                    .ADD => vb.number + vc.number,
                    .SUB => vb.number - vc.number,
                    .MUL => vb.number * vc.number,
                    else => unreachable,
                };
                stack[base + inst.getA()] = .{ .number = res };
            } else {
                // Mixed/coercion/metamethod: full handler re-executes it.
                return;
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .ADDK, .SUBK, .MULK => {
            const vb = &stack[base + inst.getB()];
            const vc = &k[inst.getC()];
            if (vb.isInteger() and vc.isInteger()) {
                const res = switch (inst.getOpCode()) {
                    .ADDK => vb.integer +% vc.integer,
                    .SUBK => vb.integer -% vc.integer,
                    .MULK => vb.integer *% vc.integer,
                    else => unreachable,
                };
                stack[base + inst.getA()] = .{ .integer = res };
                pc += 1;
                inst = pc[0];
                continue :dispatch inst.getOpCode();
            }
            return;
        },
        .LTI, .LEI, .GTI, .GEI => {
            const left = &stack[base + inst.getB()];
            if (!left.isInteger()) return;
            const a = inst.getA();
            const imm: i64 = @as(i8, @bitCast(@as(u8, inst.getC())));
            const is_true = switch (inst.getOpCode()) {
                .LTI => left.integer < imm,
                .LEI => left.integer <= imm,
                .GTI => imm < left.integer,
                .GEI => imm <= left.integer,
                else => unreachable,
            };
            const skip = (is_true and a == 0) or (!is_true and a != 0);
            pc += if (skip) 2 else 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .EQ, .LT, .LE => {
            const left = &stack[base + inst.getB()];
            const right = &stack[base + inst.getC()];
            if (!(left.isInteger() and right.isInteger())) return;
            const negate = inst.getA();
            const is_true = switch (inst.getOpCode()) {
                .EQ => left.integer == right.integer,
                .LT => left.integer < right.integer,
                .LE => left.integer <= right.integer,
                else => unreachable,
            };
            const skip = (is_true and negate == 0) or (!is_true and negate != 0);
            pc += if (skip) 2 else 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        else => return,
    }
}
