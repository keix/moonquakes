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
            if (cur.tbc_bitmap != 0 or vm.open_upvalues != null) return;
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
            // Only integer keys: string keys record a field-cache hint in
            // the full handler (error diagnostics), nil/float keys have
            // their own semantics there. Array hits are read inline; hash
            // hits go through get(); misses may need __index and exit.
            const table = stack[base + inst.getB()].asTable() orelse return;
            const key = &stack[base + inst.getC()];
            if (!key.isInteger()) return;
            const i = key.integer;
            if (i >= 1 and i <= @as(i64, @intCast(table.array.items.len))) {
                const value = table.array.items[@intCast(i - 1)];
                if (value.isNil()) return;
                stack[base + inst.getA()] = value;
            } else {
                const value = table.get(key.*) orelse return;
                stack[base + inst.getA()] = value;
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
                const value = table.get(.{ .integer = i }) orelse return;
                stack[base + inst.getA()] = value;
            }
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .NOT => {
            stack[base + inst.getA()] = .{ .boolean = !stack[base + inst.getB()].toBoolean() };
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        .UNM => {
            const vb = &stack[base + inst.getB()];
            if (vb.isInteger()) {
                stack[base + inst.getA()] = .{ .integer = 0 -% vb.integer };
            } else if (vb.isNumber()) {
                stack[base + inst.getA()] = .{ .number = -vb.number };
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
            const a = inst.getA();
            const imm: i64 = @as(i8, @bitCast(@as(u8, inst.getC())));
            var is_true: bool = undefined;
            if (left.isInteger()) {
                is_true = switch (inst.getOpCode()) {
                    .LTI => left.integer < imm,
                    .LEI => left.integer <= imm,
                    .GTI => imm < left.integer,
                    .GEI => imm <= left.integer,
                    else => unreachable,
                };
            } else if (left.isNumber()) {
                // The i8 immediate converts to f64 exactly, so the plain
                // float compare matches ltOp/leOp (NaN compares false).
                const fimm: f64 = @floatFromInt(imm);
                is_true = switch (inst.getOpCode()) {
                    .LTI => left.number < fimm,
                    .LEI => left.number <= fimm,
                    .GTI => fimm < left.number,
                    .GEI => fimm <= left.number,
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
                    .EQ => left.integer == right.integer,
                    .LT => left.integer < right.integer,
                    .LE => left.integer <= right.integer,
                    else => unreachable,
                };
            } else if (left.isNumber() and right.isNumber()) {
                is_true = switch (inst.getOpCode()) {
                    .EQ => left.number == right.number,
                    .LT => left.number < right.number,
                    .LE => left.number <= right.number,
                    else => unreachable,
                };
            } else {
                // Mixed int/float exactness, strings, and metamethods take
                // the full handler.
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
            if (!func_val.isObject() or func_val.object.type != .native_closure) return;
            const nc = object.getObject(object.NativeClosureObject, func_val.object);
            if (nc.func.id != .ipairs_iterator) return;
            const table = stack[base + a + 1].asTable() orelse return;
            const control = &stack[base + a + 2];
            if (!control.isInteger()) return;
            const next_index = control.integer +% 1;

            var value: TValue = .nil;
            if (next_index >= 1 and next_index <= @as(i64, @intCast(table.array.items.len))) {
                value = table.array.items[@intCast(next_index - 1)];
            } else if (table.get(.{ .integer = next_index })) |v| {
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
                stack[res] = .{ .integer = next_index };
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
                const sbx = inst.getSBx();
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
        .CALL => {
            // Fast path: fixed-arg call of a non-vararg Lua closure. Vararg
            // callees, top-defined argument counts (B == 0), native/pcall
            // callees, and a full callstack take the outer handler. Calls
            // are also safepoints (recursion has no back-edges).
            const func_val = &stack[base + inst.getA()];
            if (!func_val.isObject()) return;
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
            const nargs: u32 = b - 1;
            const params_to_copy = @min(nargs, @as(u32, proto.numparams));
            var i: u32 = 0;
            while (i < params_to_copy) : (i += 1) {
                stack[new_base + i] = stack[new_base + 1 + i];
            }
            while (i < proto.numparams) : (i += 1) {
                stack[new_base + i] = .nil;
            }

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
        .RETURN0, .RETURN1 => {
            // Fast path mirrors prepareReturn's no-suspend case plus
            // finishReturnToCaller and popCallInfo for non-protected frames.
            if (cur.tbc_bitmap != 0 or cur.continuation != .none) return;
            if (cur.is_protected) return;
            if (vm.open_upvalues != null) return;
            const prev = cur.previous orelse return;

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
            // the full handler does (before the lookup); a miss may need
            // __index and exits.
            const table = stack[base + inst.getB()].asTable() orelse return;
            const key_val = k[inst.getC()];
            const key = key_val.asString() orelse return;
            field_cache.rememberFieldAccess(vm, inst.getA(), key, false, false);
            // Slot-pointer inline cache: valid while the table's structure
            // (shape_count) and the GC epoch are unchanged. In-place value
            // writes keep the cache hot; a nil slot means the key became
            // absent (array hole), which falls back to the lookup.
            const entry = &vm.field_ic[(@intFromPtr(pc) >> 2) & 63];
            if (entry.pc == @intFromPtr(pc) and entry.table == @intFromPtr(table) and
                entry.shape == table.shape_count and entry.epoch == vm.ic_epoch and
                !entry.slot.isNil())
            {
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
        .GETTABUP => {
            // Global (or _ENV field) read through an upvalue table.
            const closure = cur.closure orelse return;
            const b = inst.getB();
            if (b >= closure.upvalues.len) return;
            const table = closure.upvalues[b].get().asTable() orelse return;
            const key_val = k[inst.getC()];
            const key = key_val.asString() orelse return;
            field_cache.rememberFieldAccess(vm, inst.getA(), key, true, false);
            const entry = &vm.field_ic[(@intFromPtr(pc) >> 2) & 63];
            if (entry.pc == @intFromPtr(pc) and entry.table == @intFromPtr(table) and
                entry.shape == table.shape_count and entry.epoch == vm.ic_epoch and
                !entry.slot.isNil())
            {
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
            // Array-part write with no side channel: integer key within the
            // sequence border, non-nil slot (an absent key would need
            // __newindex), and a non-collectable value (an object value
            // would need the GC write barrier). Everything else exits.
            const table = stack[base + inst.getA()].asTable() orelse return;
            const i: i64 = if (inst.getOpCode() == .SETI)
                @as(i64, inst.getB())
            else blk: {
                const key = &stack[base + inst.getB()];
                if (!key.isInteger()) return;
                break :blk key.integer;
            };
            const value = stack[base + inst.getC()];
            if (value == .object or value.isNil()) return;
            if (i < 1 or i > table.seq_len) return;
            if (i > @as(i64, @intCast(table.array.items.len))) return;
            const slot = &table.array.items[@intCast(i - 1)];
            if (slot.isNil()) return;
            slot.* = value;
            table.mod_count +%= 1;
            pc += 1;
            inst = pc[0];
            continue :dispatch inst.getOpCode();
        },
        else => return,
    }
}
