const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const opcodes = @import("../compiler/opcodes.zig");
const OpCode = opcodes.OpCode;
const Instruction = opcodes.Instruction;
const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;
const UpvalueObject = object.UpvalueObject;
const metamethod = @import("metamethod.zig");
const MetaEvent = metamethod.MetaEvent;
const builtin = @import("../builtin/dispatch.zig");
const ErrorHandler = @import("error.zig");

// Execution ABI: CallInfo (frame), ReturnValue (result)
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const ReturnValue = execution.ReturnValue;
const ExecuteResult = execution.ExecuteResult;

// Import VM (one-way dependency: Mnemonics -> VM)
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;

// ============================================================================
// Arithmetic Operations
// ============================================================================

pub const ArithOp = enum { add, sub, mul, div, idiv, mod, pow };
pub const BitwiseOp = enum { band, bor, bxor };

pub fn luaFloorDiv(a: f64, b: f64) f64 {
    return @floor(a / b);
}

pub fn luaMod(a: f64, b: f64) f64 {
    return a - luaFloorDiv(a, b) * b;
}

pub fn arithBinary(vm: *VM, inst: Instruction, comptime tag: ArithOp) !void {
    const a = inst.getA();
    const b = inst.getB();
    const c = inst.getC();
    const vb = &vm.stack[vm.base + b];
    const vc = &vm.stack[vm.base + c];

    // Try integer arithmetic first for add, sub, mul
    if (tag == .add or tag == .sub or tag == .mul) {
        if (vb.isInteger() and vc.isInteger()) {
            const ib = vb.integer;
            const ic = vc.integer;
            const res = switch (tag) {
                .add => ib + ic,
                .sub => ib - ic,
                .mul => ib * ic,
                else => unreachable,
            };
            vm.stack[vm.base + a] = .{ .integer = res };
            return;
        }
    }

    // Fall back to floating point
    const nb = vb.toNumber() orelse return error.ArithmeticError;
    const nc = vc.toNumber() orelse return error.ArithmeticError;

    // Check for division by zero
    if ((tag == .div or tag == .idiv or tag == .mod) and nc == 0) {
        return error.ArithmeticError;
    }

    const res = switch (tag) {
        .add => nb + nc,
        .sub => nb - nc,
        .mul => nb * nc,
        .div => nb / nc,
        .idiv => luaFloorDiv(nb, nc),
        .mod => luaMod(nb, nc),
        .pow => std.math.pow(f64, nb, nc),
    };

    vm.stack[vm.base + a] = .{ .number = res };
}

pub fn bitwiseBinary(vm: *VM, inst: Instruction, comptime tag: BitwiseOp) !void {
    const a = inst.getA();
    const b = inst.getB();
    const c = inst.getC();
    const vb = &vm.stack[vm.base + b];
    const vc = &vm.stack[vm.base + c];

    const ib = try toIntForBitwise(vb);
    const ic = try toIntForBitwise(vc);

    const res = switch (tag) {
        .band => ib & ic,
        .bor => ib | ic,
        .bxor => ib ^ ic,
    };

    vm.stack[vm.base + a] = .{ .integer = res };
}

fn toIntForBitwise(v: *const TValue) !i64 {
    if (v.isInteger()) {
        return v.integer;
    } else if (v.toNumber()) |n| {
        if (@floor(n) == n) {
            return @as(i64, @intFromFloat(n));
        }
    }
    return error.ArithmeticError;
}

// ============================================================================
// Comparison Operations
// ============================================================================

pub fn eqOp(a: TValue, b: TValue) bool {
    return a.eql(b);
}

pub fn ltOp(a: TValue, b: TValue) !bool {
    if (a.isInteger() and b.isInteger()) {
        return a.integer < b.integer;
    }
    const na = a.toNumber();
    const nb = b.toNumber();
    if (na != null and nb != null) {
        if (std.math.isNan(na.?) or std.math.isNan(nb.?)) {
            return false;
        }
        return na.? < nb.?;
    }
    return error.OrderComparisonError;
}

pub fn leOp(a: TValue, b: TValue) !bool {
    if (a.isInteger() and b.isInteger()) {
        return a.integer <= b.integer;
    }
    const na = a.toNumber();
    const nb = b.toNumber();
    if (na != null and nb != null) {
        if (std.math.isNan(na.?) or std.math.isNan(nb.?)) {
            return false;
        }
        return na.? <= nb.?;
    }
    return error.OrderComparisonError;
}

// ============================================================================
// Call Stack Management
// ============================================================================

pub fn pushCallInfo(vm: *VM, func: *const Proto, closure: ?*ClosureObject, base: u32, ret_base: u32, nresults: i16) !*CallInfo {
    return pushCallInfoVararg(vm, func, closure, base, ret_base, nresults, 0, 0);
}

pub fn pushCallInfoVararg(vm: *VM, func: *const Proto, closure: ?*ClosureObject, base: u32, ret_base: u32, nresults: i16, vararg_base: u32, vararg_count: u32) !*CallInfo {
    if (vm.callstack_size >= vm.callstack.len) {
        return error.CallStackOverflow;
    }

    const new_ci = &vm.callstack[vm.callstack_size];
    new_ci.* = CallInfo{
        .func = func,
        .closure = closure,
        .pc = func.code.ptr,
        .savedpc = null,
        .base = base,
        .ret_base = ret_base,
        .vararg_base = vararg_base,
        .vararg_count = vararg_count,
        .nresults = nresults,
        .previous = vm.ci,
    };

    vm.callstack_size += 1;
    vm.ci = new_ci;
    vm.base = base;

    return new_ci;
}

pub fn popCallInfo(vm: *VM) void {
    if (vm.ci) |ci| {
        if (ci.previous) |prev| {
            vm.ci = prev;
            vm.base = prev.base;
            if (vm.callstack_size > 0) {
                vm.callstack_size -= 1;
            }
        }
    }
}

// ============================================================================
// Metamethod Execution
// ============================================================================

/// Execute a metamethod synchronously and return its first result.
/// Used for comparison metamethods (__eq, __lt, __le) that need immediate results.
pub fn executeSyncMM(vm: *VM, closure: *ClosureObject, args: []const TValue) anyerror!TValue {
    const proto = closure.proto;
    const call_base = vm.top;
    const result_slot = call_base;

    // Set up arguments
    for (args, 0..) |arg, i| {
        vm.stack[call_base + i] = arg;
    }

    // Fill remaining params with nil
    var i: u32 = @intCast(args.len);
    while (i < proto.numparams) : (i += 1) {
        vm.stack[call_base + i] = .nil;
    }

    vm.top = call_base + proto.maxstacksize;

    // Save current call depth
    const saved_depth = vm.callstack_size;

    // Push call info for metamethod
    _ = try pushCallInfo(vm, proto, closure, call_base, result_slot, 1);

    // Execute until we return to saved depth
    while (vm.callstack_size > saved_depth) {
        const ci = &vm.callstack[vm.callstack_size - 1];
        const inst = ci.fetch() catch {
            vm.base = ci.ret_base;
            vm.top = ci.ret_base + 1;
            popCallInfo(vm);
            continue;
        };
        switch (try do(vm, inst)) {
            .Continue => {},
            .LoopContinue => {},
            .ReturnVM => break,
        }
    }

    return vm.stack[result_slot];
}

// ============================================================================
// Main Execution Loop
// ============================================================================

fn setupMainFrame(vm: *VM, proto: *const Proto) void {
    vm.base_ci = CallInfo{
        .func = proto,
        .closure = null,
        .pc = proto.code.ptr,
        .savedpc = null,
        .base = 0,
        .ret_base = 0,
        .nresults = -1,
        .previous = null,
    };
    vm.ci = &vm.base_ci;
    vm.base = 0;
    vm.top = proto.maxstacksize;
}

/// Find the nearest protected frame and handle the error.
/// Returns true if error was handled by a protected frame, false otherwise.
fn handleProtectedError(vm: *VM, err: anyerror) bool {
    var current = vm.ci;
    while (current) |ci| {
        if (ci.is_protected) {
            const ret_base = ci.ret_base;
            const close_base = ci.base;
            const target_ci = ci.previous;

            vm.closeUpvalues(close_base);

            while (vm.ci != null and vm.ci != target_ci) {
                popCallInfo(vm);
            }

            vm.stack[ret_base] = .{ .boolean = false };
            vm.stack[ret_base + 1] = .nil;
            vm.top = ret_base + 2;

            if (vm.lua_error_msg) |msg| {
                vm.stack[ret_base + 1] = TValue.fromString(msg);
                vm.lua_error_msg = null;
            } else {
                const err_str = vm.gc.allocString(@errorName(err)) catch {
                    return true;
                };
                vm.stack[ret_base + 1] = TValue.fromString(err_str);
            }

            return true;
        }
        current = ci.previous;
    }

    return false;
}

