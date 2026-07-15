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
//!   - Fast ops never raise Lua errors and never grow the stack. The few
//!     that allocate (NEWTABLE, SETI/SETTABLE appends) bail out on OOM
//!     with pc still at the failing instruction so the outer handler
//!     re-executes it; GC may run inside them, which is safe because
//!     `vm.base`/`vm.top`/`vm.ci` are kept in sync at frame switches.
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
const mutation = @import("../runtime/gc/mutation.zig");
const call_debug = @import("call_debug.zig");
const field_cache = @import("field_cache.zig");
const object = @import("../runtime/gc/object.zig");

pub fn run(vm: *VM, ci: *CallInfo) void {
    // Safe builds validate the PC on every fetch (CallInfo.validatePC);
    // this loop assumes valid bytecode like ReleaseFast fetch does, so it
    // only runs in optimized builds. Coverage comes from the ReleaseFast
    // passing/all.lua run.
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) return;

    // Frame-local state. The CALL/RETURN fast paths switch frames without
    // leaving the loop, swapping these in place; everything else about the
    // frame (vm.ci, vm.base, vm.top, callstack) is kept in sync eagerly.
    var cur = ci;
    var pc = cur.pc;
    defer cur.pc = pc;

    const stack = &vm.stack;
    var base = vm.base;
    var k = cur.func.k;

    // Every arm ends with the same `pc += 1; inst = pc[0]; continue` triplet
    // (or a jump variant). It cannot be factored into a helper: Zig's
    // labeled-switch `continue` is what turns each arm into a direct jump
    // to the next opcode's arm, and it must appear literally in the arm.
    var inst = pc[0];
    dispatch: switch (inst.getOpCode()) {
        .MOVE => {
            stack[base + inst.getA()] = stack[base + inst.getB()];
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LOADI => {
            TValue.setInt(&stack[base + inst.getA()], @as(i64, inst.getSBx()));
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LOADF => {
            TValue.setFloat(&stack[base + inst.getA()], @as(f64, @floatFromInt(inst.getSBx())));
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
            TValue.setBool(&stack[base + inst.getA()], true);
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LOADFALSE => {
            TValue.setBool(&stack[base + inst.getA()], false);
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LFALSESKIP => {
            TValue.setBool(&stack[base + inst.getA()], false);
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
            pc = jumpTarget(pc + 1, sj);
            if (sj < 0) {
                // Loop back-edge: safepoint.
                if (vm.slow_work_signal or interrupt.isPending()) return;
            }
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .FORPREP => {
            // All-integer count staging, mirroring opFORPREP: the control
            // slot receives the trip count and execution falls into the
            // body; zero-trip loops jump past FORLOOP. Zero step (error),
            // float state and float limits exit to the full handler.
            const a = inst.getA();
            const v_init = &stack[base + a];
            const v_limit = &stack[base + a + 1];
            const v_step = &stack[base + a + 2];
            if (!(v_init.isInteger() and v_limit.isInteger() and v_step.isInteger())) return;
            const ii = v_init.asInt();
            const il = v_limit.asInt();
            const is = v_step.asInt();
            if (is == 0) return;
            const runs = if (is > 0) ii <= il else ii >= il;
            if (!runs) {
                pc = jumpTarget(pc + 1, inst.getSBx());
                inst = pc[0];
                continue :dispatch inst.getOpCode();
            }
            const ui: u64 = @bitCast(ii);
            const ul: u64 = @bitCast(il);
            var count: u64 = if (is > 0) ul -% ui else ui -% ul;
            if (is > 0) {
                const us: u64 = @intCast(is);
                if (us != 1) count /= us;
            } else {
                const us: u64 = @as(u64, @bitCast(-(is + 1))) +% 1;
                if (us != 1) count /= us;
            }
            TValue.setInt(v_init, @bitCast(count));
            // Limit slot becomes the pristine index (see opFORPREP).
            TValue.setInt(v_limit, ii);
            TValue.setInt(&stack[base + a + 3], ii);
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .FORLOOP => {
            // Count-based: decrement the staged trip count and advance the
            // user variable, mirroring opFORLOOP. Float loops (non-integer
            // control slot) and a user variable clobbered to a non-integer
            // exit to the full handler with pc still at the FORLOOP.
            const a = inst.getA();
            const ctrl = &stack[base + a];
            if (!ctrl.isInteger()) return;
            const count: u64 = @bitCast(ctrl.asInt());
            pc += 1;
            if (count > 0) {
                TValue.setInt(ctrl, @bitCast(count - 1));
                // Advance the pristine index (old limit slot) and refresh
                // the user variable from it (see opFORLOOP).
                const idx_slot = &stack[base + a + 1];
                const idx = idx_slot.asInt() +% stack[base + a + 2].asInt();
                TValue.setInt(idx_slot, idx);
                TValue.setInt(&stack[base + a + 3], idx);
                pc = jumpTarget(pc, inst.getSBx());
                // Loop back-edge: safepoint.
                if (vm.slow_work_signal or interrupt.isPending()) return;
            }
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .CLOSE => {
            // Emitted at every loop back-edge by the compiler. To-be-closed
            // slots need __close metamethod calls and exit; plain upvalue
            // closing is infallible and stays in the loop.
            if (cur.tbc_bitmap != 0) return;
            if (openUpvaluesReach(vm, stack, base + inst.getA())) {
                vm.closeUpvalues(base + inst.getA());
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .GETUPVAL => {
            const closure = cur.closure orelse return;
            const b = inst.getB();
            stack[base + inst.getA()] = if (b < closure.upvalues.len)
                closure.upvalues[b].get()
            else
                .nil;
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .SETUPVAL => {
            const closure = cur.closure orelse return;
            const b = inst.getB();
            if (b < closure.upvalues.len) {
                mutation.upvalueSet(vm.gc(), closure.upvalues[b], stack[base + inst.getA()]);
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .GETTABLE => {
            // Integer keys: array hits read inline, hash hits go through
            // get(). String keys (register-valued, so the per-pc IC does
            // not apply): direct hash hits via getPtr, with the same
            // field-cache hint the full handler records for diagnostics.
            // Misses may need __index and exit; nil/float keys have their
            // own semantics in the full handler.
            const table = stack[base + inst.getB()].asTable() orelse return;
            const key = &stack[base + inst.getC()];
            if (key.isInteger()) {
                const i = key.asInt();
                if (i >= 1 and i <= @as(i64, @intCast(table.array.items.len))) {
                    const value = table.array.items[@intCast(i - 1)];
                    if (value.isNil()) return;
                    stack[base + inst.getA()] = value;
                } else {
                    const value = table.get(key.*) orelse return;
                    stack[base + inst.getA()] = value;
                }
            } else if (key.asString()) |key_str| {
                field_cache.rememberFieldAccess(vm, inst.getA(), key_str, table == vm.globals(), false);
                const slot = table.getPtr(key.*) orelse return;
                stack[base + inst.getA()] = slot.*;
            } else {
                return;
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .GETI => {
            // Table read with an integer immediate key; only the direct hit
            // stays here (opGETI records no field-cache hint, so semantics
            // match). Misses may need __index and exit.
            const table = stack[base + inst.getB()].asTable() orelse return;
            const i = @as(i64, inst.getC());
            if (i >= 1 and i <= @as(i64, @intCast(table.array.items.len))) {
                const value = table.array.items[@intCast(i - 1)];
                if (value.isNil()) return;
                stack[base + inst.getA()] = value;
            } else {
                const value = table.get(TValue.fromInt(i)) orelse return;
                stack[base + inst.getA()] = value;
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .NOT => {
            TValue.setBool(&stack[base + inst.getA()], !stack[base + inst.getB()].toBoolean());
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .UNM => {
            const vb = &stack[base + inst.getB()];
            if (vb.isInteger()) {
                TValue.setInt(&stack[base + inst.getA()], 0 -% vb.asInt());
            } else if (vb.isNumber()) {
                TValue.setFloat(&stack[base + inst.getA()], -vb.asFloat());
            } else {
                // String coercion / __unm: full handler.
                return;
            }
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
                    .ADD => vb.asInt() +% vc.asInt(),
                    .SUB => vb.asInt() -% vc.asInt(),
                    .MUL => vb.asInt() *% vc.asInt(),
                    else => unreachable,
                };
                TValue.setInt(&stack[base + inst.getA()], res);
            } else {
                // Float or int-float mixed; strings/metamethods exit to
                // the full handler.
                const fb = numberToFloat(vb) orelse return;
                const fc = numberToFloat(vc) orelse return;
                const res = switch (inst.getOpCode()) {
                    .ADD => fb + fc,
                    .SUB => fb - fc,
                    .MUL => fb * fc,
                    else => unreachable,
                };
                TValue.setFloat(&stack[base + inst.getA()], res);
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
                    .ADDK => vb.asInt() +% vc.asInt(),
                    .SUBK => vb.asInt() -% vc.asInt(),
                    .MULK => vb.asInt() *% vc.asInt(),
                    else => unreachable,
                };
                TValue.setInt(&stack[base + inst.getA()], res);
            } else {
                const fb = numberToFloat(vb) orelse return;
                const fc = numberToFloat(vc) orelse return;
                const res = switch (inst.getOpCode()) {
                    .ADDK => fb + fc,
                    .SUBK => fb - fc,
                    .MULK => fb * fc,
                    else => unreachable,
                };
                TValue.setFloat(&stack[base + inst.getA()], res);
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        // Convention: the hottest arithmetic (ADD/SUB/MUL and their K
        // forms) gets separate arms so operand selection is branch-free;
        // rarer DIV/MOD pairs share an arm and select the K operand with a
        // well-predicted runtime branch. Both are deliberate.
        .DIV, .DIVK => {
            // Lua '/' is always float arithmetic, including int/int;
            // coercion/metamethods exit to the full handler.
            const vb = &stack[base + inst.getB()];
            const vc = if (inst.getOpCode() == .DIVK)
                &k[inst.getC()]
            else
                &stack[base + inst.getC()];
            const fb = numberToFloat(vb) orelse return;
            const fc = numberToFloat(vc) orelse return;
            TValue.setFloat(&stack[base + inst.getA()], fb / fc);
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .BAND, .BOR, .BXOR, .BANDK, .BORK, .BXORK => {
            // Integer-only; floats with integral values, strings and
            // metamethods take the full handler's coercion path.
            const vb = &stack[base + inst.getB()];
            const vc = switch (inst.getOpCode()) {
                .BANDK, .BORK, .BXORK => &k[inst.getC()],
                else => &stack[base + inst.getC()],
            };
            if (!vb.isInteger() or !vc.isInteger()) return;
            const ib: u64 = @bitCast(vb.asInt());
            const ic: u64 = @bitCast(vc.asInt());
            const res: u64 = switch (inst.getOpCode()) {
                .BAND, .BANDK => ib & ic,
                .BOR, .BORK => ib | ic,
                .BXOR, .BXORK => ib ^ ic,
                else => unreachable,
            };
            TValue.setInt(&stack[base + inst.getA()], @bitCast(res));
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .SHL, .SHR => {
            // Plain in-range shifts only; negative and >= 64 counts have
            // Lua-specific semantics (direction flip, saturate to zero)
            // handled by the full path, as do coercion and metamethods.
            const vb = &stack[base + inst.getB()];
            const vc = &stack[base + inst.getC()];
            if (!vb.isInteger() or !vc.isInteger()) return;
            const shift = vc.asInt();
            if (shift < 0 or shift >= 64) return;
            const u: u64 = @bitCast(vb.asInt());
            const res: u64 = if (inst.getOpCode() == .SHL)
                u << @intCast(shift)
            else
                u >> @intCast(shift);
            TValue.setInt(&stack[base + inst.getA()], @bitCast(res));
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .MOD, .MODK => {
            // Integer floor modulo (Zig's @mod matches Lua's
            // divisor-signed result). Zero divisor is the n%0 error path
            // and minInt % -1 would overflow the division — both exit;
            // float mod needs fmod sign correction and exits too.
            const vb = &stack[base + inst.getB()];
            const vc = if (inst.getOpCode() == .MODK)
                &k[inst.getC()]
            else
                &stack[base + inst.getC()];
            if (!vb.isInteger() or !vc.isInteger()) return;
            const divisor = vc.asInt();
            if (divisor == 0 or divisor == -1) return;
            TValue.setInt(&stack[base + inst.getA()], @mod(vb.asInt(), divisor));
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .LTI, .LEI, .GTI, .GEI => {
            const left = &stack[base + inst.getB()];
            const a = inst.getA();
            const imm: i64 = @as(i8, @bitCast(@as(u8, inst.getC())));
            var is_true: bool = undefined;
            if (left.isInteger()) {
                is_true = switch (inst.getOpCode()) {
                    .LTI => left.asInt() < imm,
                    .LEI => left.asInt() <= imm,
                    .GTI => imm < left.asInt(),
                    .GEI => imm <= left.asInt(),
                    else => unreachable,
                };
            } else if (left.isNumber()) {
                // The i8 immediate converts to f64 exactly, so the plain
                // float compare matches ltOp/leOp (NaN compares false).
                const fimm: f64 = @floatFromInt(imm);
                is_true = switch (inst.getOpCode()) {
                    .LTI => left.asFloat() < fimm,
                    .LEI => left.asFloat() <= fimm,
                    .GTI => fimm < left.asFloat(),
                    .GEI => fimm <= left.asFloat(),
                    else => unreachable,
                };
            } else {
                return;
            }
            const skip = (is_true and a == 0) or (!is_true and a != 0);
            pc += if (skip) 2 else 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .EQ, .LT, .LE => {
            const left = &stack[base + inst.getB()];
            const right = &stack[base + inst.getC()];
            const negate = inst.getA();
            var is_true: bool = undefined;
            if (left.isInteger() and right.isInteger()) {
                is_true = switch (inst.getOpCode()) {
                    .EQ => left.asInt() == right.asInt(),
                    .LT => left.asInt() < right.asInt(),
                    .LE => left.asInt() <= right.asInt(),
                    else => unreachable,
                };
            } else if (left.isNumber() and right.isNumber()) {
                is_true = switch (inst.getOpCode()) {
                    .EQ => left.asFloat() == right.asFloat(),
                    .LT => left.asFloat() < right.asFloat(),
                    .LE => left.asFloat() <= right.asFloat(),
                    else => unreachable,
                };
            } else if (inst.getOpCode() == .EQ) {
                const l_num = left.isInteger() or left.isNumber();
                const r_num = right.isInteger() or right.isNumber();
                if (l_num and r_num) {
                    // Mixed int/float needs exact mathematical comparison:
                    // full handler.
                    return;
                }
                if (left.kind() != right.kind()) {
                    // Different types never compare equal and __eq is not
                    // consulted (it needs two tables or two userdata).
                    is_true = false;
                } else switch (left.kind()) {
                    .nil => is_true = true,
                    .boolean => is_true = left.asBool() == right.asBool(),
                    .object => {
                        const lp = left.asObjectPtr();
                        const rp = right.asObjectPtr();
                        if (lp == rp) {
                            // rawequal: __eq is never consulted for
                            // identical objects, exact for every type.
                            is_true = true;
                        } else if (lp.type == .string and rp.type == .string) {
                            // Interned strings are deduplicated, so
                            // distinct pointers mean distinct contents. A
                            // non-interned (long) string still needs a
                            // content compare: exit.
                            const ls = object.getObject(object.StringObject, lp);
                            const rs = object.getObject(object.StringObject, rp);
                            if (!ls.interned or !rs.interned) return;
                            is_true = false;
                        } else {
                            // Distinct tables/userdata may have __eq.
                            return;
                        }
                    },
                    else => unreachable,
                }
            } else {
                // LT/LE on strings and metamethods take the full handler.
                return;
            }
            const skip = (is_true and negate == 0) or (!is_true and negate != 0);
            pc += if (skip) 2 else 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .TFORCALL => {
            // Specialized for the builtin ipairs iterator: the whole step
            // (index increment, array read, result placement) runs inline
            // instead of a native call frame per element. ipairs honors
            // __index, so a raw miss on a table with a metatable exits.
            const a = inst.getA();
            const func_val = &stack[base + a];
            if (!func_val.isObject() or func_val.asObjectPtr().type != .native_closure) return;
            const nc = object.getObject(object.NativeClosureObject, func_val.asObjectPtr());
            if (nc.func.id != .ipairs_iterator) return;
            const table = stack[base + a + 1].asTable() orelse return;
            const control = &stack[base + a + 2];
            if (!control.isInteger()) return;
            const next_index = control.asInt() +% 1;

            var value: TValue = .nil;
            if (next_index >= 1 and next_index <= @as(i64, @intCast(table.array.items.len))) {
                value = table.array.items[@intCast(next_index - 1)];
            } else if (table.get(TValue.fromInt(next_index))) |v| {
                value = v;
            }
            if (value.isNil() and table.metatable != null) return;

            const c = inst.getC();
            const nresults: u32 = if (c > 0) c else 1;
            const res = base + a + 4;
            if (value.isNil()) {
                var j: u32 = 0;
                while (j < nresults) : (j += 1) stack[res + j] = .nil;
            } else {
                TValue.setInt(&stack[res], next_index);
                if (nresults > 1) stack[res + 1] = value;
                var j: u32 = 2;
                while (j < nresults) : (j += 1) stack[res + j] = .nil;
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .TFORLOOP => {
            const a = inst.getA();
            const first_var = stack[base + a + 4];
            pc += 1;
            if (!first_var.isNil()) {
                stack[base + a + 2] = first_var;
                pc = jumpTarget(pc, inst.getSBx());
                // Loop back-edge: safepoint.
                if (vm.slow_work_signal or interrupt.isPending()) return;
            }
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .CALL => {
            // Fast path: fixed-arg call of a non-vararg Lua closure. Vararg
            // callees, top-defined argument counts (B == 0), native/pcall
            // callees, and a full callstack take the outer handler. Calls
            // are also safepoints (recursion has no back-edges).
            const func_val = &stack[base + inst.getA()];
            if (!func_val.isObject()) return;
            // Pure-math native leaves run inline (like TFORCALL's ipairs
            // specialization): one numeric argument, one float result, no
            // frame, no error path. String coercion and each native's own
            // bad-argument behavior stay in the full handler.
            if (func_val.asObjectPtr().type == .native_closure) {
                if (inst.getB() != 2 or inst.getC() != 2) return;
                const nc = object.getObject(object.NativeClosureObject, func_val.asObjectPtr());
                const arg = &stack[base + inst.getA() + 1];
                const x = numberToFloat(arg) orelse return;
                const r = switch (nc.func.id) {
                    .math_sqrt => @sqrt(x),
                    .math_sin => @sin(x),
                    .math_cos => @cos(x),
                    else => return,
                };
                TValue.setFloat(&stack[base + inst.getA()], r);
                pc += 1;
                inst = pc[0];
                continue :dispatch inst.getOpCode();
            }
            const func_closure = func_val.asClosure() orelse return;
            const proto = func_closure.proto;
            if (proto.is_vararg) return;
            const b = inst.getB();
            if (b == 0) return;
            if (vm.callstack_size >= vm.callstack.len) return;
            if (vm.slow_work_signal or interrupt.isPending()) return;

            const a = inst.getA();
            pc += 1;
            cur.pc = pc;

            // Mirror stageLuaCallFrameFromStack's non-vararg path: shift
            // the arguments one slot down over the function value.
            const new_base = base + a;
            stageFixedArgs(stack, new_base, new_base + 1, b - 1, proto.numparams);

            const c = inst.getC();
            const nresults: i16 = if (c > 0) @as(i16, @intCast(c - 1)) else -1;
            const new_ci = &vm.callstack[vm.callstack_size];
            new_ci.* = CallInfo.init(proto, func_closure, new_base, new_base, nresults, cur, 0, 0);
            call_debug.applyToCallInfo(vm, new_ci);
            vm.callstack_size += 1;
            vm.ci = new_ci;
            vm.base = new_base;
            vm.top = new_base + proto.maxstacksize;

            cur = new_ci;
            base = new_base;
            k = proto.k;
            pc = proto.code.ptr;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .TAILCALL => {
            // Frame-reuse fast path mirroring reuseTailClosureFrame's
            // non-vararg case: fixed-arg tail call of a Lua closure with no
            // TBC slots to close (k flag). Upvalues over this frame close
            // in place (infallible); __call chains, natives and varargs
            // exit. Tail calls are safepoints like CALL.
            if (inst.getk() or cur.tbc_bitmap != 0) return;
            const b = inst.getB();
            if (b == 0) return;
            const a = inst.getA();
            const func_val = &stack[base + a];
            if (!func_val.isObject()) return;
            const func_closure = func_val.asClosure() orelse return;
            const proto = func_closure.proto;
            if (proto.is_vararg) return;
            if (vm.slow_work_signal or interrupt.isPending()) return;

            if (openUpvaluesReach(vm, stack, base)) {
                vm.closeUpvalues(base);
            }

            // Shift the arguments down over the reused frame's base.
            stageFixedArgs(stack, base, base + a + 1, b - 1, proto.numparams);

            const sync_boundary = cur.sync_boundary;
            cur.reset(proto, func_closure, base, cur.ret_base, cur.nresults, cur.previous, 0, 0);
            cur.was_tail_called = true;
            cur.sync_boundary = sync_boundary;
            vm.top = base + proto.maxstacksize;

            k = proto.k;
            pc = proto.code.ptr;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .RETURN0, .RETURN1 => {
            // Fast path mirrors prepareReturn's no-suspend case plus
            // finishReturnToCaller and popCallInfo for non-protected frames.
            if (cur.tbc_bitmap != 0 or cur.continuation != .none) return;
            if (cur.is_protected) return;
            // A reentrant executor (runUntilReturn / executeSyncMM) owns
            // this frame's return; hand control back to its loop.
            if (cur.sync_boundary) return;
            // Open upvalues inside this frame need real closing: exit.
            // Outer frames' open upvalues don't block the fast return.
            if (openUpvaluesReach(vm, stack, base)) return;
            const prev = cur.previous orelse return;
            // A pending continuation on the CALLER means this frame was
            // staged by a dispatch handler (e.g. a comparison metamethod)
            // that must consume the result when the frame returns — the
            // outer loop runs it; a fast pop here would skip it.
            if (prev.continuation != .none) return;

            const is_return1 = inst.getOpCode() == .RETURN1;
            const ret_val = if (is_return1) stack[base + inst.getA()] else TValue.nil;
            const nresults = cur.nresults;
            const dst = cur.ret_base;

            vm.callstack_size -= 1;
            vm.ci = prev;
            vm.base = prev.base;

            if (nresults < 0) {
                if (is_return1) {
                    stack[dst] = ret_val;
                    vm.top = dst + 1;
                } else {
                    vm.top = dst;
                }
            } else {
                const n: u32 = @intCast(nresults);
                var j: u32 = 0;
                if (is_return1 and n >= 1) {
                    stack[dst] = ret_val;
                    j = 1;
                }
                while (j < n) : (j += 1) {
                    stack[dst + j] = .nil;
                }
                vm.top = prev.base + prev.func.maxstacksize;
            }

            cur = prev;
            base = prev.base;
            k = prev.func.k;
            pc = prev.pc;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .GETFIELD => {
            // String-key table read. The diagnostic hint is recorded like
            // the full handler does (before the lookup); anything that
            // cannot be resolved as a direct hit or a one-level
            // __index-table hit exits to the full handler.
            const table = stack[base + inst.getB()].asTable() orelse return;
            const key_val = k[inst.getC()];
            const key = key_val.asString() orelse return;
            field_cache.rememberFieldAccess(vm, inst.getA(), key, false, false);
            const entry = fieldIcEntry(vm, pc);
            if (icDirectHit(entry, pc, table, vm.ic_epoch)) {
                stack[base + inst.getA()] = entry.slot.*;
            } else if (readFieldSlow(vm, pc, table, key_val)) |value| {
                stack[base + inst.getA()] = value;
            } else {
                return;
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .SELF => {
            // Method lookup: R[A+1] := receiver, R[A] := receiver[K[C]].
            // Shares the field cache, including the __index-chain form that
            // resolves class methods through the metatable.
            const receiver = stack[base + inst.getB()];
            const table = receiver.asTable() orelse return;
            const key_val = k[inst.getC()];
            const key = key_val.asString() orelse return;
            field_cache.rememberFieldAccess(vm, inst.getA(), key, false, true);
            const entry = fieldIcEntry(vm, pc);
            if (icDirectHit(entry, pc, table, vm.ic_epoch)) {
                stack[base + inst.getA() + 1] = receiver;
                stack[base + inst.getA()] = entry.slot.*;
            } else if (readFieldSlow(vm, pc, table, key_val)) |value| {
                stack[base + inst.getA() + 1] = receiver;
                stack[base + inst.getA()] = value;
            } else {
                return;
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .GETTABUP => {
            // Global (or _ENV field) read through an upvalue table.
            const closure = cur.closure orelse return;
            const b = inst.getB();
            if (b >= closure.upvalues.len) return;
            const table = closure.upvalues[b].get().asTable() orelse return;
            const key_val = k[inst.getC()];
            const key = key_val.asString() orelse return;
            field_cache.rememberFieldAccess(vm, inst.getA(), key, true, false);
            const entry = fieldIcEntry(vm, pc);
            if (icDirectHit(entry, pc, table, vm.ic_epoch)) {
                stack[base + inst.getA()] = entry.slot.*;
            } else {
                const slot = table.getPtr(key_val) orelse return;
                stack[base + inst.getA()] = slot.*;
                entry.* = .{
                    .pc = @intFromPtr(pc),
                    .table = @intFromPtr(table),
                    .shape = table.shape_count,
                    .epoch = vm.ic_epoch,
                    .slot = slot,
                };
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .SETFIELD => {
            // String-key write to an existing slot: in-place update through
            // the write barrier. Absent keys (possible __newindex) and nil
            // stores (removal bookkeeping) exit to the full handler.
            const table = stack[base + inst.getA()].asTable() orelse return;
            const key_val = k[inst.getB()];
            if (key_val.asString() == null) return;
            const value = stack[base + inst.getC()];
            if (value.isNil()) return;
            const slot = table.getPtr(key_val) orelse return;
            slot.* = value;
            table.mod_count +%= 1;
            vm.gc().barrierBackValue(&table.header, value);
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .SETTABLE, .SETI => {
            // Two array-part cases stay in the loop; everything else exits.
            // In-place: integer key within the sequence border and a non-nil
            // slot (an absent key would need __newindex). Fresh append: one
            // past the end of a table with empty hash and deleted-key parts
            // and no metatable — the constructor-fill shape, mirroring
            // TableObject.set's fast path. Object values take the backward
            // barrier (infallible); nil writes are removals and exit.
            const table = stack[base + inst.getA()].asTable() orelse return;
            const value = stack[base + inst.getC()];
            if (value.isNil()) return;
            const i: i64 = if (inst.getOpCode() == .SETI)
                @as(i64, inst.getB())
            else blk: {
                const key = &stack[base + inst.getB()];
                if (key.isInteger()) break :blk key.asInt();
                if (key.asString() != null) {
                    // String key on an existing slot: in-place update
                    // through the write barrier, mirroring SETFIELD.
                    // Absent keys (possible __newindex) exit.
                    const slot = table.getPtr(key.*) orelse return;
                    slot.* = value;
                    table.mod_count +%= 1;
                    if (value.isObject()) {
                        vm.gc().barrierBackValue(&table.header, value);
                    }
                    pc += 1;
                    inst = pc[0];
                    continue :dispatch inst.getOpCode();
                }
                return;
            };
            const alen: i64 = @intCast(table.array.items.len);
            if (i >= 1 and i <= table.seq_len and i <= alen) {
                const slot = &table.array.items[@intCast(i - 1)];
                if (slot.isNil()) return;
                slot.* = value;
                table.mod_count +%= 1;
            } else if (i == alen + 1 and table.metatable == null) {
                // On OOM the table is untouched; the defer leaves pc at
                // this SETI so the outer handler re-executes it. The
                // append invariant lives in TableObject.tryAppendFresh.
                const appended = table.tryAppendFresh(i, value) catch return;
                if (!appended) return;
            } else return;
            if (value.isObject()) {
                vm.gc().barrierBackValue(&table.header, value);
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .SETLIST => {
            // Constructor flush appending right at the array end of a table
            // with no hash/deleted entries and no nil values — the same
            // bulk store opSETLIST fast-paths. B == 0 takes the count from
            // vm.top (multret tails), which the CALL/RETURN arms keep
            // current. Anything else exits; OOM bails with pc still at the
            // SETLIST so the outer handler re-executes it.
            const a = inst.getA();
            const table = stack[base + a].asTable() orelse return;
            var next_pc = pc + 1;
            const start: i64 = if (inst.getk()) blk: {
                const ax = @as(i64, pc[1].getAx());
                next_pc = pc + 2;
                break :blk if (inst.getC() == 0) ax else (ax - 1) * 50 + 1;
            } else (@as(i64, inst.getC()) - 1) * 50 + 1;
            const b = inst.getB();
            const n: u32 = if (b > 0) b else vm.top - (base + a + 1);
            if (n > 0) {
                if (start != @as(i64, @intCast(table.array.items.len)) + 1) return;
                if (table.hash_part.count() != 0 or table.deleted_keys.count() != 0) return;
                // vm.stack, not the `stack` local: a pointer-to-slice can
                // be indexed but not sliced.
                const values = vm.stack[base + a + 1 ..][0..n];
                for (values) |v| {
                    if (v.isNil()) return;
                }
                mutation.tableExtendArray(vm.gc(), table, values) catch return;
            }
            pc = next_pc;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .NEWTABLE => {
            // Allocation may run a GC cycle; vm.base/top/ci are kept in
            // sync at frame switches, so roots are consistent mid-loop. On
            // OOM the defer leaves pc at this NEWTABLE and the outer
            // handler re-executes it, raising through the normal path.
            const table = vm.gc().allocTable() catch return;
            const array_hint = inst.getC();
            if (array_hint > 0) {
                // Bail on OOM; the orphaned table is collected normally.
                table.array.ensureTotalCapacityPrecise(table.allocator, array_hint) catch return;
            }
            stack[base + inst.getA()] = TValue.fromTable(table);
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        else => return,
    }
}

/// Numeric coercion for float arithmetic: floats pass through, integers
/// convert, everything else (strings, objects) returns null so the arm
/// exits to the full handler.
inline fn numberToFloat(v: *const TValue) ?f64 {
    if (v.isNumber()) return v.asFloat();
    if (v.isInteger()) return @floatFromInt(v.asInt());
    return null;
}

/// Apply a signed instruction offset (JMP sJ, FORPREP/FORLOOP/TFORLOOP
/// sBx) to a pc that has already been advanced past the instruction.
inline fn jumpTarget(pc: [*]const Instruction, offset: i32) [*]const Instruction {
    return if (offset >= 0)
        pc + @as(usize, @intCast(offset))
    else
        pc - @as(usize, @intCast(-offset));
}

/// True when the open-upvalue list reaches into the frame starting at
/// `level`. The list is sorted by descending stack address, so checking
/// the head suffices; outer frames' open upvalues don't count.
inline fn openUpvaluesReach(vm: *const VM, stack: anytype, level: u32) bool {
    const uv = vm.open_upvalues orelse return false;
    const uv_level = (@intFromPtr(uv.location) - @intFromPtr(&stack[0])) / @sizeOf(TValue);
    return uv_level >= level;
}

/// Stage a fixed-arg Lua call: copy the supplied arguments to the callee
/// frame base and nil-fill missing parameters (CALL shifts one slot down
/// over the function value; TAILCALL shifts onto the reused base).
inline fn stageFixedArgs(stack: anytype, dst: u32, src: u32, nargs: u32, numparams: u32) void {
    const params_to_copy = @min(nargs, numparams);
    var i: u32 = 0;
    while (i < params_to_copy) : (i += 1) {
        stack[dst + i] = stack[src + i];
    }
    while (i < numparams) : (i += 1) {
        stack[dst + i] = .nil;
    }
}

/// Direct-mapped field-IC slot for an instruction address. Instructions
/// are 4 bytes, so the low bits index after the shift; the mask derives
/// from the table length (a power of two).
inline fn fieldIcEntry(vm: *VM, pc: [*]const Instruction) *VM.FieldICEntry {
    return &vm.field_ic[(@intFromPtr(pc) >> 2) & (vm.field_ic.len - 1)];
}

/// Direct-hit validation shared by GETFIELD/SELF/GETTABUP: same site,
/// same table, structure unchanged, IC generation current, not a chain
/// entry, and a live slot. (GETTABUP sites never store chain entries, so
/// the chain check is redundant-but-free there; sharing one predicate
/// keeps the invariant in one place.)
inline fn icDirectHit(entry: *const VM.FieldICEntry, pc: [*]const Instruction, table: *const object.TableObject, ic_epoch: u64) bool {
    return entry.pc == @intFromPtr(pc) and entry.table == @intFromPtr(table) and
        entry.shape == table.shape_count and entry.epoch == ic_epoch and
        entry.chain_table == 0 and !entry.slot.isNil();
}

/// Slow half of the field cache: chain hits (the class-method pattern),
/// misses, and cache fills. The direct-hit check lives inline in the
/// GETFIELD/SELF arms. Returns null when the full handler must take over
/// (deep chains, __index functions, true misses).
fn readFieldSlow(vm: *VM, pc: [*]const Instruction, table: *object.TableObject, key_val: TValue) ?TValue {
    const entry = fieldIcEntry(vm, pc);
    if (entry.pc == @intFromPtr(pc) and entry.table == @intFromPtr(table) and
        entry.shape == table.shape_count and entry.epoch == vm.ic_epoch)
    {
        if (entry.chain_table != 0) {
            if (table.metatable) |mt| {
                // Chain entry: the metatable's __index slot must be intact
                // and still reference the same target table, whose shape
                // guards the cached value slot.
                if (mt.shape_count == entry.mt_shape) {
                    const mm = entry.mm_slot.?.*;
                    if (mm.isObject() and @intFromPtr(mm.asObjectPtr()) == entry.chain_table) {
                        const target: *object.TableObject = @ptrFromInt(entry.chain_table);
                        if (target.shape_count == entry.chain_shape) {
                            const v = entry.slot.*;
                            if (!v.isNil()) return v;
                        }
                    }
                }
            }
        }
    }

    // Miss: resolve directly, then through one __index table level.
    if (table.getPtr(key_val)) |slot| {
        const v = slot.*;
        entry.* = .{
            .pc = @intFromPtr(pc),
            .table = @intFromPtr(table),
            .shape = table.shape_count,
            .epoch = vm.ic_epoch,
            .slot = slot,
        };
        return v;
    }
    const mt = table.metatable orelse return null;
    const mm_key = TValue.fromString(vm.gc().mm_keys.get(.index));
    const mm_slot = mt.getPtr(mm_key) orelse return null;
    const mm = mm_slot.*;
    const target = mm.asTable() orelse return null;
    const slot = target.getPtr(key_val) orelse return null;
    const v = slot.*;
    entry.* = .{
        .pc = @intFromPtr(pc),
        .table = @intFromPtr(table),
        .shape = table.shape_count,
        .epoch = vm.ic_epoch,
        .slot = slot,
        .mt_shape = mt.shape_count,
        .mm_slot = mm_slot,
        .chain_table = @intFromPtr(&target.header),
        .chain_shape = target.shape_count,
    };
    return v;
}