/// Main VM execution loop.
/// Executes instructions until RETURN from main chunk.
pub fn execute(vm: *VM, proto: *const Proto) !ReturnValue {
    vm.gc.setVM(vm);

    setupMainFrame(vm, proto);

    while (true) {
        const ci = vm.ci.?;
        const inst = ci.fetch() catch |err| {
            if (handleProtectedError(vm, err)) continue;
            return err;
        };

        const result = do(vm, inst) catch |err| {
            if (handleProtectedError(vm, err)) continue;
            return err;
        };

        switch (result) {
            .Continue => {},
            .LoopContinue => continue,
            .ReturnVM => |ret| return ret,
        }
    }
}

/// Execute a single instruction.
/// Called by VM's execute() loop after fetch.
pub inline fn do(vm: *VM, inst: Instruction) !ExecuteResult {
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
        // [MM_ARITH] Fast path: integer add with immediate. Slow path: __add metamethod.
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
            const vb = vm.stack[vm.base + b];

            if (vb.isInteger()) {
                const shift = @as(u8, sc);
                vm.stack[vm.base + a] = .{ .integer = std.math.shl(i64, vb.integer, @as(u6, @intCast(shift))) };
                return .Continue;
            } else if (vb.toNumber()) |n| {
                if (@floor(n) == n) {
                    const shift = @as(u8, sc);
                    vm.stack[vm.base + a] = .{ .integer = std.math.shl(i64, @intFromFloat(n), @as(u6, @intCast(shift))) };
                    return .Continue;
                }
            }
            // Try metamethod
            const shift_val = TValue{ .integer = @as(i64, sc) };
            if (try dispatchBitwiseMM(vm, vb, shift_val, a, .shl)) |result| return result;
            return error.ArithmeticError;
        },
        .SHRI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const vb = vm.stack[vm.base + b];

            if (vb.isInteger()) {
                const shift = @as(u8, sc);
                vm.stack[vm.base + a] = .{ .integer = std.math.shr(i64, vb.integer, @as(u6, @intCast(shift))) };
                return .Continue;
            } else if (vb.toNumber()) |n| {
                if (@floor(n) == n) {
                    const shift = @as(u8, sc);
                    vm.stack[vm.base + a] = .{ .integer = std.math.shr(i64, @intFromFloat(n), @as(u6, @intCast(shift))) };
                    return .Continue;
                }
            }
            // Try metamethod
            const shift_val = TValue{ .integer = @as(i64, sc) };
            if (try dispatchBitwiseMM(vm, vb, shift_val, a, .shr)) |result| return result;
            return error.ArithmeticError;
        },
        // [MM_ARITH] Fast path: add with constant. Slow path: __add metamethod.
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
        // [MM_ARITH] Fast path: subtract with constant. Slow path: __sub metamethod.
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
        // [MM_ARITH] Fast path: multiply with constant. Slow path: __mul metamethod.
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
        // [MM_ARITH] Fast path: divide with constant. Slow path: __div metamethod.
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
        // [MM_ARITH] Fast path: integer divide with constant. Slow path: __idiv metamethod.
        .IDIVK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            const nb = vb.toNumber() orelse return error.ArithmeticError;
            const nc = vc.toNumber() orelse return error.ArithmeticError;
            if (nc == 0) return error.ArithmeticError;
            vm.stack[vm.base + a] = .{ .number = luaFloorDiv(nb, nc) };
            return .Continue;
        },
        // [MM_ARITH] Fast path: modulo with constant. Slow path: __mod metamethod.
        .MODK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            const nb = vb.toNumber() orelse return error.ArithmeticError;
            const nc = vc.toNumber() orelse return error.ArithmeticError;
            if (nc == 0) return error.ArithmeticError;
            vm.stack[vm.base + a] = .{ .number = luaMod(nb, nc) };
            return .Continue;
        },
        // [MM_ARITH] Fast path: power with constant. Slow path: __pow metamethod.
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
            const vb = vm.stack[vm.base + b];
            const vc = ci.func.k[c];

            const toInt = struct {
                fn convert(v: TValue) ?i64 {
                    if (v.isInteger()) return v.integer;
                    if (v.toNumber()) |n| if (@floor(n) == n) return @intFromFloat(n);
                    return null;
                }
            }.convert;

            if (toInt(vb)) |ib| {
                if (toInt(vc)) |ic| {
                    vm.stack[vm.base + a] = .{ .integer = ib & ic };
                    return .Continue;
                }
            }
            if (try dispatchBitwiseMM(vm, vb, vc, a, .band)) |result| return result;
            return error.ArithmeticError;
        },
        .BORK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = vm.stack[vm.base + b];
            const vc = ci.func.k[c];

            const toInt = struct {
                fn convert(v: TValue) ?i64 {
                    if (v.isInteger()) return v.integer;
                    if (v.toNumber()) |n| if (@floor(n) == n) return @intFromFloat(n);
                    return null;
                }
            }.convert;

            if (toInt(vb)) |ib| {
                if (toInt(vc)) |ic| {
                    vm.stack[vm.base + a] = .{ .integer = ib | ic };
                    return .Continue;
                }
            }
            if (try dispatchBitwiseMM(vm, vb, vc, a, .bor)) |result| return result;
            return error.ArithmeticError;
        },
        .BXORK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = vm.stack[vm.base + b];
            const vc = ci.func.k[c];

            const toInt = struct {
                fn convert(v: TValue) ?i64 {
                    if (v.isInteger()) return v.integer;
                    if (v.toNumber()) |n| if (@floor(n) == n) return @intFromFloat(n);
                    return null;
                }
            }.convert;

            if (toInt(vb)) |ib| {
                if (toInt(vc)) |ic| {
                    vm.stack[vm.base + a] = .{ .integer = ib ^ ic };
                    return .Continue;
                }
            }
            if (try dispatchBitwiseMM(vm, vb, vc, a, .bxor)) |result| return result;
            return error.ArithmeticError;
        },
        // [MM_ARITH] Fast path: register add. Slow path: __add metamethod.
        .ADD => {
            return try dispatchArithMM(vm, inst, .add, .add);
        },
        // [MM_ARITH] Fast path: register subtract. Slow path: __sub metamethod.
        .SUB => {
            return try dispatchArithMM(vm, inst, .sub, .sub);
        },
        // [MM_ARITH] Fast path: register multiply. Slow path: __mul metamethod.
        .MUL => {
            return try dispatchArithMM(vm, inst, .mul, .mul);
        },
        // [MM_ARITH] Fast path: register divide. Slow path: __div metamethod.
        .DIV => {
            return try dispatchArithMM(vm, inst, .div, .div);
        },
        // [MM_ARITH] Fast path: register integer divide. Slow path: __idiv metamethod.
        .IDIV => {
            return try dispatchArithMM(vm, inst, .idiv, .idiv);
        },
        // [MM_ARITH] Fast path: register modulo. Slow path: __mod metamethod.
        .MOD => {
            return try dispatchArithMM(vm, inst, .mod, .mod);
        },
        // [MM_ARITH] Fast path: register power. Slow path: __pow metamethod.
        .POW => {
            return try dispatchArithMM(vm, inst, .pow, .pow);
        },
        .BAND => {
            bitwiseBinary(vm, inst, .band) catch {
                const a = inst.getA();
                const b = inst.getB();
                const c = inst.getC();
                if (try dispatchBitwiseMM(vm, vm.stack[vm.base + b], vm.stack[vm.base + c], a, .band)) |result| {
                    return result;
                }
                return error.ArithmeticError;
            };
            return .Continue;
        },
        .BOR => {
            bitwiseBinary(vm, inst, .bor) catch {
                const a = inst.getA();
                const b = inst.getB();
                const c = inst.getC();
                if (try dispatchBitwiseMM(vm, vm.stack[vm.base + b], vm.stack[vm.base + c], a, .bor)) |result| {
                    return result;
                }
                return error.ArithmeticError;
            };
            return .Continue;
        },
        .BXOR => {
            bitwiseBinary(vm, inst, .bxor) catch {
                const a = inst.getA();
                const b = inst.getB();
                const c = inst.getC();
                if (try dispatchBitwiseMM(vm, vm.stack[vm.base + b], vm.stack[vm.base + c], a, .bxor)) |result| {
                    return result;
                }
                return error.ArithmeticError;
            };
            return .Continue;
        },
        .SHL => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = vm.stack[vm.base + b];
            const vc = vm.stack[vm.base + c];

            const toInt = struct {
                fn convert(v: TValue) ?i64 {
                    if (v.isInteger()) {
                        return v.integer;
                    } else if (v.toNumber()) |n| {
                        if (@floor(n) == n) {
                            return @as(i64, @intFromFloat(n));
                        }
                    }
                    return null;
                }
            }.convert;

            if (toInt(vb)) |value| {
                if (toInt(vc)) |shift| {
                    const result = if (shift >= 0) blk: {
                        const s = std.math.cast(u6, shift) orelse 63;
                        break :blk std.math.shl(i64, value, s);
                    } else blk: {
                        const s = std.math.cast(u6, -shift) orelse 63;
                        break :blk std.math.shr(i64, value, s);
                    };
                    vm.stack[vm.base + a] = .{ .integer = result };
                    return .Continue;
                }
            }
            // Try metamethod
            if (try dispatchBitwiseMM(vm, vb, vc, a, .shl)) |result| {
                return result;
            }
            return error.ArithmeticError;
        },
        .SHR => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = vm.stack[vm.base + b];
            const vc = vm.stack[vm.base + c];

            const toInt = struct {
                fn convert(v: TValue) ?i64 {
                    if (v.isInteger()) {
                        return v.integer;
                    } else if (v.toNumber()) |n| {
                        if (@floor(n) == n) {
                            return @as(i64, @intFromFloat(n));
                        }
                    }
                    return null;
                }
            }.convert;

            if (toInt(vb)) |value| {
                if (toInt(vc)) |shift| {
                    const result = if (shift >= 0) blk: {
                        const s = std.math.cast(u6, shift) orelse 63;
                        break :blk std.math.shr(i64, value, s);
                    } else blk: {
                        const s = std.math.cast(u6, -shift) orelse 63;
                        break :blk std.math.shl(i64, value, s);
                    };
                    vm.stack[vm.base + a] = .{ .integer = result };
                    return .Continue;
                }
            }
            // Try metamethod
            if (try dispatchBitwiseMM(vm, vb, vc, a, .shr)) |result| {
                return result;
            }
            return error.ArithmeticError;
        },
        // [MM_ARITH] Fast path: unary minus. Slow path: __unm metamethod.
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
            const vb = vm.stack[vm.base + b];

            if (vb.isInteger()) {
                vm.stack[vm.base + a] = .{ .integer = ~vb.integer };
                return .Continue;
            } else if (vb.toNumber()) |n| {
                if (@floor(n) == n) {
                    const i = @as(i64, @intFromFloat(n));
                    vm.stack[vm.base + a] = .{ .integer = ~i };
                    return .Continue;
                }
            }
            // Try metamethod
            if (try dispatchBnotMM(vm, vb, a)) |result| {
                return result;
            }
            return error.ArithmeticError;
        },
        // [MM_LEN] Fast path: string/table length. Slow path: __len metamethod.
        .LEN => {
            const a = inst.getA();
            const b = inst.getB();
            const vb = &vm.stack[vm.base + b];

            if (vb.asString()) |str| {
                // Strings: direct byte length (no metamethod)
                vm.stack[vm.base + a] = .{ .integer = @as(i64, @intCast(str.asSlice().len)) };
            } else if (vb.asTable()) |table| {
                // Tables: try __len metamethod first
                if (try dispatchLenMM(vm, table, vb.*, a)) |result| {
                    return result;
                }
                // Default: count sequential integer keys from 1
                // Stop at first nil or missing key (Lua sequence semantics)
                var len: i64 = 0;
                var key_buffer: [32]u8 = undefined;
                while (true) {
                    const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{len + 1}) catch break;
                    const key = vm.gc.allocString(key_slice) catch break;
                    const val = table.get(key) orelse break;
                    if (val == .nil) break;
                    len += 1;
                }
                vm.stack[vm.base + a] = .{ .integer = len };
            } else {
                return error.LengthError;
            }
            return .Continue;
        },
        // [MM_CONCAT] Fast path: string/number concat. Slow path: __concat metamethod.
        .CONCAT => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();

            // Check if all values can be concatenated without metamethod
            var all_primitive = true;
            for (b..c + 1) |i| {
                if (!canConcatPrimitive(vm.stack[vm.base + i])) {
                    all_primitive = false;
                    break;
                }
            }

            // Fast path: all values are strings or numbers
            if (all_primitive) {
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
            }

            // Slow path: try __concat metamethod (binary operation)
            // For now, only handle the case of exactly 2 operands
            if (c == b + 1) {
                const left = vm.stack[vm.base + b];
                const right = vm.stack[vm.base + c];
                if (try dispatchConcatMM(vm, left, right, a)) |result| {
                    return result;
                }
            }

            return error.ArithmeticError;
        },
        // [MM_EQ] Fast path: primitive equality. Slow path: __eq metamethod.
        .EQ => {
            const negate = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const left = vm.stack[vm.base + b];
            const right = vm.stack[vm.base + c];

            // Fast path: neither is a table, no metamethod possible
            const is_true = if (left.asTable() == null and right.asTable() == null)
                eqOp(left, right)
            else
                try dispatchEqMM(vm, left, right) orelse eqOp(left, right);

            if ((is_true and negate == 0) or (!is_true and negate != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        // [MM_LT] Fast path: numeric less-than. Slow path: __lt metamethod.
        .LT => {
            const negate = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const left = vm.stack[vm.base + b];
            const right = vm.stack[vm.base + c];

            // Fast path: both are numbers
            const is_true = if ((left.isInteger() or left.isNumber()) and (right.isInteger() or right.isNumber()))
                try ltOp(left, right)
                // Fast path: both are strings - lexicographic comparison
            else if (left.asString() != null and right.asString() != null) blk: {
                const left_str = left.asString().?.asSlice();
                const right_str = right.asString().?.asSlice();
                break :blk std.mem.order(u8, left_str, right_str) == .lt;
            }
                // Slow path: try metamethod
                else try dispatchLtMM(vm, left, right) orelse return error.ArithmeticError;

            if ((is_true and negate == 0) or (!is_true and negate != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        // [MM_LE] Fast path: numeric less-or-equal. Slow path: __le metamethod.
        .LE => {
            const negate = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const left = vm.stack[vm.base + b];
            const right = vm.stack[vm.base + c];

            // Fast path: both are numbers
            const is_true = if ((left.isInteger() or left.isNumber()) and (right.isInteger() or right.isNumber()))
                try leOp(left, right)
                // Fast path: both are strings - lexicographic comparison
            else if (left.asString() != null and right.asString() != null) blk: {
                const left_str = left.asString().?.asSlice();
                const right_str = right.asString().?.asSlice();
                const order = std.mem.order(u8, left_str, right_str);
                break :blk order == .lt or order == .eq;
            }
                // Slow path: try metamethod
                else try dispatchLeMM(vm, left, right) orelse return error.ArithmeticError;

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
        // Generic for loop: TFORPREP A sBx - jump forward to TFORCALL/TFORLOOP
        .TFORPREP => {
            const sbx = inst.getSBx();
            try ci.jumpRel(sbx);
            return .Continue;
        },
        // Generic for loop: TFORCALL A C - call iterator R(A)(R(A+1), R(A+2)), store C results at R(A+3)...
        .TFORCALL => {
            const a = inst.getA();
            const c = inst.getC();

            const func_val = vm.stack[vm.base + a];
            const state_val = vm.stack[vm.base + a + 1];
            const control_val = vm.stack[vm.base + a + 2];

            // Set up call at R(A+3): copy function and args
            // Layout: R(A+3)=func, R(A+4)=state, R(A+5)=control, results go to R(A+3)...
            const call_reg: u8 = @intCast(a + 3);
            vm.stack[vm.base + call_reg] = func_val;
            vm.stack[vm.base + call_reg + 1] = state_val;
            vm.stack[vm.base + call_reg + 2] = control_val;

            const nresults: u32 = if (c > 0) c else 1;

            // Handle native closure
            if (func_val.isObject()) {
                const obj = func_val.object;
                if (obj.type == .native_closure) {
                    const nc = object.getObject(NativeClosureObject, obj);
                    const frame_max = vm.base + ci.func.maxstacksize;
                    vm.top = vm.base + call_reg + 3; // func + 2 args
                    try vm.callNative(nc.func.id, call_reg, 2, nresults);
                    // GC SAFETY: Clear stale slots and restore top
                    const result_end = vm.base + call_reg + nresults;
                    if (result_end < frame_max) {
                        for (vm.stack[result_end..frame_max]) |*slot| {
                            slot.* = .nil;
                        }
                    }
                    vm.top = frame_max;
                    return .Continue;
                }
            }

            // Handle Lua closure
            if (func_val.asClosure()) |closure| {
                const func_proto = closure.proto;
                const new_base = vm.base + call_reg;

                // Shift arguments: state and control move down
                vm.stack[new_base] = state_val;
                vm.stack[new_base + 1] = control_val;

                // Fill remaining params with nil if needed
                if (2 < func_proto.numparams) {
                    for (vm.stack[new_base + 2 ..][0 .. func_proto.numparams - 2]) |*slot| {
                        slot.* = .nil;
                    }
                }

                const nres: i16 = @intCast(nresults);
                _ = try pushCallInfo(vm, func_proto, closure, new_base, new_base, nres);
                vm.top = new_base + func_proto.maxstacksize;
                return .LoopContinue;
            }

            return error.NotAFunction;
        },
        // Generic for loop: TFORLOOP A sBx - if R(A+3) != nil, R(A+2) = R(A+3), jump back
        .TFORLOOP => {
            const a = inst.getA();
            const sbx = inst.getSBx();

            const first_var = vm.stack[vm.base + a + 3];

            if (!first_var.isNil()) {
                // Update control variable
                vm.stack[vm.base + a + 2] = first_var;
                // Jump back to loop body
                try ci.jumpRel(sbx);
            }
            // Otherwise fall through (loop ends)
            return .Continue;
        },
        // [MM_CALL] Fast path: closure/native call. Slow path: __call metamethod.
        .CALL => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();

            const func_val = vm.stack[vm.base + a];

            // Fast path: native closure
            if (func_val.isObject()) {
                const obj = func_val.object;
                if (obj.type == .native_closure) {
                    const nc = object.getObject(NativeClosureObject, obj);
                    const nargs: u32 = if (b > 0) b - 1 else blk: {
                        const arg_start = vm.base + a + 1;
                        break :blk vm.top - arg_start;
                    };
                    // When C=0 (variable returns), default to 1 for native functions
                    // since most natives return exactly 1 value
                    const nresults: u32 = if (c > 0) c - 1 else 1;
                    // Remember frame extent before call
                    const frame_max = vm.base + ci.func.maxstacksize;
                    // Ensure vm.top is past all arguments so native functions can use temp registers safely
                    vm.top = vm.base + a + 1 + nargs;
                    try vm.callNative(nc.func.id, a, nargs, nresults);
                    // GC SAFETY: Clear stack slots that may contain stale pointers.
                    // After call completes, slots from result_end to frame_max might have
                    // stale object pointers from previous operations. Clear them to nil
                    // so GC doesn't try to mark freed objects.
                    const result_end = vm.base + a + nresults;
                    if (result_end < frame_max) {
                        for (vm.stack[result_end..frame_max]) |*slot| {
                            slot.* = .nil;
                        }
                    }
                    vm.top = frame_max;
                    return .LoopContinue;
                }
            }

            // Fast path: Lua closure
            if (func_val.asClosure()) |closure| {
                const func_proto = closure.proto;

                const nargs: u32 = if (b > 0) b - 1 else blk: {
                    const arg_start = vm.base + a + 1;
                    break :blk vm.top - arg_start;
                };

                const nresults: i16 = if (c > 0) @as(i16, @intCast(c - 1)) else -1;

                const new_base = vm.base + a;
                const ret_base = vm.base + a;

                // Calculate vararg info before shifting arguments
                var vararg_base: u32 = 0;
                var vararg_count: u32 = 0;

                if (func_proto.is_vararg and nargs > func_proto.numparams) {
                    // Store varargs at the end of the new frame
                    vararg_count = nargs - func_proto.numparams;
                    vararg_base = new_base + func_proto.maxstacksize;

                    // Copy varargs to their storage location (after maxstacksize)
                    // Varargs are at positions: new_base + 1 + numparams .. new_base + 1 + nargs
                    // IMPORTANT: Copy backwards to handle overlapping regions (dest > src)
                    var i: u32 = vararg_count;
                    while (i > 0) {
                        i -= 1;
                        vm.stack[vararg_base + i] = vm.stack[new_base + 1 + func_proto.numparams + i];
                    }
                }

                // Shift arguments down by 1 slot (overwrite function value)
                // Note: regions overlap, so copy forward (src > dst)
                // Only copy fixed parameters, not varargs
                const params_to_copy = @min(nargs, @as(u32, func_proto.numparams));
                if (params_to_copy > 0) {
                    for (0..params_to_copy) |i| {
                        vm.stack[new_base + i] = vm.stack[new_base + 1 + i];
                    }
                }

                // Fill remaining parameter slots with nil
                if (nargs < func_proto.numparams) {
                    for (vm.stack[new_base + nargs ..][0 .. func_proto.numparams - nargs]) |*slot| {
                        slot.* = .nil;
                    }
                }

                _ = try pushCallInfoVararg(vm, func_proto, closure, new_base, ret_base, nresults, vararg_base, vararg_count);

                // Extend top to include vararg storage if needed
                const frame_top = new_base + func_proto.maxstacksize + vararg_count;
                vm.top = frame_top;
                return .LoopContinue;
            }

            // Slow path: try __call metamethod
            const nargs: u32 = if (b > 0) b - 1 else blk: {
                const arg_start = vm.base + a + 1;
                break :blk vm.top - arg_start;
            };
            const nresults: i16 = if (c > 0) @as(i16, @intCast(c - 1)) else -1;

            if (try dispatchCallMM(vm, func_val, a, nargs, nresults)) |result| {
                return result;
            }

            return error.NotAFunction;
        },
        .RETURN => {
            const a = inst.getA();
            const b = inst.getB();

            if (vm.ci.?.previous != null) {
                const returning_ci = vm.ci.?;
                const nresults = returning_ci.nresults;
                const dst_base = returning_ci.ret_base;
                const is_protected = returning_ci.is_protected;

                vm.closeUpvalues(returning_ci.base);
                popCallInfo(vm);

                // Calculate actual return count
                // B=0 means variable returns (from R[A] to top)
                // B>0 means B-1 fixed returns
                const ret_count: u32 = if (b == 0)
                    vm.top - (returning_ci.base + a)
                else if (b == 1)
                    0
                else
                    b - 1;

                // Protected frame: prepend true and shift results by 1
                if (is_protected) {
                    vm.stack[dst_base] = .{ .boolean = true };
                    if (ret_count == 0) {
                        // No return values from function
                        vm.top = dst_base + 1;
                    } else {
                        // Copy return values to dst_base + 1
                        for (0..ret_count) |i| {
                            vm.stack[dst_base + 1 + i] = vm.stack[returning_ci.base + a + i];
                        }
                        vm.top = dst_base + 1 + ret_count;
                    }
                    return .LoopContinue;
                }

                if (ret_count == 0) {
                    // No return values - fill expected slots with nil
                    if (nresults > 0) {
                        const n: usize = @intCast(nresults);
                        for (vm.stack[dst_base..][0..n]) |*slot| {
                            slot.* = .nil;
                        }
                    }
                } else if (nresults < 0) {
                    // Variable results - copy all return values
                    // Note: regions may overlap, copy forward (src >= dst)
                    for (0..ret_count) |i| {
                        vm.stack[dst_base + i] = vm.stack[returning_ci.base + a + i];
                    }
                    vm.top = dst_base + ret_count;
                } else {
                    // Fixed results - copy available values, fill rest with nil
                    const n: u32 = @intCast(nresults);
                    const copy_count = @min(ret_count, n);
                    for (0..copy_count) |i| {
                        vm.stack[dst_base + i] = vm.stack[returning_ci.base + a + i];
                    }
                    if (n > copy_count) {
                        for (vm.stack[dst_base + copy_count ..][0 .. n - copy_count]) |*slot| {
                            slot.* = .nil;
                        }
                    }
                    // Update vm.top to reflect actual stack usage after return
                    vm.top = dst_base + n;
                }

                return .LoopContinue;
            }

            // Top-level return (no previous call frame)
            const ret_count: u32 = if (b == 0)
                vm.top - (vm.base + a)
            else if (b == 1)
                0
            else
                b - 1;

            if (ret_count == 0) {
                return .{ .ReturnVM = .none };
            } else if (ret_count == 1) {
                return .{ .ReturnVM = .{ .single = vm.stack[vm.base + a] } };
            } else {
                const values = vm.stack[vm.base + a .. vm.base + a + ret_count];
                return .{ .ReturnVM = .{ .multiple = values } };
            }
        },
        .RETURN0 => {
            if (vm.ci.?.previous != null) {
                const returning_ci = vm.ci.?;
                const nresults = returning_ci.nresults;
                const dst_base = returning_ci.ret_base;
                const is_protected = returning_ci.is_protected;

                vm.closeUpvalues(returning_ci.base);
                popCallInfo(vm);

                // Protected frame: return (true) with no additional values
                if (is_protected) {
                    vm.stack[dst_base] = .{ .boolean = true };
                    vm.top = dst_base + 1;
                    return .LoopContinue;
                }

                // Fill expected result slots with nil
                if (nresults > 0) {
                    const n: usize = @intCast(nresults);
                    for (vm.stack[dst_base..][0..n]) |*slot| {
                        slot.* = .nil;
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
                const is_protected = returning_ci.is_protected;

                vm.closeUpvalues(returning_ci.base);
                popCallInfo(vm);

                // Protected frame: return (true, value)
                if (is_protected) {
                    vm.stack[dst_base] = .{ .boolean = true };
                    vm.stack[dst_base + 1] = vm.stack[returning_ci.base + a];
                    vm.top = dst_base + 2;
                    return .LoopContinue;
                }

                if (nresults < 0) {
                    vm.stack[dst_base] = vm.stack[returning_ci.base + a];
                    vm.top = dst_base + 1;
                } else if (nresults > 0) {
                    // Copy single return value, fill rest with nil
                    vm.stack[dst_base] = vm.stack[returning_ci.base + a];
                    if (nresults > 1) {
                        const n: usize = @intCast(nresults - 1);
                        for (vm.stack[dst_base + 1 ..][0..n]) |*slot| {
                            slot.* = .nil;
                        }
                    }
                }

                return .LoopContinue;
            }

            return .{ .ReturnVM = .{ .single = vm.stack[vm.base + a] } };
        },
        // [MM_INDEX] Fast path: upvalue table read. Slow path: __index metamethod.
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
        // [MM_NEWINDEX] Fast path: upvalue table write. Slow path: __newindex metamethod.
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
        // [MM_INDEX] Fast path: table read by key. Slow path: __index metamethod.
        .GETTABLE => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const table_val = vm.stack[vm.base + b];
            const key_val = vm.stack[vm.base + c];

            if (table_val.asTable()) |table| {
                if (key_val.asString()) |key| {
                    if (try dispatchIndexMM(vm, table, key, table_val, a)) |result| {
                        return result;
                    }
                } else if (key_val.isInteger()) {
                    var key_buffer: [32]u8 = undefined;
                    const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{key_val.integer}) catch {
                        return error.InvalidTableKey;
                    };
                    const key = try vm.gc.allocString(key_slice);
                    if (try dispatchIndexMM(vm, table, key, table_val, a)) |result| {
                        return result;
                    }
                } else {
                    return error.InvalidTableOperation;
                }
            } else {
                return error.InvalidTableOperation;
            }
            return .Continue;
        },
        // [MM_NEWINDEX] Fast path: table write by key. Slow path: __newindex metamethod.
        .SETTABLE => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const table_val = vm.stack[vm.base + a];
            const key_val = vm.stack[vm.base + b];
            const value = vm.stack[vm.base + c];

            if (table_val.asTable()) |table| {
                if (key_val.asString()) |key| {
                    if (try dispatchNewindexMM(vm, table, key, table_val, value)) |result| {
                        return result;
                    }
                } else if (key_val.isInteger()) {
                    var key_buffer: [32]u8 = undefined;
                    const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{key_val.integer}) catch {
                        return error.InvalidTableOperation;
                    };
                    const key = try vm.gc.allocString(key_slice);
                    if (try dispatchNewindexMM(vm, table, key, table_val, value)) |result| {
                        return result;
                    }
                } else {
                    return error.InvalidTableOperation;
                }
            } else {
                return error.InvalidTableOperation;
            }
            return .Continue;
        },
        // [MM_INDEX] Fast path: table read by integer index. Slow path: __index metamethod.
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
                if (try dispatchIndexMM(vm, table, key, table_val, a)) |result| {
                    return result;
                }
            } else {
                return error.InvalidTableOperation;
            }
            return .Continue;
        },
        // [MM_NEWINDEX] Fast path: table write by integer index. Slow path: __newindex metamethod.
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
                if (try dispatchNewindexMM(vm, table, key, table_val, value)) |result| {
                    return result;
                }
            } else {
                return error.InvalidTableOperation;
            }
            return .Continue;
        },
        // [MM_INDEX] Fast path: table read by field. Slow path: __index metamethod.
        .GETFIELD => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const table_val = vm.stack[vm.base + b];
            const key_val = ci.func.k[c];

            if (table_val.asTable()) |table| {
                if (key_val.asString()) |key| {
                    if (try dispatchIndexMM(vm, table, key, table_val, a)) |result| {
                        return result;
                    }
                } else {
                    return error.InvalidTableOperation;
                }
            } else {
                return error.InvalidTableOperation;
            }
            return .Continue;
        },
        // [MM_NEWINDEX] Fast path: table write by field. Slow path: __newindex metamethod.
        .SETFIELD => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const table_val = vm.stack[vm.base + a];
            const key_val = ci.func.k[b];
            const value = vm.stack[vm.base + c];

            if (table_val.asTable()) |table| {
                if (key_val.asString()) |key| {
                    if (try dispatchNewindexMM(vm, table, key, table_val, value)) |result| {
                        return result;
                    }
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
        // [MM_EQ] Fast path: equality with constant. Slow path: __eq metamethod.
        .EQK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const left = vm.stack[vm.base + b];
            const right = ci.func.k[c];

            // Fast path: left is not a table (constant right can't be a table)
            const is_true = if (left.asTable() == null)
                eqOp(left, right)
            else
                try dispatchEqMM(vm, left, right) orelse eqOp(left, right);

            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        // [MM_EQ] Fast path: equality with immediate. Slow path: __eq metamethod.
        .EQI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const imm = @as(i8, @bitCast(@as(u8, sc)));
            const left = vm.stack[vm.base + b];
            const right = TValue{ .integer = @as(i64, imm) };

            // Fast path: left is not a table (immediate right is always integer)
            const is_true = if (left.asTable() == null)
                eqOp(left, right)
            else
                try dispatchEqMM(vm, left, right) orelse eqOp(left, right);

            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        // [MM_LT] Fast path: less-than with immediate. Slow path: __lt metamethod.
        .LTI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const imm = @as(i8, @bitCast(@as(u8, sc)));
            const left = vm.stack[vm.base + b];
            const right = TValue{ .integer = @as(i64, imm) };

            // Fast path: left is a number
            const is_true = if (left.isInteger() or left.isNumber())
                try ltOp(left, right)
            else
                try dispatchLtMM(vm, left, right) orelse return error.ArithmeticError;

            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        // [MM_LE] Fast path: less-or-equal with immediate. Slow path: __le metamethod.
        .LEI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const imm = @as(i8, @bitCast(@as(u8, sc)));
            const left = vm.stack[vm.base + b];
            const right = TValue{ .integer = @as(i64, imm) };

            // Fast path: left is a number
            const is_true = if (left.isInteger() or left.isNumber())
                try leOp(left, right)
            else
                try dispatchLeMM(vm, left, right) orelse return error.ArithmeticError;

            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        // [MM_LT] Fast path: greater-than with immediate. Slow path: __lt metamethod (reversed).
        .GTI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const imm = @as(i8, @bitCast(@as(u8, sc)));
            const left = TValue{ .integer = @as(i64, imm) };
            const right = vm.stack[vm.base + b];

            // Fast path: right is a number (GTI is imm < R[B])
            const is_true = if (right.isInteger() or right.isNumber())
                try ltOp(left, right)
            else
                try dispatchLtMM(vm, left, right) orelse return error.ArithmeticError;

            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        // [MM_LE] Fast path: greater-or-equal with immediate. Slow path: __le metamethod (reversed).
        .GEI => {
            const a = inst.getA();
            const b = inst.getB();
            const sc = inst.getC();
            const imm = @as(i8, @bitCast(@as(u8, sc)));
            const left = TValue{ .integer = @as(i64, imm) };
            const right = vm.stack[vm.base + b];

            // Fast path: right is a number (GEI is imm <= R[B])
            const is_true = if (right.isInteger() or right.isNumber())
                try leOp(left, right)
            else
                try dispatchLeMM(vm, left, right) orelse return error.ArithmeticError;

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
        .SETLIST => {
            // SETLIST A B C k: R[A][(C-1)*FPF+i] := R[A+i], 1 <= i <= B
            // FPF (Fields Per Flush) = 50 in Lua 5.4
            // Special case: when k=1 and C=0, EXTRAARG contains direct start index
            const FIELDS_PER_FLUSH: u32 = 50;

            const a = inst.getA();
            const b = inst.getB();
            const c_raw = inst.getC();
            const k = inst.getk();

            // Calculate starting index
            const start_index: i64 = if (k) blk: {
                const extraarg_inst = try ci.fetchExtraArg();
                const ax = extraarg_inst.getAx();
                if (c_raw == 0) {
                    // Direct index mode: EXTRAARG is the start index
                    break :blk @as(i64, ax);
                } else {
                    // Large batch mode: EXTRAARG is the batch number
                    break :blk @as(i64, (ax - 1) * FIELDS_PER_FLUSH) + 1;
                }
            } else @as(i64, (c_raw - 1) * FIELDS_PER_FLUSH) + 1;

            // Get table from R[A]
            const table_val = vm.stack[vm.base + a];
            const table = table_val.asTable() orelse return error.InvalidTableOperation;

            // Calculate number of values to set
            // B=0 means use top - (base + a + 1) values
            const n: u32 = if (b > 0) b else vm.top - (vm.base + a + 1);

            // Set values R[A+1], R[A+2], ..., R[A+n] into table
            var key_buffer: [32]u8 = undefined;
            for (0..n) |i| {
                const value = vm.stack[vm.base + a + 1 + @as(u32, @intCast(i))];
                const index: i64 = start_index + @as(i64, @intCast(i));

                // Convert integer index to string key
                const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{index}) catch {
                    return error.InvalidTableOperation;
                };
                const key = try vm.gc.allocString(key_slice);

                // Use dispatchNewindexMM to handle potential metamethods
                if (try dispatchNewindexMM(vm, table, key, table_val, value)) |result| {
                    return result;
                }
            }

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
        // Metamethod dispatch opcodes
        // These are emitted after arithmetic operations for metamethod fallback
        .MMBIN => {
            // MMBIN A B C: metamethod for binary operation R[B] op R[C]
            // A encodes the metamethod event (add, sub, mul, etc.)
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();

            const vb = vm.stack[vm.base + b];
            const vc = vm.stack[vm.base + c];

            // Decode metamethod event from A
            const event = mmEventFromOpcode(a) orelse return error.UnknownOpcode;

            // Try to get metamethod from either operand
            const mm = try metamethod.getBinMetamethod(vb, vc, event, &vm.gc) orelse {
                // No metamethod found - arithmetic error
                return error.ArithmeticError;
            };

            // Call the metamethod: mm(vb, vc) -> result at b
            // Set up call: function at temp, args at temp+1, temp+2
            const temp = vm.top;
            vm.stack[temp] = mm;
            vm.stack[temp + 1] = vb;
            vm.stack[temp + 2] = vc;
            vm.top = temp + 3;

            // If metamethod is a closure, push call frame
            if (mm.asClosure()) |closure| {
                _ = try pushCallInfo(vm, closure.proto, closure, temp, @intCast(vm.base + b), 1);
                return .LoopContinue;
            }

            // For native closures, call directly
            if (mm.isObject() and mm.object.type == .native_closure) {
                const nc = object.getObject(NativeClosureObject, mm.object);
                try vm.callNative(nc.func.id, @intCast(temp - vm.base), 2, 1);
                // Result is at temp, move to b
                vm.stack[vm.base + b] = vm.stack[temp];
                vm.top = temp;
                return .Continue;
            }

            return error.NotAFunction;
        },
        .MMBINI => {
            // MMBINI A sB C k: metamethod for binary op with immediate
            // TODO: Implement immediate metamethod dispatch
            return error.UnknownOpcode;
        },
        .MMBINK => {
            // MMBINK A B C k: metamethod for binary op with constant
            // TODO: Implement constant metamethod dispatch
            return error.UnknownOpcode;
        },
        .VARARG => {
            // VARARG A C: Load varargs into R[A], R[A+1], ..., R[A+C-2]
            // If C=0, load all varargs and set top
            const a = inst.getA();
            const c = inst.getC();

            const vararg_base = ci.vararg_base;
            const vararg_count = ci.vararg_count;

            if (c == 0) {
                // Load all varargs, set top accordingly
                for (0..vararg_count) |i| {
                    vm.stack[vm.base + a + i] = vm.stack[vararg_base + i];
                }
                vm.top = vm.base + a + vararg_count;
            } else {
                // Load exactly c-1 values
                const want: u32 = c - 1;
                for (0..want) |i| {
                    if (i < vararg_count) {
                        vm.stack[vm.base + a + i] = vm.stack[vararg_base + i];
                    } else {
                        // Fill with nil if not enough varargs
                        vm.stack[vm.base + a + i] = .nil;
                    }
                }
            }
            return .Continue;
        },
        .VARARGPREP => {
            // VARARGPREP A: Prepare vararg function with A fixed parameters
            // In our implementation, CALL already handles vararg setup,
            // so this is mostly a no-op for verification
            const a = inst.getA();
            _ = a; // numparams - could verify ci.func.numparams == a
            return .Continue;
        },
        .EXTRAARG => {
            return error.UnknownOpcode;
        },

        // --- Extended opcodes ---
        // Protected call: catches runtime errors and returns (true, results...) or (false, error)
        .PCALL => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();

            const func_val = vm.stack[vm.base + a + 1];
            const nargs: u32 = if (b > 0) b - 1 else blk: {
                const arg_start = vm.base + a + 2;
                break :blk vm.top - arg_start;
            };
            const nresults: u32 = if (c > 0) c - 1 else 1;

            // Handle native closure
            if (func_val.isObject()) {
                const obj = func_val.object;
                if (obj.type == .native_closure) {
                    const nc = object.getObject(NativeClosureObject, obj);
                    const frame_max = vm.base + ci.func.maxstacksize;

                    // Set up call at temporary position
                    const call_reg: u32 = a + 1;
                    vm.top = vm.base + call_reg + 1 + nargs;

                    // Execute with error catching
                    const result_count: u32 = if (vm.callNative(nc.func.id, @intCast(call_reg), nargs, nresults)) blk: {
                        // Success: move results and prepend true
                        var i: u32 = nresults;
                        while (i > 0) : (i -= 1) {
                            vm.stack[vm.base + a + i] = vm.stack[vm.base + call_reg + i - 1];
                        }
                        vm.stack[vm.base + a] = .{ .boolean = true };
                        break :blk nresults + 1; // true + results
                    } else |_| blk: {
                        // Failure: set false and error message
                        vm.stack[vm.base + a] = .{ .boolean = false };
                        vm.stack[vm.base + a + 1] = .nil; // Safe placeholder

                        // Now safe to access stored message or allocate
                        if (vm.lua_error_msg) |msg| {
                            vm.stack[vm.base + a + 1] = TValue.fromString(msg);
                            vm.lua_error_msg = null;
                        } else {
                            const err_str = try vm.gc.allocString("error");
                            vm.stack[vm.base + a + 1] = TValue.fromString(err_str);
                        }
                        break :blk 2; // false + error message
                    };
                    // GC SAFETY: Clear stale slots and restore top
                    const result_end = vm.base + a + result_count;
                    if (result_end < frame_max) {
                        for (vm.stack[result_end..frame_max]) |*slot| {
                            slot.* = .nil;
                        }
                    }
                    vm.top = frame_max;
                    return .Continue;
                }
            }

            // Handle Lua closure with protected execution
            if (func_val.asClosure()) |closure| {
                const func_proto = closure.proto;
                const call_base = vm.base + a + 1;

                // Shift arguments (overwrite function)
                if (nargs > 0) {
                    for (0..nargs) |i| {
                        vm.stack[call_base + i] = vm.stack[call_base + 1 + i];
                    }
                }

                // Fill remaining params with nil
                if (nargs < func_proto.numparams) {
                    for (vm.stack[call_base + nargs ..][0 .. func_proto.numparams - nargs]) |*slot| {
                        slot.* = .nil;
                    }
                }

                // Push a protected call frame
                const pcall_nresults: i16 = @intCast(nresults);
                const new_ci = try pushCallInfo(vm, func_proto, closure, call_base, vm.base + a, pcall_nresults);
                new_ci.is_protected = true;

                vm.top = call_base + func_proto.maxstacksize;
                return .LoopContinue;
            }

            // Not a function - return error
            vm.stack[vm.base + a] = .{ .boolean = false };
            const err_str = try vm.gc.allocString("attempt to call a non-function value");
            vm.stack[vm.base + a + 1] = TValue.fromString(err_str);
            return .Continue;
        },

        else => return error.UnknownOpcode,
    }
}

/// Map instruction A field to MetaEvent for MMBIN
fn mmEventFromOpcode(a: u8) ?MetaEvent {
    return switch (a) {
        6 => .add,
        7 => .sub,
        8 => .mul,
        9 => .mod,
        10 => .pow,
        11 => .div,
        12 => .idiv,
        13 => .band,
        14 => .bor,
        15 => .bxor,
        16 => .shl,
        17 => .shr,
        20 => .concat,
        else => null,
    };
}

/// Arithmetic with metamethod fallback
/// Tries fast path first, then checks for metamethod
fn dispatchArithMM(vm: *VM, inst: Instruction, comptime arith_op: ArithOp, comptime event: MetaEvent) !ExecuteResult {
    const a = inst.getA();
    const b = inst.getB();
    const c = inst.getC();
    const vb = vm.stack[vm.base + b];
    const vc = vm.stack[vm.base + c];

    // Try fast path (numeric arithmetic)
    if (canDoArith(vb, vc)) {
        try arithBinary(vm, inst, arith_op);
        return .Continue;
    }

    // Try metamethod
    const mm = try metamethod.getBinMetamethod(vb, vc, event, &vm.gc) orelse {
        return error.ArithmeticError;
    };

    // Call the metamethod
    return try callBinMetamethod(vm, mm, vb, vc, a);
}

/// Check if both values can be used for arithmetic (fast path)
fn canDoArith(a: TValue, b: TValue) bool {
    return (a.isInteger() or a.isNumber()) and (b.isInteger() or b.isNumber());
}

/// Call a binary metamethod and store result
fn callBinMetamethod(vm: *VM, mm: TValue, arg1: TValue, arg2: TValue, result_reg: u8) !ExecuteResult {
    // Set up call: like CALL instruction
    // func at temp, args at temp+1, temp+2
    // But for call frame, we copy args to start at new_base
    const temp = vm.top;

    // If metamethod is a closure, push call frame
    if (mm.asClosure()) |closure| {
        const proto = closure.proto;
        const new_base = temp;

        // Set up parameters at new_base (like CALL does)
        vm.stack[new_base] = arg1; // First parameter at R[0]
        vm.stack[new_base + 1] = arg2; // Second parameter at R[1]

        // Fill remaining parameters with nil if needed
        var i: u32 = 2;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        vm.top = new_base + proto.maxstacksize;

        _ = try pushCallInfo(vm, proto, closure, new_base, @intCast(vm.base + result_reg), 1);
        return .LoopContinue;
    }

    // For native closures, call directly
    if (mm.isObject() and mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, mm.object);
        // Set up: function at temp, args at temp+1, temp+2
        vm.stack[temp] = mm;
        vm.stack[temp + 1] = arg1;
        vm.stack[temp + 2] = arg2;
        vm.top = temp + 3;

        try vm.callNative(nc.func.id, @intCast(temp - vm.base), 2, 1);
        // Result is at temp, move to result_reg
        vm.stack[vm.base + result_reg] = vm.stack[temp];
        vm.top = temp;
        return .Continue;
    }

    return error.NotAFunction;
}

/// Index with __index metamethod fallback
/// Returns the value if found, or calls __index if not found
/// If __index is a table, recursively looks up the key
/// If __index is a function, calls it with (table, key)
fn dispatchIndexMM(vm: *VM, table: *object.TableObject, key: *object.StringObject, table_val: TValue, result_reg: u8) !?ExecuteResult {
    // Fast path: key exists in table
    if (table.get(key)) |value| {
        vm.stack[vm.base + result_reg] = value;
        return null; // Continue
    }

    // Check for __index metamethod
    const mt = table.metatable orelse {
        vm.stack[vm.base + result_reg] = .nil;
        return null; // Continue
    };

    const index_mm = mt.get(vm.mm_keys.index) orelse {
        vm.stack[vm.base + result_reg] = .nil;
        return null; // Continue
    };

    // __index is a table: recursively look up
    if (index_mm.asTable()) |index_table| {
        if (index_table.get(key)) |value| {
            vm.stack[vm.base + result_reg] = value;
        } else {
            // Recursive __index lookup on the index table
            return try dispatchIndexMM(vm, index_table, key, index_mm, result_reg);
        }
        return null; // Continue
    }

    // __index is a function: call it with (table, key)
    if (index_mm.asClosure()) |closure| {
        const proto = closure.proto;
        const new_base = vm.top;

        // Set up parameters: table, key
        vm.stack[new_base] = table_val;
        vm.stack[new_base + 1] = TValue.fromString(key);

        // Fill remaining parameters with nil if needed
        var i: u32 = 2;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        vm.top = new_base + proto.maxstacksize;

        _ = try pushCallInfo(vm, proto, closure, new_base, @intCast(vm.base + result_reg), 1);
        return .LoopContinue;
    }

    // __index is a native function
    if (index_mm.isObject() and index_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, index_mm.object);
        const temp = vm.top;

        vm.stack[temp] = index_mm;
        vm.stack[temp + 1] = table_val;
        vm.stack[temp + 2] = TValue.fromString(key);
        vm.top = temp + 3;

        try vm.callNative(nc.func.id, @intCast(temp - vm.base), 2, 1);
        vm.stack[vm.base + result_reg] = vm.stack[temp];
        vm.top = temp;
        return null; // Continue
    }

    // __index is not a valid type
    vm.stack[vm.base + result_reg] = .nil;
    return null;
}

/// Newindex with __newindex metamethod fallback
/// If key doesn't exist and __newindex is set, dispatch to metamethod
/// If __newindex is a table, set the key in that table
/// If __newindex is a function, call it with (table, key, value)
fn dispatchNewindexMM(vm: *VM, table: *object.TableObject, key: *object.StringObject, table_val: TValue, value: TValue) !?ExecuteResult {
    // Fast path: key already exists in table - just update it
    if (table.get(key) != null) {
        try table.set(key, value);
        return null; // Continue
    }

    // Check for __newindex metamethod
    const mt = table.metatable orelse {
        // No metatable, just set the value
        try table.set(key, value);
        return null; // Continue
    };

    const newindex_mm = mt.get(vm.mm_keys.newindex) orelse {
        // No __newindex, just set the value
        try table.set(key, value);
        return null; // Continue
    };

    // __newindex is a table: set in that table instead
    if (newindex_mm.asTable()) |newindex_table| {
        // Recursive __newindex dispatch
        return try dispatchNewindexMM(vm, newindex_table, key, newindex_mm, value);
    }

    // __newindex is a function: call it with (table, key, value)
    if (newindex_mm.asClosure()) |closure| {
        const proto = closure.proto;
        const new_base = vm.top;

        // Set up parameters: table, key, value
        vm.stack[new_base] = table_val;
        vm.stack[new_base + 1] = TValue.fromString(key);
        vm.stack[new_base + 2] = value;

        // Fill remaining parameters with nil if needed
        var i: u32 = 3;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        vm.top = new_base + proto.maxstacksize;

        // __newindex doesn't return a value, but we still need to call it
        _ = try pushCallInfo(vm, proto, closure, new_base, new_base, 0);
        return .LoopContinue;
    }

    // __newindex is a native function
    if (newindex_mm.isObject() and newindex_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, newindex_mm.object);
        const temp = vm.top;

        vm.stack[temp] = newindex_mm;
        vm.stack[temp + 1] = table_val;
        vm.stack[temp + 2] = TValue.fromString(key);
        vm.stack[temp + 3] = value;
        vm.top = temp + 4;

        try vm.callNative(nc.func.id, @intCast(temp - vm.base), 3, 0);
        vm.top = temp;
        return null; // Continue
    }

    // __newindex is not a valid type, just set normally
    try table.set(key, value);
    return null;
}

/// Call metamethod dispatch for non-callable values
/// If obj has __call metamethod, call it with (obj, args...)
/// Returns null if no __call found (caller should return error)
fn dispatchCallMM(vm: *VM, obj_val: TValue, func_slot: u32, nargs: u32, nresults: i16) !?ExecuteResult {
    // Only tables can have metatables (for now)
    const table = obj_val.asTable() orelse return null;

    const mt = table.metatable orelse return null;

    const call_mm = mt.get(vm.mm_keys.call) orelse return null;

    // __call must be a function
    if (call_mm.asClosure()) |closure| {
        const proto = closure.proto;
        const new_base = vm.base + func_slot;

        // Stack is already laid out correctly for __call:
        // [new_base] = obj (becomes self)
        // [new_base+1..] = original args
        // No shifting needed - obj is already at func_slot

        // Total args for __call is nargs + 1 (the object)
        const total_args = nargs + 1;

        // Fill remaining parameters with nil if needed
        var i: u32 = total_args;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        vm.top = new_base + proto.maxstacksize;

        _ = try pushCallInfo(vm, proto, closure, new_base, new_base, nresults);
        return .LoopContinue;
    }

    // __call is a native closure
    if (call_mm.isObject() and call_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, call_mm.object);
        const base_slot = func_slot;

        // Stack is already correct: obj at base_slot, args at base_slot+1...
        // Call native with nargs+1 (obj counts as first arg)
        const actual_nresults: u32 = if (nresults >= 0) @intCast(nresults) else 0;
        try vm.callNative(nc.func.id, base_slot, nargs + 1, actual_nresults);
        return .LoopContinue;
    }

    return null;
}

/// Len with __len metamethod fallback
/// If table has __len metamethod, call it and return the result
/// Returns null if no __len found (caller should use default length)
fn dispatchLenMM(vm: *VM, table: *object.TableObject, table_val: TValue, result_reg: u8) !?ExecuteResult {
    const mt = table.metatable orelse return null;

    const len_mm = mt.get(vm.mm_keys.len) orelse return null;

    // __len is a Lua function
    if (len_mm.asClosure()) |closure| {
        const proto = closure.proto;
        const new_base = vm.top;

        // Set up call: __len(table)
        vm.stack[new_base] = table_val;

        // Fill remaining params with nil
        var i: u32 = 1;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        vm.top = new_base + proto.maxstacksize;

        // Push call info, result goes to result_reg
        _ = try pushCallInfo(vm, proto, closure, new_base, vm.base + result_reg, 1);
        return .LoopContinue;
    }

    // __len is a native function
    if (len_mm.isObject() and len_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, len_mm.object);
        const call_base = vm.top - vm.base;

        // Set up call: __len(table)
        vm.stack[vm.top] = table_val;
        vm.top += 1;

        try vm.callNative(nc.func.id, @intCast(call_base), 1, 1);

        // Copy result to destination register
        vm.stack[vm.base + result_reg] = vm.stack[vm.base + call_base];
        return .Continue;
    }

    return null;
}

/// Check if value can be concatenated without metamethod (string or number)
fn canConcatPrimitive(val: TValue) bool {
    return val.asString() != null or val.isInteger() or val.isNumber();
}

/// Try to get __concat metamethod from a value
fn getConcatMM(vm: *VM, val: TValue) ?TValue {
    const table = val.asTable() orelse return null;
    const mt = table.metatable orelse return null;
    return mt.get(vm.mm_keys.concat);
}

/// Concat with __concat metamethod fallback
/// Tries left operand first, then right operand for metamethod
/// Returns null if neither has __concat (caller should handle error)
fn dispatchConcatMM(vm: *VM, left: TValue, right: TValue, result_reg: u8) !?ExecuteResult {
    // Try left operand's __concat first, then right
    const concat_mm = getConcatMM(vm, left) orelse getConcatMM(vm, right) orelse return null;

    // __concat is a Lua function
    if (concat_mm.asClosure()) |closure| {
        const proto = closure.proto;
        const new_base = vm.top;

        // Set up call: __concat(left, right)
        vm.stack[new_base] = left;
        vm.stack[new_base + 1] = right;

        // Fill remaining params with nil
        var i: u32 = 2;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        vm.top = new_base + proto.maxstacksize;

        // Push call info, result goes to result_reg
        _ = try pushCallInfo(vm, proto, closure, new_base, vm.base + result_reg, 1);
        return .LoopContinue;
    }

    // __concat is a native function
    if (concat_mm.isObject() and concat_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, concat_mm.object);
        const call_base = vm.top - vm.base;

        // Set up call: __concat(left, right)
        vm.stack[vm.top] = left;
        vm.stack[vm.top + 1] = right;
        vm.top += 2;

        try vm.callNative(nc.func.id, @intCast(call_base), 2, 1);

        // Copy result to destination register
        vm.stack[vm.base + result_reg] = vm.stack[vm.base + call_base];
        return .Continue;
    }

    return null;
}

/// Try to get __eq metamethod from a table
fn getEqMM(vm: *VM, val: TValue) ?TValue {
    const table = val.asTable() orelse return null;
    const mt = table.metatable orelse return null;
    return mt.get(vm.mm_keys.eq);
}

/// Equality with __eq metamethod fallback
/// Returns true/false if comparison can be done, null if metamethod not found
/// Note: Only supports native metamethods for now (Lua functions require async handling)
fn dispatchEqMM(vm: *VM, left: TValue, right: TValue) !?bool {
    // Primitive equality check first - if equal, no metamethod needed
    if (eqOp(left, right)) {
        return true;
    }

    // __eq is only called for tables (or userdata) of the same type
    const left_table = left.asTable() orelse return null;
    const right_table = right.asTable() orelse return null;

    // In Lua 5.4, __eq requires both operands have the same metamethod
    const left_mm = getEqMM(vm, left) orelse return null;
    const right_mm = getEqMM(vm, right);

    // Check if they have the same __eq (by identity)
    if (right_mm) |rmm| {
        // For simplicity, just check if left has __eq and use it
        _ = rmm;
    }

    // __eq is a native function - call synchronously
    if (left_mm.isObject() and left_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, left_mm.object);
        const call_base = vm.top - vm.base;

        // Set up call: __eq(left, right)
        vm.stack[vm.top] = TValue.fromTable(left_table);
        vm.stack[vm.top + 1] = TValue.fromTable(right_table);
        vm.top += 2;

        try vm.callNative(nc.func.id, @intCast(call_base), 2, 1);

        // Get result and convert to boolean
        const result = vm.stack[vm.base + call_base];
        return result.toBoolean();
    }

    // __eq is a Lua function - call synchronously using VM's executeSync
    if (left_mm.asClosure()) |closure| {
        const result = try executeSyncMM(vm, closure, &[_]TValue{
            TValue.fromTable(left_table),
            TValue.fromTable(right_table),
        });
        return result.toBoolean();
    }

    return null;
}

/// Try to get __lt metamethod from a table
fn getLtMM(vm: *VM, val: TValue) ?TValue {
    const table = val.asTable() orelse return null;
    const mt = table.metatable orelse return null;
    return mt.get(vm.mm_keys.lt);
}

/// Less-than with __lt metamethod fallback
/// Returns true/false if comparison can be done, null if no metamethod and not comparable
fn dispatchLtMM(vm: *VM, left: TValue, right: TValue) !?bool {
    // Try numeric comparison first
    if (ltOp(left, right)) |result| {
        return result;
    } else |_| {}

    // Try metamethod - check left first, then right
    const lt_mm = getLtMM(vm, left) orelse getLtMM(vm, right) orelse return null;

    // __lt is a native function - call synchronously
    if (lt_mm.isObject() and lt_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, lt_mm.object);
        const call_base = vm.top - vm.base;

        // Set up call: __lt(left, right)
        vm.stack[vm.top] = left;
        vm.stack[vm.top + 1] = right;
        vm.top += 2;

        try vm.callNative(nc.func.id, @intCast(call_base), 2, 1);

        // Get result and convert to boolean
        const result = vm.stack[vm.base + call_base];
        return result.toBoolean();
    }

    // __lt is a Lua function - call synchronously
    if (lt_mm.asClosure()) |closure| {
        const result = try executeSyncMM(vm, closure, &[_]TValue{ left, right });
        return result.toBoolean();
    }

    return null;
}

/// Try to get __le metamethod from a table
fn getLeMM(vm: *VM, val: TValue) ?TValue {
    const table = val.asTable() orelse return null;
    const mt = table.metatable orelse return null;
    return mt.get(vm.mm_keys.le);
}

/// Less-or-equal with __le metamethod fallback
/// If no __le, tries !(b < a) using __lt
/// Returns true/false if comparison can be done, null if not comparable
fn dispatchLeMM(vm: *VM, left: TValue, right: TValue) !?bool {
    // Try numeric comparison first
    if (leOp(left, right)) |result| {
        return result;
    } else |_| {}

    // Try __le metamethod first
    if (getLeMM(vm, left) orelse getLeMM(vm, right)) |le_mm| {
        // __le is a native function
        if (le_mm.isObject() and le_mm.object.type == .native_closure) {
            const nc = object.getObject(NativeClosureObject, le_mm.object);
            const call_base = vm.top - vm.base;

            vm.stack[vm.top] = left;
            vm.stack[vm.top + 1] = right;
            vm.top += 2;

            try vm.callNative(nc.func.id, @intCast(call_base), 2, 1);

            const result = vm.stack[vm.base + call_base];
            return result.toBoolean();
        }

        // __le is a Lua function
        if (le_mm.asClosure()) |closure| {
            const result = try executeSyncMM(vm, closure, &[_]TValue{ left, right });
            return result.toBoolean();
        }
    }

    // No __le, try using __lt: a <= b iff not (b < a)
    if (getLtMM(vm, right) orelse getLtMM(vm, left)) |lt_mm| {
        // __lt is a native function
        if (lt_mm.isObject() and lt_mm.object.type == .native_closure) {
            const nc = object.getObject(NativeClosureObject, lt_mm.object);
            const call_base = vm.top - vm.base;

            // Note: reversed order for b < a
            vm.stack[vm.top] = right;
            vm.stack[vm.top + 1] = left;
            vm.top += 2;

            try vm.callNative(nc.func.id, @intCast(call_base), 2, 1);

            const result = vm.stack[vm.base + call_base];
            return !result.toBoolean(); // negate: a <= b iff !(b < a)
        }

        // __lt is a Lua function
        if (lt_mm.asClosure()) |closure| {
            const result = try executeSyncMM(vm, closure, &[_]TValue{ right, left });
            return !result.toBoolean();
        }
    }

    return null;
}

/// Bitwise metamethod event types
const BitwiseMetaEvent = enum {
    band,
    bor,
    bxor,
    shl,
    shr,
    bnot,

    fn toKey(self: BitwiseMetaEvent) []const u8 {
        return switch (self) {
            .band => "__band",
            .bor => "__bor",
            .bxor => "__bxor",
            .shl => "__shl",
            .shr => "__shr",
            .bnot => "__bnot",
        };
    }
};

/// Try to get bitwise metamethod from a value
fn getBitwiseMM(vm: *VM, val: TValue, comptime event: BitwiseMetaEvent) !?TValue {
    const table = val.asTable() orelse return null;
    const mt = table.metatable orelse return null;
    const key = try vm.gc.allocString(event.toKey());
    return mt.get(key);
}

/// Binary bitwise with metamethod fallback
/// Returns the result value, or null if no metamethod found
fn dispatchBitwiseMM(vm: *VM, left: TValue, right: TValue, result_reg: u8, comptime event: BitwiseMetaEvent) !?ExecuteResult {
    // Try left operand's metamethod first, then right
    const mm = try getBitwiseMM(vm, left, event) orelse
        try getBitwiseMM(vm, right, event) orelse
        return null;

    // Metamethod is a Lua function
    if (mm.asClosure()) |closure| {
        const proto = closure.proto;
        const new_base = vm.top;

        vm.stack[new_base] = left;
        vm.stack[new_base + 1] = right;

        var i: u32 = 2;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        vm.top = new_base + proto.maxstacksize;
        _ = try pushCallInfo(vm, proto, closure, new_base, vm.base + result_reg, 1);
        return .LoopContinue;
    }

    // Metamethod is a native function
    if (mm.isObject() and mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, mm.object);
        const call_base = vm.top - vm.base;

        vm.stack[vm.top] = left;
        vm.stack[vm.top + 1] = right;
        vm.top += 2;

        try vm.callNative(nc.func.id, @intCast(call_base), 2, 1);
        vm.stack[vm.base + result_reg] = vm.stack[vm.base + call_base];
        return .Continue;
    }

    return null;
}

/// Unary bitwise not with __bnot metamethod fallback
fn dispatchBnotMM(vm: *VM, operand: TValue, result_reg: u8) !?ExecuteResult {
    const mm = try getBitwiseMM(vm, operand, .bnot) orelse return null;

    // Metamethod is a Lua function
    if (mm.asClosure()) |closure| {
        const proto = closure.proto;
        const new_base = vm.top;

        vm.stack[new_base] = operand;

        var i: u32 = 1;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        vm.top = new_base + proto.maxstacksize;
        _ = try pushCallInfo(vm, proto, closure, new_base, vm.base + result_reg, 1);
        return .LoopContinue;
    }

    // Metamethod is a native function
    if (mm.isObject() and mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, mm.object);
        const call_base = vm.top - vm.base;

        vm.stack[vm.top] = operand;
        vm.top += 1;

        try vm.callNative(nc.func.id, @intCast(call_base), 1, 1);
        vm.stack[vm.base + result_reg] = vm.stack[vm.base + call_base];
        return .Continue;
    }

    return null;
}
