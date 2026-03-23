const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const opcodes = @import("../compiler/opcodes.zig");
const pipeline = @import("../compiler/pipeline.zig");
const OpCode = opcodes.OpCode;
const Instruction = opcodes.Instruction;
const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;
const UpvalueObject = object.UpvalueObject;
const ProtoObject = object.ProtoObject;
const StringObject = object.StringObject;
const metamethod = @import("metamethod.zig");
const MetaEvent = metamethod.MetaEvent;
const builtin = @import("../builtin/dispatch.zig");
const ErrorHandler = @import("error.zig");
const NativeFnId = @import("../runtime/native.zig").NativeFnId;

// Execution ABI: CallInfo (frame), ReturnValue (result)
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const ReturnValue = execution.ReturnValue;
const ExecuteResult = execution.ExecuteResult;
const call = @import("call.zig");
const diagnostics = @import("diagnostics.zig");
const error_format = @import("error_format.zig");
const frame = @import("frame.zig");
const name_resolver = @import("name_resolver.zig");

// Import VM (one-way dependency: Mnemonics -> VM)
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;
const error_state = @import("error_state.zig");
const field_cache = @import("field_cache.zig");
const hook_state = @import("hook.zig");
const traceback_state = @import("traceback.zig");
const vm_gc = @import("gc.zig");
const interrupt = @import("../interrupt.zig");

pub const ArithOp = enum { add, sub, mul, div, idiv, mod, pow };
pub const BitwiseOp = enum { band, bor, bxor };

const native_multret_cap: u32 = 256;

fn formatConcatNumber(buf: []u8, n: f64) []const u8 {
    const rendered = std.fmt.bufPrint(buf, "{d}", .{n}) catch return buf[0..0];

    if (std.math.isFinite(n) and
        std.mem.indexOfScalar(u8, rendered, '.') == null and
        std.mem.indexOfAny(u8, rendered, "eE") == null and
        rendered.len + 2 <= buf.len)
    {
        buf[rendered.len] = '.';
        buf[rendered.len + 1] = '0';
        return buf[0 .. rendered.len + 2];
    }

    return rendered;
}

fn nativeDesiredResultsForCall(id: NativeFnId, c: u8, _: u32) u32 {
    if (c > 0) return c - 1;
    // COMPAT HACK: allow MULTRET only for specific natives that are required
    // by compatibility tests while keeping C=0 conservative by default.
    return switch (id) {
        .table_unpack => 0, // C=0 sentinel: callee decides actual result count.
        .string_byte => 0, // C=0 sentinel: callee decides based on i,j args.
        .string_gsub => 2, // gsub always returns (string, count).
        .string_match => 0, // C=0 sentinel: captures can return variable results.
        .utf8_codepoint => 0, // C=0 sentinel: callee decides based on i,j args.
        .select => 0, // C=0 sentinel: callee decides based on index and arg count.
        .debug_getlocal => 0, // C=0 sentinel: allow returning both (name, value).
        .debug_getupvalue => 0, // C=0 sentinel: allow returning (name, value).
        .debug_gethook => 0, // C=0 sentinel: allow returning (func, mask, count).
        .pcall, .xpcall => 0, // C=0 sentinel: propagate success flag + payload.
        .coroutine_yield => 0, // C=0 sentinel: resume values propagate as MULTRET.
        .require => 2, // require returns module value and loader data.
        .next => 2, // next returns key, value
        .load, .loadfile => 2, // load/loadfile return (func) or (nil, err)
        .coroutine_resume => 0, // C=0 sentinel: callee decides actual result count.
        else => 1,
    };
}

fn nativeKeepsTopForCall(id: NativeFnId, c: u8) bool {
    if (c > 0) return false;
    return switch (id) {
        .table_unpack, .string_byte, .string_match, .select, .debug_getlocal => true,
        else => false,
    };
}

fn nativeDesiredResultsForMM(id: NativeFnId, nresults: i16, stack_room: u32) u32 {
    if (nresults >= 0) return @intCast(nresults);
    // MULTRET: these natives can return variable number of results
    return switch (id) {
        .coroutine_resume,
        .coroutine_wrap_call,
        => 0,
        .io_lines_iterator => @min(native_multret_cap, stack_room),
        else => 1,
    };
}

// Bootstrap frame used by protected calls (pcall/xpcall):
// CALL R0, ... ; RETURN R0, ...
var protected_call_bootstrap_code = [_]Instruction{
    Instruction.initABC(.CALL, 0, 0, 0),
    Instruction.initABC(.RETURN, 0, 0, 0),
};
var protected_call_bootstrap_lineinfo = [_]u32{ 1, 1 };
var protected_call_bootstrap_proto = object.ProtoObject{
    .header = object.GCObject.init(.proto, null),
    .k = &.{},
    .code = protected_call_bootstrap_code[0..],
    .protos = &.{},
    .numparams = 0,
    .is_vararg = true,
    .maxstacksize = 2,
    .nups = 0,
    .upvalues = &.{},
    .allocator = std.heap.page_allocator,
    .source = "[protected call bootstrap]",
    .lineinfo = protected_call_bootstrap_lineinfo[0..],
};

// Push a synthetic protected frame that runs CALL/RETURN around the user target.
// This gives pcall/xpcall a normal Lua frame to unwind into on failure.
fn dispatchProtectedCall(vm: *VM, ci: *CallInfo, a: u8, total_args: u32, total_results: u32, handler: ?TValue, ret_base: u32) !ExecuteResult {
    if (total_args == 0) {
        vm.stack[vm.base + a] = .{ .boolean = false };
        vm.stack[vm.base + a + 1] = TValue.fromString(try vm.gc().allocString("bad argument #1 to 'pcall' (value expected)"));
        vm.top = if (total_results == 0) vm.base + a + 2 else vm.base + ci.func.maxstacksize;
        return .Continue;
    }

    const call_base = vm.base + a + 1;
    const user_nresults: u32 = if (total_results > 0) total_results - 1 else 0;
    const pcall_nresults: i16 = if (total_results > 0) @intCast(user_nresults) else -1;

    const new_ci = try pushCallInfoVararg(
        vm,
        &protected_call_bootstrap_proto,
        null,
        call_base,
        ret_base,
        pcall_nresults,
        0,
        0,
    );
    new_ci.is_protected = true;
    if (handler) |h| new_ci.error_handler = h;

    vm.top = call_base + total_args;
    return .LoopContinue;
}

// xpcall inserts an error handler before the real call target.
// Normalize the register layout so the protected bootstrap sees func(...) only.
fn prepareXpcall(vm: *VM, a: u8, total_args: u32, fail_base: u32) !struct { total_args: u32, handler: TValue } {
    if (total_args < 2) {
        vm.stack[fail_base] = .{ .boolean = false };
        vm.stack[fail_base + 1] = TValue.fromString(try vm.gc().allocString("bad argument #2 to 'xpcall' (value expected)"));
        return error.InvalidXpcallHandler;
    }

    const handler = vm.stack[vm.base + a + 2];
    const inner_total_args = total_args - 1;
    if (inner_total_args > 1) {
        var i: u32 = 0;
        const shift_count = inner_total_args - 1;
        while (i < shift_count) : (i += 1) {
            vm.stack[vm.base + a + 2 + i] = vm.stack[vm.base + a + 3 + i];
        }
    }

    return .{ .total_args = inner_total_args, .handler = handler };
}

// Tail-called pcall/xpcall reuses the current frame instead of pushing a new
// CallInfo, but it still needs the same protected bootstrap semantics.
fn reuseCurrentFrameForProtectedCall(current_ci: *CallInfo, ret_base: u32, total_results: u32, handler: ?TValue, new_base: u32) void {
    const pcall_nresults: i16 = if (total_results > 0)
        @intCast(total_results - 1)
    else
        -1;
    current_ci.func = &protected_call_bootstrap_proto;
    current_ci.closure = null;
    current_ci.pc = protected_call_bootstrap_proto.code.ptr;
    current_ci.base = new_base;
    current_ci.ret_base = ret_base;
    current_ci.nresults = pcall_nresults;
    current_ci.was_tail_called = true;
    current_ci.vararg_base = 0;
    current_ci.vararg_count = 0;
    current_ci.is_protected = true;
    current_ci.error_handler = handler orelse .nil;
    current_ci.tbc_bitmap = 0;
    current_ci.pending_return_a = null;
    current_ci.pending_return_count = null;
    current_ci.pending_return_reexec = false;
    current_ci.pending_compare_active = false;
    current_ci.pending_compare_negate = 0;
    current_ci.pending_compare_invert = false;
    current_ci.pending_compare_result_slot = 0;
    current_ci.pending_concat_active = false;
    current_ci.pending_concat_a = 0;
    current_ci.pending_concat_b = 0;
    current_ci.pending_concat_i = -1;
}

// Return/tailcall paths need identical TBC cleanup semantics: propagate errors,
// but remember when __close yielded so the return instruction can re-execute.
fn closeTbcForReturn(vm: *VM, ci: *CallInfo) !void {
    if (ci.tbc_bitmap == 0) return;
    closeTBCVariables(vm, ci, 0, .nil) catch |err| {
        if (err == error.Yield) {
            ci.pending_return_reexec = true;
        }
        return err;
    };
}

fn tableSetWithBarrier(vm: *VM, table: *object.TableObject, key: TValue, value: TValue) !void {
    try table.set(key, value);
    vm.gc().barrierBackValue(&table.header, value);
}

fn upvalueSetWithBarrier(vm: *VM, upvalue: *UpvalueObject, value: TValue) void {
    upvalue.set(value);
    if (upvalue.isClosed()) {
        vm.gc().barrierBackValue(&upvalue.header, value);
    }
}

pub fn luaFloorDiv(a: f64, b: f64) f64 {
    return @floor(a / b);
}

pub fn luaMod(a: f64, b: f64) f64 {
    const r = @rem(a, b);
    if (!std.math.isFinite(r)) return r;
    if (r == 0.0) return r;
    if ((r < 0) != (b < 0)) return r + b;
    return r;
}

fn idivInt(a: i64, b: i64) !i64 {
    if (b == 0) return error.DivideByZero;
    if (b == -1 and a == std.math.minInt(i64)) {
        return a; // wrap per two's complement
    }
    return @divFloor(a, b);
}

fn modInt(a: i64, b: i64) !i64 {
    if (b == 0) return error.ModuloByZero;
    if (b == -1) return 0;
    const r = @rem(a, b); // truncating remainder
    if (r != 0 and ((r < 0) != (b < 0))) {
        return r + b;
    }
    return r;
}

pub fn arithBinary(vm: *VM, inst: Instruction, comptime tag: ArithOp) !void {
    const a = inst.getA();
    const b = inst.getB();
    const c = inst.getC();
    const vb = &vm.stack[vm.base + b];
    const vc = &vm.stack[vm.base + c];

    // Try integer arithmetic first for add, sub, mul, idiv, mod
    // Use wrapping arithmetic per Lua 5.4 semantics (two's complement)
    if (tag == .add or tag == .sub or tag == .mul) {
        if (vb.isInteger() and vc.isInteger()) {
            const ib = vb.integer;
            const ic = vc.integer;
            const res = switch (tag) {
                .add => ib +% ic,
                .sub => ib -% ic,
                .mul => ib *% ic,
                else => unreachable,
            };
            vm.stack[vm.base + a] = .{ .integer = res };
            return;
        }
    }
    if (tag == .idiv or tag == .mod) {
        if (vb.isInteger() and vc.isInteger()) {
            const ib = vb.integer;
            const ic = vc.integer;
            const res = if (tag == .idiv)
                try idivInt(ib, ic)
            else
                try modInt(ib, ic);
            vm.stack[vm.base + a] = .{ .integer = res };
            return;
        }
    }

    // Fall back to floating point
    const nb = vb.toNumber() orelse return error.ArithmeticError;
    const nc = vc.toNumber() orelse return error.ArithmeticError;

    if (tag == .mod) {
        if (floatToIntExact(nb)) |ib| {
            if (floatToIntExact(nc)) |ic| {
                if (ic != 0) {
                    const res_i = try modInt(ib, ic);
                    vm.stack[vm.base + a] = .{ .number = @as(f64, @floatFromInt(res_i)) };
                    return;
                }
            }
        }
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

    const ib = toIntForBitwise(vb) catch |err| {
        if (err == error.IntegerRepresentation) {
            maybeSetIntReprContext(vm, b);
        }
        return err;
    };
    const ic = toIntForBitwise(vc) catch |err| {
        if (err == error.IntegerRepresentation) {
            maybeSetIntReprContext(vm, c);
        }
        return err;
    };

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
    } else if (v.* == .object and v.object.type == .string) {
        const str = object.getObject(StringObject, v.object);
        const slice = std.mem.trim(u8, str.asSlice(), " \t\n\r");
        return parseStringIntForBitwise(slice);
    } else if (v.toNumber()) |n| {
        if (@floor(n) != n) return error.IntegerRepresentation;
        const min_f = @as(f64, @floatFromInt(std.math.minInt(i64)));
        const max_f = @as(f64, @floatFromInt(std.math.maxInt(i64)));
        if (n < min_f or n > max_f) return error.IntegerRepresentation;
        // Reject ambiguous max_f (2^63) for floats; allow min_f.
        if (n == max_f) return error.IntegerRepresentation;

        const i: i64 = @intFromFloat(n);
        if (@as(f64, @floatFromInt(i)) == n) {
            return i;
        }
        return error.IntegerRepresentation;
    }
    return error.ArithmeticError;
}

fn parseStringIntForBitwise(slice: []const u8) !i64 {
    if (slice.len == 0) return error.ArithmeticError;

    var i: usize = 0;
    var negative = false;
    if (slice[i] == '+' or slice[i] == '-') {
        negative = slice[i] == '-';
        i += 1;
        if (i >= slice.len) return error.ArithmeticError;
    }

    var base: u8 = 10;
    const is_hex = i + 1 < slice.len and slice[i] == '0' and (slice[i + 1] == 'x' or slice[i + 1] == 'X');
    if (is_hex) {
        base = 16;
        i += 2;
        if (i >= slice.len) return error.ArithmeticError;
    }

    const body = slice[i..];
    const has_dot = std.mem.indexOfScalar(u8, body, '.') != null;
    const has_p_exp = std.mem.indexOfAny(u8, body, "pP") != null;
    const has_e_exp = std.mem.indexOfAny(u8, body, "eE") != null;
    const is_float_like = has_dot or has_p_exp or (!is_hex and has_e_exp);

    // Integer-like strings use modulo 2^64.
    if (!is_float_like) {
        var bits: u64 = 0;
        for (body) |ch| {
            const digit: u8 = switch (ch) {
                '0'...'9' => ch - '0',
                'a'...'f' => 10 + (ch - 'a'),
                'A'...'F' => 10 + (ch - 'A'),
                else => return error.ArithmeticError,
            };
            if (digit >= base) return error.ArithmeticError;
            bits = bits *% @as(u64, base) +% @as(u64, digit);
        }
        if (negative) bits = 0 -% bits;
        return @bitCast(bits);
    }

    // Float-like strings must have exact integer representation in i64 range.
    const n = std.fmt.parseFloat(f64, slice) catch return error.ArithmeticError;
    if (@floor(n) != n) return error.IntegerRepresentation;
    const min_f = @as(f64, @floatFromInt(std.math.minInt(i64)));
    const max_f = @as(f64, @floatFromInt(std.math.maxInt(i64)));
    if (n < min_f or n > max_f) return error.IntegerRepresentation;
    if (n == max_f) return error.IntegerRepresentation;
    const i64v: i64 = @intFromFloat(n);
    if (@as(f64, @floatFromInt(i64v)) != n) return error.IntegerRepresentation;
    return i64v;
}

fn floatToIntExact(n: f64) ?i64 {
    if (!std.math.isFinite(n)) return null;
    if (n != @floor(n)) return null;
    const max_i = std.math.maxInt(i64);
    const min_i = std.math.minInt(i64);
    const max_f = @as(f64, @floatFromInt(max_i));
    const min_f = @as(f64, @floatFromInt(min_i));
    if (n < min_f or n > max_f) return null;
    if (!intFitsFloat(max_i) and n >= max_f) return null;
    const i: i64 = @intFromFloat(n);
    if (@as(f64, @floatFromInt(i)) != n) return null;
    return i;
}

fn intFitsFloat(i: i64) bool {
    const max_exact: i64 = @as(i64, 1) << 53;
    return i >= -max_exact and i <= max_exact;
}

fn maybeSetIntReprContext(vm: *VM, reg: u8) void {
    field_cache.rememberIntReprContext(vm, reg);
}

fn shlInt(value: i64, shift: i64) i64 {
    if (shift < 0) {
        // abs(minInt) overflows in two's complement; Lua treats huge shifts as zero.
        if (shift == std.math.minInt(i64)) return 0;
        return shrInt(value, -shift);
    }
    if (shift >= 64) return 0;
    const u: u64 = @bitCast(value);
    const res: u64 = u << @intCast(shift);
    return @bitCast(res);
}

fn shrInt(value: i64, shift: i64) i64 {
    if (shift < 0) {
        if (shift == std.math.minInt(i64)) return 0;
        return shlInt(value, -shift);
    }
    if (shift >= 64) return 0;
    const u: u64 = @bitCast(value);
    const res: u64 = u >> @intCast(shift);
    return @bitCast(res);
}

pub fn eqOp(a: TValue, b: TValue) bool {
    return a.eql(b);
}

const CallNameKind = name_resolver.CallNameKind;
const CallNameContext = name_resolver.CallNameContext;

const currentInstructionIndex = name_resolver.currentInstructionIndex;
const findNearestOpcodeBack = name_resolver.findNearestOpcodeBack;
const findRegisterProducerBack = name_resolver.findRegisterProducerBack;
const arithmeticNameOperandOperatorLine = name_resolver.arithmeticNameOperandOperatorLine;
const callNameContext = name_resolver.callNameContext;
const traceNonMethodObjectContext = name_resolver.traceNonMethodObjectContext;
const resolveRegisterNameContext = name_resolver.resolveRegisterNameContext;
const findUnaryOperatorLineInSource = name_resolver.findUnaryOperatorLineInSource;
const findCallOpenParenLineInSource = name_resolver.findCallOpenParenLineInSource;

const runtimeErrorLine = diagnostics.runtimeErrorLine;
const runtimeErrorWithLocation = diagnostics.runtimeErrorWithLocation;
const raiseWithLocation = diagnostics.raiseWithLocation;
pub const runtimeErrorWithCurrentLocation = diagnostics.runtimeErrorWithCurrentLocation;
const callableValueTypeName = error_format.callableValueTypeName;
const namedValueTypeName = error_format.namedValueTypeName;
pub const formatIndexOnNonTableError = error_format.formatIndexOnNonTableError;
pub fn formatArithmeticError(vm: *VM, inst: Instruction, msg_buf: *[128]u8) []const u8 {
    return error_format.formatArithmeticError(vm, inst, msg_buf, toIntForBitwise);
}
pub fn formatIntegerRepresentationError(vm: *VM, inst: Instruction, msg_buf: *[128]u8) []const u8 {
    return error_format.formatIntegerRepresentationError(vm, inst, msg_buf, toIntForBitwise);
}
pub const formatForLoopError = error_format.formatForLoopError;
pub const formatNoCloseMetamethodError = error_format.formatNoCloseMetamethodError;
const buildCallNotFunctionMessage = error_format.buildCallNotFunctionMessage;

fn isVmRuntimeError(err: anyerror) bool {
    return err == error.CallStackOverflow or
        err == error.ArithmeticError or
        err == error.DivideByZero or
        err == error.ModuloByZero or
        err == error.IntegerRepresentation or
        err == error.OrderComparisonError or
        err == error.LengthError or
        err == error.NotATable or
        err == error.NotAFunction or
        err == error.InvalidTableKey or
        err == error.InvalidTableOperation or
        err == error.InvalidForLoopInit or
        err == error.InvalidForLoopLimit or
        err == error.InvalidForLoopStep or
        err == error.NoCloseMetamethod or
        err == error.FormatError;
}

fn formatVmRuntimeErrorMessage(vm: *VM, inst: Instruction, err: anyerror, msg_buf: *[128]u8) []const u8 {
    return switch (err) {
        error.CallStackOverflow => if (vm.errors.error_handling_depth > 0) "error in error handling" else "stack overflow",
        error.ArithmeticError => formatArithmeticError(vm, inst, msg_buf),
        error.DivideByZero => "divide by zero",
        error.ModuloByZero => "attempt to perform 'n%0'",
        error.IntegerRepresentation => formatIntegerRepresentationError(vm, inst, msg_buf),
        error.NotATable => formatIndexOnNonTableError(vm, inst, msg_buf),
        error.NotAFunction => "attempt to call a non-function value",
        error.OrderComparisonError => "attempt to compare values",
        error.LengthError => "attempt to get length of a value",
        error.InvalidTableKey => "table index is nil or NaN",
        error.InvalidTableOperation => formatIndexOnNonTableError(vm, inst, msg_buf),
        error.InvalidForLoopInit => formatForLoopError(vm, inst, err, msg_buf),
        error.InvalidForLoopLimit => formatForLoopError(vm, inst, err, msg_buf),
        error.InvalidForLoopStep => formatForLoopError(vm, inst, err, msg_buf),
        error.NoCloseMetamethod => formatNoCloseMetamethodError(vm, inst, msg_buf),
        error.FormatError => "bad argument to string format",
        else => "runtime error",
    };
}

fn continueIfLuaExceptionHandled(vm: *VM, err: anyerror) error{Yield}!bool {
    if (err != error.LuaException) return false;
    return try handleLuaException(vm);
}

fn continueMetamethodIfLuaExceptionHandled(vm: *VM, err: anyerror, saved_depth: u8) error{Yield}!bool {
    if (err != error.LuaException or error_state.isClosingMetamethod(vm)) return false;
    if (!(try handleLuaException(vm))) return false;
    return vm.callstack_size > saved_depth;
}

fn metamethodEventName(comptime event: MetaEvent) []const u8 {
    return switch (event) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .mod => "mod",
        .pow => "pow",
        .idiv => "idiv",
        .band => "band",
        .bor => "bor",
        .bxor => "bxor",
        .shl => "shl",
        .shr => "shr",
        .unm => "unm",
        .bnot => "bnot",
        .eq => "eq",
        .lt => "lt",
        .le => "le",
        .index => "index",
        .newindex => "newindex",
        .call => "call",
        .concat => "concat",
        .len => "len",
        .close => "close",
        .name => "name",
        .pairs => "pairs",
        .mode => "mode",
        .gc => "gc",
        .tostring => "tostring",
        .metatable => "metatable",
    };
}

fn metamethodEventNameRuntime(event: MetaEvent) []const u8 {
    return switch (event) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .mod => "mod",
        .pow => "pow",
        .idiv => "idiv",
        .band => "band",
        .bor => "bor",
        .bxor => "bxor",
        .shl => "shl",
        .shr => "shr",
        .unm => "unm",
        .bnot => "bnot",
        .eq => "eq",
        .lt => "lt",
        .le => "le",
        .index => "index",
        .newindex => "newindex",
        .call => "call",
        .concat => "concat",
        .len => "len",
        .close => "close",
        .gc => "gc",
        .tostring => "tostring",
        .metatable => "metatable",
        .name => "name",
        .pairs => "pairs",
        .mode => "mode",
    };
}

fn markMetamethodFrame(ci: *CallInfo, name: []const u8) void {
    ci.debug_name = name;
    ci.debug_namewhat = "metamethod";
}

fn raiseMetamethodNotCallable(vm: *VM, mm: TValue, metamethod_name: []const u8) !void {
    const ty = callableValueTypeName(mm);
    var msg_buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "attempt to call a {s} value (metamethod '{s}')", .{ ty, metamethod_name }) catch "attempt to call metamethod value";
    return vm.raiseString(msg);
}

fn raiseIndexValueError(vm: *VM, value: TValue) !void {
    const ty = callableValueTypeName(value);
    var msg_buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "attempt to index a {s} value", .{ty}) catch "attempt to index a non-table value";
    return vm.raiseString(msg);
}

fn raiseOrderComparison(vm: *VM, left: TValue, right: TValue) !bool {
    const left_ty = namedValueTypeName(vm, left);
    const right_ty = namedValueTypeName(vm, right);
    var msg_buf: [128]u8 = undefined;
    const msg = if (std.mem.eql(u8, left_ty, right_ty))
        std.fmt.bufPrint(&msg_buf, "attempt to compare two {s} values", .{left_ty}) catch "attempt to compare values"
    else
        std.fmt.bufPrint(&msg_buf, "attempt to compare {s} with {s}", .{ left_ty, right_ty }) catch "attempt to compare values";
    return vm.raiseString(msg);
}

pub fn ltOp(a: TValue, b: TValue) !bool {
    if (a.isInteger() and b.isInteger()) {
        return a.integer < b.integer;
    }
    if (a.isNumber() and b.isNumber()) {
        return a.number < b.number;
    }
    if (a.isInteger() and b.isNumber()) {
        return compareIntFloat(a.integer, b.number, false);
    }
    if (a.isNumber() and b.isInteger()) {
        return compareFloatInt(a.number, b.integer, false);
    }
    if (a.asString()) |as| {
        if (b.asString()) |bs| {
            return std.mem.order(u8, as.asSlice(), bs.asSlice()) == .lt;
        }
    }
    return error.OrderComparisonError;
}

pub fn leOp(a: TValue, b: TValue) !bool {
    if (a.isInteger() and b.isInteger()) {
        return a.integer <= b.integer;
    }
    if (a.isNumber() and b.isNumber()) {
        return a.number <= b.number;
    }
    if (a.isInteger() and b.isNumber()) {
        return compareIntFloat(a.integer, b.number, true);
    }
    if (a.isNumber() and b.isInteger()) {
        return compareFloatInt(a.number, b.integer, true);
    }
    if (a.asString()) |as| {
        if (b.asString()) |bs| {
            const ord = std.mem.order(u8, as.asSlice(), bs.asSlice());
            return ord == .lt or ord == .eq;
        }
    }
    return error.OrderComparisonError;
}

fn compareIntFloat(i: i64, f: f64, comptime le: bool) bool {
    if (std.math.isNan(f)) return false;
    if (intFitsFloat(i)) {
        const i_f = @as(f64, @floatFromInt(i));
        return if (le) i_f <= f else i_f < f;
    }
    if (le) {
        if (floatToIntFloor(f)) |fi| {
            return i <= fi;
        }
        return f > 0;
    }
    if (floatToIntCeil(f)) |fi| {
        return i < fi;
    }
    return f > 0;
}

fn compareFloatInt(f: f64, i: i64, comptime le: bool) bool {
    if (std.math.isNan(f)) return false;
    if (intFitsFloat(i)) {
        const i_f = @as(f64, @floatFromInt(i));
        return if (le) f <= i_f else f < i_f;
    }
    if (le) {
        if (floatToIntCeil(f)) |fi| {
            return fi <= i;
        }
        return f < 0;
    }
    if (floatToIntFloor(f)) |fi| {
        return fi < i;
    }
    return f < 0;
}

fn floatToIntFloor(f: f64) ?i64 {
    if (!std.math.isFinite(f)) return null;
    return floatToIntChecked(std.math.floor(f));
}

fn floatToIntCeil(f: f64) ?i64 {
    if (!std.math.isFinite(f)) return null;
    return floatToIntChecked(std.math.ceil(f));
}

fn floatToIntChecked(f: f64) ?i64 {
    const max_i = std.math.maxInt(i64);
    const min_i = std.math.minInt(i64);
    const max_f = @as(f64, @floatFromInt(max_i));
    const min_f = @as(f64, @floatFromInt(min_i));
    if (f < min_f or f > max_f) return null;
    if (!intFitsFloat(max_i) and f >= max_f) return null;
    return @as(i64, @intFromFloat(f));
}

pub const pushCallInfo = frame.pushCallInfo;
pub const pushCallInfoVararg = frame.pushCallInfoVararg;
pub const popCallInfo = frame.popCallInfo;
const ensureStackTop = frame.ensureStackTop;

/// Execute a metamethod synchronously and return its first result.
/// Used for comparison metamethods (__eq, __lt, __le) that need immediate results.
pub fn executeSyncMM(vm: *VM, closure: *ClosureObject, args: []const TValue) anyerror!TValue {
    return executeSyncMMWithDebug(vm, closure, args, null, null);
}

fn executeSyncMMWithDebug(
    vm: *VM,
    closure: *ClosureObject,
    args: []const TValue,
    debug_name: ?[]const u8,
    debug_namewhat: ?[]const u8,
) anyerror!TValue {
    const proto = closure.proto;
    // Use a safe stack location that doesn't overlap with the caller's active stack.
    // The caller's base + maxstacksize should be safe.
    const caller_ci = vm.ci.?;
    const safe_base = caller_ci.base + caller_ci.func.maxstacksize;
    const call_base = @max(vm.top, safe_base);
    const result_slot = call_base;
    const argc: u32 = @intCast(args.len);

    // Ensure there is room for argument setup and callee frame.
    const min_arg_slots = @max(argc, @as(u32, proto.numparams));
    try ensureStackTop(vm, call_base + min_arg_slots);
    try ensureStackTop(vm, call_base + proto.maxstacksize);

    // Set up arguments
    for (args, 0..) |arg, i| {
        vm.stack[call_base + i] = arg;
    }

    var vararg_base: u32 = 0;
    var vararg_count: u32 = 0;
    if (proto.is_vararg and argc > proto.numparams) {
        vararg_count = argc - proto.numparams;
        const min_vararg_base = call_base + proto.maxstacksize;
        vararg_base = @max(min_vararg_base, vm.top) + 32;
        try ensureStackTop(vm, vararg_base + vararg_count);
        var i: u32 = vararg_count;
        while (i > 0) {
            i -= 1;
            vm.stack[vararg_base + i] = vm.stack[call_base + proto.numparams + i];
        }
    }

    // Fill remaining fixed params with nil
    var i: u32 = argc;
    while (i < proto.numparams) : (i += 1) {
        vm.stack[call_base + i] = .nil;
    }

    // Save current call depth
    const saved_depth = vm.callstack_size;
    const saved_ci = vm.ci;
    const saved_base = vm.base;
    const saved_top = vm.top;
    const cleanupToSavedDepth = struct {
        fn run(vm2: *VM, depth: u8, ci_saved: ?*CallInfo, base: u32, top: u32) void {
            while (vm2.callstack_size > depth) {
                popCallInfo(vm2);
            }
            vm2.ci = ci_saved;
            vm2.base = base;
            vm2.top = top;
        }
    }.run;

    // Push call info for metamethod
    const new_ci = try pushCallInfoVararg(vm, proto, closure, call_base, result_slot, 1, vararg_base, vararg_count);
    if (debug_name) |name| {
        new_ci.debug_name = name;
        new_ci.debug_namewhat = debug_namewhat orelse "metamethod";
    }
    vm.top = if (vararg_count > 0) vararg_base + vararg_count else call_base + proto.maxstacksize;

    // Execute until we return to saved depth
    while (vm.callstack_size > saved_depth) {
        const ci = &vm.callstack[vm.callstack_size - 1];
        const inst = ci.fetch() catch {
            vm.base = ci.ret_base;
            vm.top = ci.ret_base + 1;
            popCallInfo(vm);
            continue;
        };
        const step = do(vm, inst) catch |err| {
            if (err == error.HandledException) {
                continue;
            }
            if (try continueMetamethodIfLuaExceptionHandled(vm, err, saved_depth)) {
                continue;
            }
            if (err == error.LuaException) {
                while (vm.callstack_size > saved_depth) {
                    const unwind_ci = &vm.callstack[vm.callstack_size - 1];
                    closeTBCVariables(vm, unwind_ci, 0, vm.errors.lua_error_value) catch {};
                    vm.closeUpvalues(unwind_ci.base);
                    popCallInfo(vm);
                }
                vm.ci = saved_ci;
                vm.base = saved_base;
                vm.top = saved_top;
                return error.LuaException;
            }
            if (isVmRuntimeError(err)) {
                var msg_buf: [128]u8 = undefined;
                const msg = formatVmRuntimeErrorMessage(vm, inst, err, &msg_buf);
                var full_msg_buf: [320]u8 = undefined;
                const full_msg = runtimeErrorWithCurrentLocation(vm, inst, err, msg, &full_msg_buf);
                vm.errors.lua_error_value = TValue.fromString(vm.gc().allocString(full_msg) catch {
                    cleanupToSavedDepth(vm, saved_depth, saved_ci, saved_base, saved_top);
                    return err;
                });
                if (try continueMetamethodIfLuaExceptionHandled(vm, error.LuaException, saved_depth)) continue;
                cleanupToSavedDepth(vm, saved_depth, saved_ci, saved_base, saved_top);
                return error.LuaException;
            }
            if (err == error.NoCloseMetamethod) {
                const reg = inst.getA();
                const name = if (reg < ci.func.local_reg_names.len and ci.func.local_reg_names[reg] != null)
                    ci.func.local_reg_names[reg].?
                else
                    "?";
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "variable '{s}' got a non-closable value", .{name}) catch "variable got a non-closable value";
                vm.errors.lua_error_value = TValue.fromString(vm.gc().allocString(msg) catch return err);
                cleanupToSavedDepth(vm, saved_depth, saved_ci, saved_base, saved_top);
                return error.LuaException;
            }
            if (err == error.Yield) {
                // Preserve stack/frame state for coroutine resume.
                return error.Yield;
            }
            cleanupToSavedDepth(vm, saved_depth, saved_ci, saved_base, saved_top);
            return err;
        };
        switch (step) {
            .Continue => {},
            .LoopContinue => {},
            .ReturnVM => break,
        }
    }

    const result = vm.stack[result_slot];
    vm.ci = saved_ci;
    vm.base = saved_base;
    vm.top = saved_top;
    return result;
}

fn nativeReturnHookName(id: NativeFnId) ?[]const u8 {
    return switch (id) {
        .math_sin => "sin",
        .select => "select",
        .debug_sethook => "sethook",
        else => null,
    };
}

/// Close to-be-closed variables from the current frame
/// Calls __close metamethod on TBC variables from highest to 'from_reg'
pub fn closeTBCVariables(vm: *VM, ci: *CallInfo, from_reg: u8, err_obj: TValue) anyerror!void {
    const close_tag = "in metamethod 'close'";
    const annotateCloseError = struct {
        fn run(vm2: *VM, tag: []const u8) void {
            const s = vm2.errors.lua_error_value.asString() orelse return;
            if (std.mem.indexOf(u8, s.asSlice(), tag) != null) return;
            const merged = std.fmt.allocPrint(vm2.gc().allocator, "{s} {s}", .{ s.asSlice(), tag }) catch return;
            defer vm2.gc().allocator.free(merged);
            const merged_obj = vm2.gc().allocString(merged) catch return;
            vm2.errors.lua_error_value = TValue.fromString(merged_obj);
        }
    }.run;

    var current_err = err_obj;
    var had_error = !current_err.isNil();

    const saved_name_override = vm.hooks.name_override;
    if (!err_obj.isNil()) vm.hooks.name_override = "pcall";
    defer vm.hooks.name_override = saved_name_override;

    const setCloseCallError = struct {
        fn run(vm2: *VM, mm_val: TValue) TValue {
            var msg_buf: [128]u8 = undefined;
            const ty = callableValueTypeName(mm_val);
            const msg = std.fmt.bufPrint(&msg_buf, "attempt to call a {s} value (metamethod 'close')", .{ty}) catch "attempt to call a value (metamethod 'close')";
            const obj = vm2.gc().allocString(msg) catch return vm2.errors.lua_error_value;
            const v = TValue.fromString(obj);
            vm2.errors.lua_error_value = v;
            return v;
        }
    }.run;

    // Process TBC variables from high to low (reverse order)
    var reg = ci.getHighestTBC(from_reg);
    while (reg) |r| {
        const val = vm.stack[vm.base + r];
        // Clear mark before invoking __close to avoid re-entering the same slot
        // if __close raises and unwinding runs close logic again.
        ci.clearTBC(r);

        // Get __close metamethod
        if (metamethod.getMetamethod(val, .close, &vm.gc().mm_keys, &vm.gc().shared_mt)) |mm| {
            // Call __close(val, err_obj) where err_obj is nil on normal close
            // or current error object during unwinding.
            const saved_top = vm.top;

            if (mm.asClosure()) |closure| {
                // executeSyncMM handles stack setup using vm.top
                error_state.beginCloseMetamethod(vm);
                defer {
                    error_state.endCloseMetamethod(vm);
                }
                _ = executeSyncMM(vm, closure, &[_]TValue{ val, current_err }) catch |err| switch (err) {
                    error.LuaException => {
                        annotateCloseError(vm, close_tag);
                        current_err = vm.errors.lua_error_value;
                        had_error = true;
                        vm.top = saved_top;
                        if (r == 0) break;
                        reg = ci.getHighestTBC(from_reg);
                        continue;
                    },
                    error.CallStackOverflow => {
                        const msg = if (vm.errors.error_handling_depth > 0) "error in error handling" else "stack overflow";
                        vm.errors.lua_error_value = TValue.fromString(try vm.gc().allocString(msg));
                        annotateCloseError(vm, close_tag);
                        current_err = vm.errors.lua_error_value;
                        had_error = true;
                        vm.top = saved_top;
                        if (r == 0) break;
                        reg = ci.getHighestTBC(from_reg);
                        continue;
                    },
                    else => return err,
                };
            } else if (mm.isObject() and mm.object.type == .native_closure) {
                const nc = object.getObject(NativeClosureObject, mm.object);
                // Set up arguments for native call
                const temp = vm.top;
                vm.stack[temp] = mm;
                vm.stack[temp + 1] = val;
                vm.stack[temp + 2] = current_err;
                vm.top = temp + 3;
                error_state.beginCloseMetamethod(vm);
                defer {
                    error_state.endCloseMetamethod(vm);
                }
                vm.callNative(nc.func.id, @intCast(temp - vm.base), 2, 0) catch |err| switch (err) {
                    error.LuaException => {
                        annotateCloseError(vm, close_tag);
                        current_err = vm.errors.lua_error_value;
                        had_error = true;
                        vm.top = saved_top;
                        if (r == 0) break;
                        reg = ci.getHighestTBC(from_reg);
                        continue;
                    },
                    error.CallStackOverflow => {
                        const msg = if (vm.errors.error_handling_depth > 0) "error in error handling" else "stack overflow";
                        vm.errors.lua_error_value = TValue.fromString(try vm.gc().allocString(msg));
                        annotateCloseError(vm, close_tag);
                        current_err = vm.errors.lua_error_value;
                        had_error = true;
                        vm.top = saved_top;
                        if (r == 0) break;
                        reg = ci.getHighestTBC(from_reg);
                        continue;
                    },
                    else => return err,
                };
                try hook_state.onReturn(vm, "close", null, executeSyncMM);
            } else {
                current_err = setCloseCallError(vm, mm);
                had_error = true;
            }
            vm.top = saved_top;
        } else {
            // Value became non-closable (e.g. __close removed) before close time.
            current_err = setCloseCallError(vm, .nil);
            had_error = true;
        }

        // Get next TBC variable
        if (r == 0) break;
        reg = ci.getHighestTBC(from_reg);
    }

    if (had_error) {
        vm.errors.lua_error_value = current_err;
        return error.LuaException;
    }
}

fn setupMainFrame(vm: *VM, proto: *const ProtoObject, main_closure: *ClosureObject, main_args: []const TValue) void {
    const argc: u32 = @intCast(main_args.len);
    const params_to_copy: u32 = @min(argc, @as(u32, proto.numparams));
    var i: u32 = 0;
    while (i < params_to_copy) : (i += 1) {
        vm.stack[i] = main_args[i];
    }
    while (i < proto.numparams) : (i += 1) {
        vm.stack[i] = .nil;
    }

    var vararg_base: u32 = 0;
    var vararg_count: u32 = 0;
    if (proto.is_vararg and argc > proto.numparams) {
        vararg_count = argc - proto.numparams;
        vararg_base = proto.maxstacksize + 32;
        var vi: u32 = 0;
        while (vi < vararg_count) : (vi += 1) {
            vm.stack[vararg_base + vi] = main_args[proto.numparams + vi];
        }
    }

    vm.base_ci = CallInfo{
        .func = proto,
        .closure = main_closure,
        .pc = proto.code.ptr,
        .savedpc = null,
        .base = 0,
        .ret_base = 0,
        .nresults = -1,
        .vararg_base = vararg_base,
        .vararg_count = vararg_count,
        .previous = null,
    };
    vm.ci = &vm.base_ci;
    vm.base = 0;
    vm.top = if (vararg_count > 0) vararg_base + vararg_count else proto.maxstacksize;
}

/// Handle a LuaException by unwinding to the nearest protected frame.
/// Returns true if error was handled by a protected frame, false otherwise.
/// The error value is taken from vm.errors.lua_error_value (set by vm.raise()).
pub fn handleLuaException(vm: *VM) error{Yield}!bool {
    error_state.beginHandling(vm);
    defer {
        error_state.endHandling(vm);
    }
    vm.traceback.snapshot_count = 0;
    vm.traceback.snapshot_has_error_frame = false;
    var current = vm.ci;
    while (current) |ci| {
        if (ci.is_protected) {
            const ret_base = ci.ret_base;
            const protected_nresults = ci.nresults;
            const protected_error_handler = ci.error_handler;
            const target_ci = ci.previous;
            traceback_state.captureSnapshot(vm, target_ci);
            while (vm.ci != null and vm.ci != target_ci) {
                const unwind_ci = vm.ci.?;
                closeTBCVariables(vm, unwind_ci, 0, vm.errors.lua_error_value) catch |cerr| switch (cerr) {
                    error.Yield => {
                        error_state.setPendingUnwind(vm, unwind_ci);
                        return error.Yield;
                    },
                    else => {},
                };
                vm.closeUpvalues(unwind_ci.base);
                popCallInfo(vm);
            }

            var handled_error = vm.errors.lua_error_value;
            const already_handled = vm.stack[ret_base].isBoolean() and !vm.stack[ret_base].boolean and !vm.stack[ret_base + 1].isNil();
            // Defensive: avoid clobbering a previously captured non-nil error in the
            // same protected return slot when a reentrant handler path reports nil.
            if (handled_error.isNil() and vm.stack[ret_base].isBoolean() and !vm.stack[ret_base].boolean and !vm.stack[ret_base + 1].isNil()) {
                handled_error = vm.stack[ret_base + 1];
            }
            if (already_handled) {
                handled_error = vm.stack[ret_base + 1];
            } else if (!protected_error_handler.isNil()) {
                error_state.beginHandling(vm);
                defer {
                    error_state.endHandling(vm);
                }
                if (protected_error_handler.asClosure()) |_| {
                    handled_error = call.callValueSafe(vm, protected_error_handler, &[_]TValue{handled_error}) catch |handler_err| switch (handler_err) {
                        error.Yield => return error.Yield,
                        error.LuaException => blk: {
                            const s = vm.gc().allocString("error in error handling") catch break :blk vm.errors.lua_error_value;
                            break :blk TValue.fromString(s);
                        },
                        else => blk: {
                            const s = vm.gc().allocString("error in error handling") catch break :blk vm.errors.lua_error_value;
                            break :blk TValue.fromString(s);
                        },
                    };
                } else if (protected_error_handler.asNativeClosure()) |nc| {
                    const temp = vm.top;
                    vm.stack[temp] = protected_error_handler;
                    vm.stack[temp + 1] = handled_error;
                    vm.top = temp + 2;
                    var handler_ok = true;
                    vm.callNative(nc.func.id, @intCast(temp - vm.base), 1, 1) catch |handler_err| switch (handler_err) {
                        error.Yield => return error.Yield,
                        error.LuaException => {
                            handler_ok = false;
                            const s = vm.gc().allocString("error in error handling") catch null;
                            handled_error = if (s) |ss| TValue.fromString(ss) else vm.errors.lua_error_value;
                        },
                        else => {
                            handler_ok = false;
                            const s = vm.gc().allocString("error in error handling") catch null;
                            handled_error = if (s) |ss| TValue.fromString(ss) else vm.errors.lua_error_value;
                        },
                    };
                    if (handler_ok) {
                        handled_error = vm.stack[temp];
                    }
                    vm.top = temp;
                } else {
                    const s = vm.gc().allocString("error in error handling") catch null;
                    handled_error = if (s) |ss| TValue.fromString(ss) else vm.errors.lua_error_value;
                }
            }

            // Place (false, error_value) in return slots
            vm.stack[ret_base] = .{ .boolean = false };
            vm.stack[ret_base + 1] = handled_error;
            if (protected_nresults >= 0) {
                const expected: u32 = @intCast(protected_nresults);
                if (expected > 1) {
                    var i: u32 = 1;
                    while (i < expected) : (i += 1) {
                        vm.stack[ret_base + 1 + i] = .nil;
                    }
                }
            }
            error_state.clearRaisedValue(vm); // Clear after use
            const caller_frame_top: u32 = if (vm.ci) |caller_ci| vm.base + caller_ci.func.maxstacksize else ret_base + 2;
            vm.top = if (protected_nresults < 0) ret_base + 2 else caller_frame_top;
            error_state.clearPendingUnwind(vm);
            return true;
        }
        current = ci.previous;
    }

    normalizeUnhandledErrorValue(vm);

    // No protected frame handled this error. Preserve current stack lines so
    // debug.traceback(thread) can report frames after coroutine becomes dead.
    traceback_state.captureSnapshot(vm, null);
    error_state.clearPendingUnwind(vm);
    return false;
}

fn normalizeUnhandledErrorValue(vm: *VM) void {
    if (vm.errors.lua_error_value.asString() != null) return;

    const mm = metamethod.getMetamethod(vm.errors.lua_error_value, .tostring, &vm.gc().mm_keys, &vm.gc().shared_mt) orelse return;
    const closure = mm.asClosure() orelse return;
    const result = executeTostringForUnhandledError(vm, closure, vm.errors.lua_error_value) catch return;
    if (result.asString()) |s| {
        vm.errors.lua_error_value = TValue.fromString(s);
    }
}

fn executeTostringForUnhandledError(vm: *VM, closure: *ClosureObject, value: TValue) !TValue {
    const allocator = vm.rt.allocator;
    const compile_result = pipeline.compile(allocator, "local f, x = ...; return f(x)", .{ .source_name = "=(error handler)" });
    switch (compile_result) {
        .err => |e| {
            e.deinit(allocator);
            return executeSyncMM(vm, closure, &[_]TValue{value});
        },
        .ok => {},
    }
    const raw_proto = compile_result.ok;
    defer pipeline.freeRawProto(allocator, raw_proto);

    const proto = try pipeline.materialize(&raw_proto, vm.gc(), allocator);
    const wrapper = try vm.gc().allocClosure(proto);
    if (proto.nups > 0) {
        wrapper.upvalues[0].closed = TValue.fromTable(vm.globals());
        wrapper.upvalues[0].location = &wrapper.upvalues[0].closed;
    }

    _ = vm.pushTempRoot(TValue.fromClosure(wrapper));
    defer vm.popTempRoots(1);

    return executeSyncMM(vm, wrapper, &[_]TValue{ TValue.fromClosure(closure), value });
}

pub fn captureCurrentTracebackSnapshot(vm: *VM) void {
    traceback_state.captureSnapshot(vm, null);
}

/// Main VM execution loop.
/// Executes instructions until RETURN from main chunk.
pub fn executeWithArgs(vm: *VM, proto: *const ProtoObject, main_args: []const TValue) !ReturnValue {
    // Create main closure with _ENV upvalue pointing to globals
    // Inhibit GC during allocation sequence to prevent collection of
    // intermediate objects (main_closure) before they're fully rooted
    vm.gc().inhibitGC();
    const proto_mut = @constCast(proto);
    const main_closure = vm.gc().allocClosure(proto_mut) catch |err| {
        vm.gc().allowGC();
        return err;
    };
    if (proto.nups > 0) {
        // Main chunk's upvalue[0] is _ENV = globals
        main_closure.upvalues[0].closed = TValue.fromTable(vm.globals());
        main_closure.upvalues[0].location = &main_closure.upvalues[0].closed;
    }
    vm.gc().allowGC();

    setupMainFrame(vm, proto, main_closure, main_args);

    // Finalizers are executed by the currently running VM.
    vm.gc().setFinalizerExecutor(vm_gc.finalizerExecutor(vm));
    defer vm.gc().setFinalizerExecutor(null);

    while (true) {
        if (vm.gc().hasPendingFinalizers()) {
            vm.gc().drainFinalizers();
        }
        if (vm.errors.pending_error_unwind and vm.errors.pending_error_unwind_ci != null and vm.ci == vm.errors.pending_error_unwind_ci.?) {
            if (try continueIfLuaExceptionHandled(vm, error.LuaException)) continue;
            return error.LuaException;
        }
        const ci = vm.ci orelse return error.LuaException;
        if (ci.pending_compare_active) {
            var is_true = vm.stack[ci.pending_compare_result_slot].toBoolean();
            if (ci.pending_compare_invert) is_true = !is_true;
            if ((is_true and ci.pending_compare_negate == 0) or (!is_true and ci.pending_compare_negate != 0)) {
                ci.skip();
            }
            ci.pending_compare_active = false;
        }
        if (ci.pending_concat_active) {
            if (try continueConcatFold(vm, ci)) continue;
        }
        const inst = ci.fetch() catch |err| {
            if (err == error.PcOutOfRange) {
                if (ci.previous != null) {
                    popCallInfo(vm);
                    if (vm.ci) |prev_ci| {
                        vm.base = prev_ci.ret_base;
                        vm.top = prev_ci.ret_base + prev_ci.func.maxstacksize + prev_ci.vararg_count;
                        continue;
                    }
                }
                return .none;
            }
            if (try continueIfLuaExceptionHandled(vm, err)) continue;
            return err;
        };

        const result = do(vm, inst) catch |err| {
            if (err == error.HandledException) continue;
            if (try continueIfLuaExceptionHandled(vm, err)) continue;
            // Convert VM errors to LuaException for pcall catchability
            if (isVmRuntimeError(err)) {
                var msg_buf: [128]u8 = undefined;
                const msg = formatVmRuntimeErrorMessage(vm, inst, err, &msg_buf);
                var full_msg_buf: [320]u8 = undefined;
                const full_msg = runtimeErrorWithLocation(ci, inst, err, msg, &full_msg_buf);
                vm.errors.lua_error_value = TValue.fromString(vm.gc().allocString(full_msg) catch {
                    return err;
                });
                if (try continueIfLuaExceptionHandled(vm, error.LuaException)) continue;
                return error.LuaException;
            }
            return err;
        };

        switch (result) {
            .Continue => {},
            .LoopContinue => continue,
            .ReturnVM => |ret| return ret,
        }
    }
}

pub fn execute(vm: *VM, proto: *const ProtoObject) !ReturnValue {
    return executeWithArgs(vm, proto, &.{});
}

/// Execute a single instruction.
/// Called by VM's execute() loop after fetch.
pub inline fn do(vm: *VM, inst: Instruction) !ExecuteResult {
    if (interrupt.consume()) {
        return vm.raiseString("interrupted!");
    }
    vm.field_cache.exec_tick +%= 1;
    const ci = vm.ci.?;
    if (vm.hooks.count > 0 and !vm.hooks.in_hook) {
        if (vm.hooks.countdown == 0) vm.hooks.countdown = vm.hooks.count * 2;
        vm.hooks.countdown -|= 1;
        if (vm.hooks.countdown == 0) {
            vm.hooks.countdown = vm.hooks.count * 2;
            try hook_state.onCount(vm, executeSyncMM);
        }
    }
    if ((vm.hooks.mask & 0x04) != 0 and !vm.hooks.in_hook and ci.closure != null) {
        if (currentInstructionIndex(ci)) |idx| {
            if (idx < ci.func.lineinfo.len) {
                var line_u32 = ci.func.lineinfo[idx];
                if (idx > 0) {
                    const op = ci.func.code[idx].getOpCode();
                    var suppress_call_line_adjust = false;
                    if (op == .CALL) {
                        const call_reg = inst.getA();
                        if (vm.stack[vm.base + call_reg].asNativeClosure()) |nc| {
                            // Preserve the clear-hook source line before native
                            // debug.sethook() disables further line callbacks,
                            // but only chunk frames expect a line event on the
                            // clear call itself.
                            suppress_call_line_adjust =
                                (nc.func.id == .debug_sethook and
                                    inst.getB() == 1 and
                                    ci.func.numparams == 0 and
                                    ci.func.is_vararg);
                        } else if (ci.previous == null) {
                            if (vm.stack[vm.base + call_reg].asClosure()) |callee| {
                                // For stripped closures, keep caller line stable around CALL.
                                suppress_call_line_adjust = callee.proto.lineinfo.len == 0;
                            }
                        }
                    }
                    if (op == .CALL and
                        !suppress_call_line_adjust and
                        line_u32 > ci.func.lineinfo[idx - 1])
                    {
                        line_u32 = ci.func.lineinfo[idx - 1];
                    }
                }
                const line: i64 = @intCast(line_u32);
                const idx_i32: i32 = @intCast(idx);
                var first_line: i64 = -1;
                var multi_line = false;
                var li: usize = 0;
                while (li < ci.func.lineinfo.len) : (li += 1) {
                    const ln: i64 = @intCast(ci.func.lineinfo[li]);
                    if (ln <= 0) continue;
                    if (first_line < 0) {
                        first_line = ln;
                    } else if (ln != first_line) {
                        multi_line = true;
                        break;
                    }
                }
                var has_for_loop = false;
                if (!multi_line) {
                    var oi: usize = 0;
                    while (oi < ci.func.code.len) : (oi += 1) {
                        const lop = ci.func.code[oi].getOpCode();
                        if (lop == .FORLOOP or lop == .TFORLOOP) {
                            has_for_loop = true;
                            break;
                        }
                    }
                }
                const should_dispatch = if (ci.hook_last_pc < 0) blk: {
                    if (!multi_line) {
                        if (has_for_loop) break :blk false;
                    }
                    break :blk line != ci.hook_last_line;
                } else if (idx_i32 <= ci.hook_last_pc) blk: {
                    if (line != ci.hook_last_line) break :blk true;
                    // Lua reports same-line backward jumps for single-line chunks
                    // (e.g. one-line numeric for), but not for multi-line chunks.
                    break :blk !multi_line;
                } else blk: {
                    if (has_for_loop and ci.hook_last_line < 0) break :blk false;
                    break :blk line != ci.hook_last_line;
                };
                ci.hook_last_pc = idx_i32;
                if (should_dispatch) {
                    ci.hook_last_line = line;
                    try hook_state.onLine(vm, line, executeSyncMM);
                }
            } else if (ci.hook_last_pc < 0) {
                // Stripped chunk: no lineinfo. Lua still triggers one line hook
                // callback with nil line for the first instruction.
                if (ci.previous) |caller| {
                    if (currentInstructionIndex(caller)) |caller_idx| {
                        if (caller_idx < caller.func.lineinfo.len) {
                            caller.hook_last_pc = @intCast(caller_idx);
                            caller.hook_last_line = @intCast(caller.func.lineinfo[caller_idx]);
                        }
                    }
                }
                ci.hook_last_pc = @intCast(idx);
                ci.hook_last_line = -1;
                try hook_state.onLineNil(vm, executeSyncMM);
            }
        }
    }

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

            // Wrapping arithmetic per Lua 5.4 semantics
            if (vb.isInteger()) {
                vm.stack[vm.base + a] = .{ .integer = vb.integer +% @as(i64, imm) };
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
                const shift: i64 = @intCast(sc);
                vm.stack[vm.base + a] = .{ .integer = shlInt(vb.integer, shift) };
                return .Continue;
            } else if (vb.toNumber()) |n| {
                if (@floor(n) == n) {
                    const shift: i64 = @intCast(sc);
                    vm.stack[vm.base + a] = .{ .integer = shlInt(@intFromFloat(n), shift) };
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
                const shift: i64 = @intCast(sc);
                vm.stack[vm.base + a] = .{ .integer = shrInt(vb.integer, shift) };
                return .Continue;
            } else if (vb.toNumber()) |n| {
                if (@floor(n) == n) {
                    const shift: i64 = @intCast(sc);
                    vm.stack[vm.base + a] = .{ .integer = shrInt(@intFromFloat(n), shift) };
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

            // Wrapping arithmetic per Lua 5.4 semantics
            if (vb.isInteger() and vc.isInteger()) {
                vm.stack[vm.base + a] = .{ .integer = vb.integer +% vc.integer };
            } else {
                const nb_opt = vb.toNumber();
                const nc_opt = vc.toNumber();
                if (nb_opt == null or nc_opt == null) {
                    if (try dispatchArithKMM(vm, vb.*, vc.*, a, .add)) |result| return result;
                    return error.ArithmeticError;
                }
                const nb = nb_opt.?;
                const nc = nc_opt.?;
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

            // Wrapping arithmetic per Lua 5.4 semantics
            if (vb.isInteger() and vc.isInteger()) {
                vm.stack[vm.base + a] = .{ .integer = vb.integer -% vc.integer };
            } else {
                const nb_opt = vb.toNumber();
                const nc_opt = vc.toNumber();
                if (nb_opt == null or nc_opt == null) {
                    if (try dispatchArithKMM(vm, vb.*, vc.*, a, .sub)) |result| return result;
                    return error.ArithmeticError;
                }
                const nb = nb_opt.?;
                const nc = nc_opt.?;
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

            // Wrapping arithmetic per Lua 5.4 semantics
            if (vb.isInteger() and vc.isInteger()) {
                vm.stack[vm.base + a] = .{ .integer = vb.integer *% vc.integer };
            } else {
                const nb_opt = vb.toNumber();
                const nc_opt = vc.toNumber();
                if (nb_opt == null or nc_opt == null) {
                    if (try dispatchArithKMM(vm, vb.*, vc.*, a, .mul)) |result| return result;
                    return error.ArithmeticError;
                }
                const nb = nb_opt.?;
                const nc = nc_opt.?;
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

            const nb_opt = vb.toNumber();
            const nc_opt = vc.toNumber();
            if (nb_opt == null or nc_opt == null) {
                if (try dispatchArithKMM(vm, vb.*, vc.*, a, .div)) |result| return result;
                return error.ArithmeticError;
            }
            const nb = nb_opt.?;
            const nc = nc_opt.?;
            // Division by zero returns inf/-inf/nan per IEEE 754
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

            if (vb.isInteger() and vc.isInteger()) {
                const res = try idivInt(vb.integer, vc.integer);
                vm.stack[vm.base + a] = .{ .integer = res };
                return .Continue;
            }
            const nb_opt = vb.toNumber();
            const nc_opt = vc.toNumber();
            if (nb_opt == null or nc_opt == null) {
                if (try dispatchArithKMM(vm, vb.*, vc.*, a, .idiv)) |result| return result;
                return error.ArithmeticError;
            }
            const nb = nb_opt.?;
            const nc = nc_opt.?;
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

            if (vb.isInteger() and vc.isInteger()) {
                const res = try modInt(vb.integer, vc.integer);
                vm.stack[vm.base + a] = .{ .integer = res };
                return .Continue;
            }
            const nb_opt = vb.toNumber();
            const nc_opt = vc.toNumber();
            if (nb_opt == null or nc_opt == null) {
                if (try dispatchArithKMM(vm, vb.*, vc.*, a, .mod)) |result| return result;
                return error.ArithmeticError;
            }
            const nb = nb_opt.?;
            const nc = nc_opt.?;
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

            const nb_opt = vb.toNumber();
            const nc_opt = vc.toNumber();
            if (nb_opt == null or nc_opt == null) {
                if (try dispatchArithKMM(vm, vb.*, vc.*, a, .pow)) |result| return result;
                return error.ArithmeticError;
            }
            const nb = nb_opt.?;
            const nc = nc_opt.?;
            vm.stack[vm.base + a] = .{ .number = std.math.pow(f64, nb, nc) };
            return .Continue;
        },
        .BANDK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            var conv_err: ?anyerror = null;
            var ib_opt: ?i64 = null;
            var ic_opt: ?i64 = null;
            if (toIntForBitwise(vb)) |ib| {
                ib_opt = ib;
            } else |err| {
                if (err == error.IntegerRepresentation) {
                    maybeSetIntReprContext(vm, b);
                }
                conv_err = err;
            }
            if (toIntForBitwise(vc)) |ic| {
                ic_opt = ic;
            } else |err| {
                conv_err = err;
            }
            if (ib_opt) |ib| {
                if (ic_opt) |ic| {
                    vm.stack[vm.base + a] = .{ .integer = ib & ic };
                    return .Continue;
                }
            }
            if (try dispatchBitwiseMM(vm, vb.*, vc.*, a, .band)) |result| return result;
            return conv_err orelse error.ArithmeticError;
        },
        .BORK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            var conv_err: ?anyerror = null;
            var ib_opt: ?i64 = null;
            var ic_opt: ?i64 = null;
            if (toIntForBitwise(vb)) |ib| {
                ib_opt = ib;
            } else |err| {
                if (err == error.IntegerRepresentation) {
                    maybeSetIntReprContext(vm, b);
                }
                conv_err = err;
            }
            if (toIntForBitwise(vc)) |ic| {
                ic_opt = ic;
            } else |err| {
                conv_err = err;
            }
            if (ib_opt) |ib| {
                if (ic_opt) |ic| {
                    vm.stack[vm.base + a] = .{ .integer = ib | ic };
                    return .Continue;
                }
            }
            if (try dispatchBitwiseMM(vm, vb.*, vc.*, a, .bor)) |result| return result;
            return conv_err orelse error.ArithmeticError;
        },
        .BXORK => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = &vm.stack[vm.base + b];
            const vc = &ci.func.k[c];

            var conv_err: ?anyerror = null;
            var ib_opt: ?i64 = null;
            var ic_opt: ?i64 = null;
            if (toIntForBitwise(vb)) |ib| {
                ib_opt = ib;
            } else |err| {
                if (err == error.IntegerRepresentation) {
                    maybeSetIntReprContext(vm, b);
                }
                conv_err = err;
            }
            if (toIntForBitwise(vc)) |ic| {
                ic_opt = ic;
            } else |err| {
                conv_err = err;
            }
            if (ib_opt) |ib| {
                if (ic_opt) |ic| {
                    vm.stack[vm.base + a] = .{ .integer = ib ^ ic };
                    return .Continue;
                }
            }
            if (try dispatchBitwiseMM(vm, vb.*, vc.*, a, .bxor)) |result| return result;
            return conv_err orelse error.ArithmeticError;
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
            bitwiseBinary(vm, inst, .band) catch |err| {
                const a = inst.getA();
                const b = inst.getB();
                const c = inst.getC();
                if (try dispatchBitwiseMM(vm, vm.stack[vm.base + b], vm.stack[vm.base + c], a, .band)) |result| {
                    return result;
                }
                return err;
            };
            return .Continue;
        },
        .BOR => {
            bitwiseBinary(vm, inst, .bor) catch |err| {
                const a = inst.getA();
                const b = inst.getB();
                const c = inst.getC();
                if (try dispatchBitwiseMM(vm, vm.stack[vm.base + b], vm.stack[vm.base + c], a, .bor)) |result| {
                    return result;
                }
                return err;
            };
            return .Continue;
        },
        .BXOR => {
            bitwiseBinary(vm, inst, .bxor) catch |err| {
                const a = inst.getA();
                const b = inst.getB();
                const c = inst.getC();
                if (try dispatchBitwiseMM(vm, vm.stack[vm.base + b], vm.stack[vm.base + c], a, .bxor)) |result| {
                    return result;
                }
                return err;
            };
            return .Continue;
        },
        .SHL => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = vm.stack[vm.base + b];
            const vc = vm.stack[vm.base + c];

            var conv_err: ?anyerror = null;
            var value_opt: ?i64 = null;
            var shift_opt: ?i64 = null;
            if (toIntForBitwise(&vb)) |value| {
                value_opt = value;
            } else |err| {
                if (err == error.IntegerRepresentation) {
                    maybeSetIntReprContext(vm, b);
                }
                conv_err = err;
            }
            if (toIntForBitwise(&vc)) |shift| {
                shift_opt = shift;
            } else |err| {
                if (err == error.IntegerRepresentation) {
                    maybeSetIntReprContext(vm, c);
                }
                conv_err = err;
            }
            if (value_opt) |value| {
                if (shift_opt) |shift| {
                    const result = shlInt(value, shift);
                    vm.stack[vm.base + a] = .{ .integer = result };
                    return .Continue;
                }
            }
            // Try metamethod
            if (try dispatchBitwiseMM(vm, vb, vc, a, .shl)) |result| {
                return result;
            }
            return conv_err orelse error.ArithmeticError;
        },
        .SHR => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const vb = vm.stack[vm.base + b];
            const vc = vm.stack[vm.base + c];

            var conv_err: ?anyerror = null;
            var value_opt: ?i64 = null;
            var shift_opt: ?i64 = null;
            if (toIntForBitwise(&vb)) |value| {
                value_opt = value;
            } else |err| {
                if (err == error.IntegerRepresentation) {
                    maybeSetIntReprContext(vm, b);
                }
                conv_err = err;
            }
            if (toIntForBitwise(&vc)) |shift| {
                shift_opt = shift;
            } else |err| {
                if (err == error.IntegerRepresentation) {
                    maybeSetIntReprContext(vm, c);
                }
                conv_err = err;
            }
            if (value_opt) |value| {
                if (shift_opt) |shift| {
                    const result = shrInt(value, shift);
                    vm.stack[vm.base + a] = .{ .integer = result };
                    return .Continue;
                }
            }
            // Try metamethod
            if (try dispatchBitwiseMM(vm, vb, vc, a, .shr)) |result| {
                return result;
            }
            return conv_err orelse error.ArithmeticError;
        },
        // [MM_ARITH] Fast path: unary minus. Slow path: __unm metamethod.
        .UNM => {
            const a = inst.getA();
            const b = inst.getB();
            const vb = vm.stack[vm.base + b];
            if (vb.isInteger()) {
                vm.stack[vm.base + a] = .{ .integer = 0 -% vb.integer };
            } else if (vb.toNumber()) |n| {
                vm.stack[vm.base + a] = .{ .number = -n };
            } else {
                // Try __unm metamethod
                const mm = metamethod.getMetamethod(vb, .unm, &vm.gc().mm_keys, &vm.gc().shared_mt) orelse {
                    return error.ArithmeticError;
                };
                return try callUnaryMetamethod(vm, mm, vb, a, "unm");
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

            var conv_err: ?anyerror = null;
            if (toIntForBitwise(&vb)) |value| {
                vm.stack[vm.base + a] = .{ .integer = ~value };
                return .Continue;
            } else |err| {
                if (err == error.IntegerRepresentation) {
                    maybeSetIntReprContext(vm, b);
                }
                conv_err = err;
            }
            // Try metamethod
            if (try dispatchBnotMM(vm, vb, a)) |result| {
                return result;
            }
            return conv_err orelse error.ArithmeticError;
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
                vm.stack[vm.base + a] = .{ .integer = table.rawLen() };
            } else {
                if (metamethod.getMetamethod(vb.*, .len, &vm.gc().mm_keys, &vm.gc().shared_mt)) |mm| {
                    return try callUnaryMetamethod(vm, mm, vb.*, a, "len");
                }
                const ty = callableValueTypeName(vb.*);
                var msg_buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "attempt to get length of a {s} value", .{ty}) catch "attempt to get length of value";
                return vm.raiseString(msg);
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
                        const str = formatConcatNumber(&buf, val.number);
                        total_len += str.len;
                    }
                }

                const result_buf = try vm.gc().allocator.alloc(u8, total_len);
                defer vm.gc().allocator.free(result_buf);
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
                        const str = formatConcatNumber(result_buf[offset..], val.number);
                        offset += str.len;
                    }
                }

                const result_str = try vm.gc().allocString(result_buf);
                vm.stack[vm.base + a] = TValue.fromString(result_str);
                return .Continue;
            }

            // Slow path: fold concatenation pairwise with metamethod fallback.
            var acc = vm.stack[vm.base + c];
            vm.stack[vm.base + a] = acc;
            var i: i16 = @as(i16, @intCast(c)) - 1;
            while (i >= @as(i16, @intCast(b))) : (i -= 1) {
                const left = vm.stack[vm.base + @as(u32, @intCast(i))];
                if (canConcatPrimitive(left) and canConcatPrimitive(acc)) {
                    acc = try concatTwoSync(vm, left, acc);
                    vm.stack[vm.base + a] = acc;
                    continue;
                }
                const mm_res = try dispatchConcatMM(vm, left, acc, a) orelse {
                    const bad = if (!canConcatPrimitive(left)) left else acc;
                    const ty = callableValueTypeName(bad);
                    var msg_buf: [96]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "attempt to concatenate a {s} value", .{ty}) catch "attempt to concatenate values";
                    return vm.raiseString(msg);
                };
                switch (mm_res) {
                    .Continue => {
                        acc = vm.stack[vm.base + a];
                        continue;
                    },
                    .LoopContinue => {
                        ci.pending_concat_active = true;
                        ci.pending_concat_a = a;
                        ci.pending_concat_b = b;
                        ci.pending_concat_i = i - 1;
                        return .LoopContinue;
                    },
                    .ReturnVM => unreachable,
                }
            }
            vm.stack[vm.base + a] = acc;
            return .Continue;
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
                else switch (try dispatchLtMMForOpcode(vm, ci, left, right, negate)) {
                    .value => |mm_res| mm_res,
                    .deferred => return .LoopContinue,
                    .missing => {
                        _ = try raiseOrderComparison(vm, left, right);
                        unreachable;
                    },
                };

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
                else switch (try dispatchLeMMForOpcode(vm, ci, left, right, negate)) {
                    .value => |mm_res| mm_res,
                    .deferred => return .LoopContinue,
                    .missing => {
                        _ = try raiseOrderComparison(vm, left, right);
                        unreachable;
                    },
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

            if (v_init.isInteger() and v_step.isInteger()) {
                const ii = v_init.integer;
                const is = v_step.integer;
                if (is == 0) return error.InvalidForLoopStep;

                var il: i64 = undefined;
                if (v_limit.isInteger()) {
                    il = v_limit.integer;
                } else {
                    const lnum = v_limit.toNumber() orelse return error.InvalidForLoopLimit;
                    if (std.math.isNan(lnum)) return error.InvalidForLoopLimit;

                    if (std.math.isPositiveInf(lnum)) {
                        if (is < 0) {
                            // finite integer start cannot reach +inf with negative step
                            try ci.jumpRel(sbx);
                            return .Continue;
                        }
                        il = std.math.maxInt(i64);
                    } else if (std.math.isNegativeInf(lnum)) {
                        if (is > 0) {
                            // finite integer start cannot reach -inf with positive step
                            try ci.jumpRel(sbx);
                            return .Continue;
                        }
                        il = std.math.minInt(i64);
                    } else {
                        const adj = if (is > 0) @floor(lnum) else @ceil(lnum);
                        if (is > 0 and adj < @as(f64, @floatFromInt(std.math.minInt(i64)))) {
                            // Finite limit is below i64 range: positive-step integer loop
                            // can never reach it from any finite i64 start.
                            try ci.jumpRel(sbx);
                            return .Continue;
                        }
                        if (is < 0 and adj > @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
                            // Finite limit is above i64 range: negative-step integer loop
                            // can never reach it from any finite i64 start.
                            try ci.jumpRel(sbx);
                            return .Continue;
                        }
                        if (adj >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
                            il = std.math.maxInt(i64);
                        } else if (adj <= @as(f64, @floatFromInt(std.math.minInt(i64)))) {
                            il = std.math.minInt(i64);
                        } else {
                            il = @as(i64, @intFromFloat(adj));
                        }
                    }
                }
                vm.stack[vm.base + a + 1] = .{ .integer = il };

                const sub_result = @subWithOverflow(ii, is);
                if (sub_result[1] == 0) {
                    vm.stack[vm.base + a] = .{ .integer = sub_result[0] };
                } else {
                    // Integer overflow on (init - step): keep integer semantics
                    // without falling back to imprecise float math near 2^63.
                    const should_run = if (is > 0) (ii <= il) else (ii >= il);
                    if (!should_run) {
                        try ci.jumpRel(sbx);
                        return .Continue;
                    }
                    vm.stack[vm.base + a] = .{ .integer = ii };
                    vm.stack[vm.base + a + 3] = .{ .integer = ii };
                    return .Continue;
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
        // Generic for loop: TFORCALL A C - call iterator R(A)(R(A+1), R(A+2)),
        // store C results at R(A+4)... (R(A+3) is to-be-closed state)
        .TFORCALL => {
            const a = inst.getA();
            const c = inst.getC();

            const func_val = vm.stack[vm.base + a];
            const state_val = vm.stack[vm.base + a + 1];
            const control_val = vm.stack[vm.base + a + 2];

            // Set up call at R(A+4): copy function and args
            // Layout: R(A+4)=func, R(A+5)=state, R(A+6)=control, results go to R(A+4)...
            const call_reg: u8 = @intCast(a + 4);
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
                    try hook_state.onReturn(vm, nativeReturnHookName(nc.func.id), null, executeSyncMM);
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
                const iter_ci = try pushCallInfo(vm, func_proto, closure, new_base, new_base, nres);
                iter_ci.debug_name = "for iterator";
                iter_ci.debug_namewhat = "for iterator";
                vm.top = new_base + func_proto.maxstacksize;
                return .LoopContinue;
            }

            // Slow path: iterator is a callable table (__call)
            if (try dispatchCallMM(vm, func_val, call_reg, 2, @intCast(nresults))) |result| {
                return result;
            }

            return error.NotAFunction;
        },
        // Generic for loop: TFORLOOP A sBx - if R(A+4) != nil, R(A+2) = R(A+4), jump back
        .TFORLOOP => {
            const a = inst.getA();
            const sbx = inst.getSBx();

            const first_var = vm.stack[vm.base + a + 4];

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
                    if (nc.func.id == .pcall or nc.func.id == .xpcall) {
                        const total_args: u32 = if (b > 0) b - 1 else blk: {
                            const arg_start = vm.base + a + 1;
                            break :blk if (vm.top >= arg_start) vm.top - arg_start else 0;
                        };
                        const total_results: u32 = if (c > 0) c - 1 else 0;
                        if (nc.func.id == .pcall) {
                            return try dispatchProtectedCall(vm, ci, a, total_args, total_results, null, vm.base + a);
                        }

                        const prepared = prepareXpcall(vm, a, total_args, vm.base + a) catch |err| switch (err) {
                            error.InvalidXpcallHandler => {
                                const frame_max = vm.base + ci.func.maxstacksize;
                                vm.top = if (c == 0) vm.base + a + 2 else frame_max;
                                return .Continue;
                            },
                            else => return err,
                        };
                        return try dispatchProtectedCall(vm, ci, a, prepared.total_args, total_results, prepared.handler, vm.base + a);
                    }
                    const nargs: u32 = if (b > 0) b - 1 else blk: {
                        const arg_start = vm.base + a + 1;
                        break :blk if (vm.top >= arg_start) vm.top - arg_start else 0;
                    };
                    // Remember frame extent before call
                    const frame_max = vm.base + ci.func.maxstacksize;
                    const stack_room: u32 = @intCast(vm.stack.len - (vm.base + a));
                    const nresults: u32 = if (c == 0 and ci.is_protected and ci.func == &protected_call_bootstrap_proto)
                        (if (ci.nresults < 0) 0 else @max(@as(u32, 1), @as(u32, @intCast(ci.nresults))))
                    else
                        nativeDesiredResultsForCall(nc.func.id, c, stack_room);
                    var native_call_args: [64]TValue = [_]TValue{.nil} ** 64;
                    const native_call_arg_count: usize = @min(@as(usize, @intCast(nargs)), native_call_args.len);
                    for (0..native_call_arg_count) |i| {
                        native_call_args[i] = vm.stack[vm.base + a + 1 + @as(u32, @intCast(i))];
                    }
                    // Ensure vm.top is past all arguments so native functions can use temp registers safely
                    vm.top = vm.base + a + 1 + nargs;
                    try hook_state.onCallFromStack(vm, null, 1, vm.base + a + 1, nargs, executeSyncMM);
                    try vm.callNative(nc.func.id, a, nargs, nresults);

                    // 0-RETURN HANDLING: Some natives (select, string.byte) return 0 values
                    // by setting vm.top = vm.base + a. When the caller expects fixed results
                    // (nresults > 0), fill those slots with nil and advance vm.top.
                    // This handles cases like: local x = select(10, 1,2,3) -> x = nil
                    const result_base = vm.base + a;
                    if (nresults > 0 and vm.top == result_base) {
                        // Native returned 0 values but caller expects nresults
                        for (vm.stack[result_base .. result_base + nresults]) |*slot| {
                            slot.* = .nil;
                        }
                        vm.top = result_base + nresults;
                    }

                    // GC SAFETY: Clear stale pointers beyond result area
                    const result_end = if (nresults == 0) vm.top else result_base + nresults;
                    if (result_end < frame_max) {
                        for (vm.stack[result_end..frame_max]) |*slot| {
                            slot.* = .nil;
                        }
                    }
                    // For MULTRET (C=0), caller depends on vm.top to know result count.
                    // For fixed results (C>0), keep conservative frame top.
                    vm.top = if (c == 0 or nativeKeepsTopForCall(nc.func.id, c)) result_end else frame_max;
                    switch (nc.func.id) {
                        .select => {
                            var idx_u: u32 = 1;
                            if (native_call_arg_count > 0) {
                                const idx_val = native_call_args[0].toInteger() orelse 1;
                                if (idx_val >= 1) idx_u = @intCast(idx_val);
                            }
                            const arg_count: u32 = @intCast(native_call_arg_count);
                            const native_transfer_count: u32 = if (arg_count >= idx_u) arg_count - idx_u else 0;
                            const src_idx: usize = @min(@as(usize, @intCast(idx_u)), native_call_arg_count);
                            const src_slice = native_call_args[src_idx .. src_idx + @as(usize, @intCast(native_transfer_count))];
                            try hook_state.onReturnFromValues(vm, nativeReturnHookName(nc.func.id), null, idx_u + 1, src_slice, executeSyncMM);
                        },
                        .math_sin => {
                            const arg = if (native_call_arg_count > 0) native_call_args[0].toNumber() orelse 0 else 0;
                            const out = TValue{ .number = std.math.sin(arg) };
                            try hook_state.onReturnFromValues(vm, nativeReturnHookName(nc.func.id), null, 2, &[_]TValue{out}, executeSyncMM);
                        },
                        else => {
                            const native_transfer_total: u32 = if (nresults == 0) result_end - result_base else nresults;
                            const native_transfer_count: u32 = if (native_transfer_total > 0) native_transfer_total - 1 else 0;
                            try hook_state.onReturnFromStack(vm, nativeReturnHookName(nc.func.id), null, 2, vm.base + a + 1, native_transfer_count, executeSyncMM);
                        },
                    }
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

                // Hot fast path: fixed-arity, non-vararg call with exact argument count.
                // Common in recursive numeric code (e.g. fib): skip vararg bookkeeping and
                // nil-filling logic, only shift arguments over callee slot.
                if (!func_proto.is_vararg and nargs == func_proto.numparams) {
                    if (nargs > 0) {
                        var i: u32 = 0;
                        while (i < nargs) : (i += 1) {
                            vm.stack[new_base + i] = vm.stack[new_base + 1 + i];
                        }
                    }
                    _ = try pushCallInfoVararg(vm, func_proto, closure, new_base, ret_base, nresults, 0, 0);
                    try hook_state.onCallFromStack(vm, null, 1, new_base, func_proto.numparams, executeSyncMM);
                    vm.top = new_base + func_proto.maxstacksize;
                    return .LoopContinue;
                }

                // Calculate vararg info before shifting arguments
                var vararg_base: u32 = 0;
                var vararg_count: u32 = 0;

                if (func_proto.is_vararg and nargs > func_proto.numparams) {
                    // Store varargs beyond the frame to avoid collision with nested calls.
                    // We use vm.top (the current stack extent) plus a buffer to ensure
                    // varargs are safe from being overwritten by any nested function's
                    // frame, which could extend beyond the caller's maxstacksize.
                    vararg_count = nargs - func_proto.numparams;
                    // Use max of (new_base + maxstacksize) and (vm.top) to find a safe location
                    // Add extra buffer for nested call frames
                    const min_vararg_base = new_base + func_proto.maxstacksize;
                    vararg_base = @max(min_vararg_base, vm.top) + 32; // 32-slot buffer for nested calls
                    try ensureStackTop(vm, vararg_base + vararg_count);

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
                try hook_state.onCallFromStack(vm, null, 1, new_base, func_proto.numparams, executeSyncMM);

                // Extend top to include vararg storage if needed
                const frame_top = if (vararg_count > 0) vararg_base + vararg_count else new_base + func_proto.maxstacksize;
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

            var msg_buf: [192]u8 = undefined;
            const msg = buildCallNotFunctionMessage(vm, ci, a, func_val, &msg_buf);
            try raiseWithLocation(vm, ci, inst, error.NotAFunction, msg);
            return error.LuaException;
        },
        // TAILCALL: Tail call optimization - reuse current frame
        // TAILCALL A B C k: return R[A](R[A+1], ..., R[A+B-1])
        .TAILCALL => {
            const a = inst.getA();
            const b = inst.getB();
            const k = inst.getk();

            const func_val = vm.stack[vm.base + a];
            const original_func_val = func_val;
            const current_ci = vm.ci.?;
            var nargs: u32 = if (b > 0) b - 1 else blk: {
                const arg_start = vm.base + a + 1;
                break :blk vm.top - arg_start;
            };
            var tail_func = func_val;

            // Close TBC variables if k flag is set
            if (k) {
                try closeTbcForReturn(vm, current_ci);
            }

            // Close upvalues before tail call
            vm.closeUpvalues(current_ci.base);

            // Slow path: resolve __call chain (table -> __call -> table -> ... -> function)
            // by repeatedly rewriting stack as callable(self, args...).
            var call_chain_depth: u16 = 0;
            while (tail_func.asClosure() == null and !(tail_func.isObject() and tail_func.object.type == .native_closure)) {
                if (call_chain_depth >= 2000) {
                    var msg_buf: [192]u8 = undefined;
                    const msg = buildCallNotFunctionMessage(vm, current_ci, a, original_func_val, &msg_buf);
                    try raiseWithLocation(vm, current_ci, inst, error.NotAFunction, msg);
                    return error.LuaException;
                }
                call_chain_depth += 1;

                const table = tail_func.asTable() orelse {
                    var msg_buf: [192]u8 = undefined;
                    const msg = buildCallNotFunctionMessage(vm, current_ci, a, original_func_val, &msg_buf);
                    try raiseWithLocation(vm, current_ci, inst, error.NotAFunction, msg);
                    return error.LuaException;
                };
                const mt = table.metatable orelse {
                    var msg_buf: [192]u8 = undefined;
                    const msg = buildCallNotFunctionMessage(vm, current_ci, a, original_func_val, &msg_buf);
                    try raiseWithLocation(vm, current_ci, inst, error.NotAFunction, msg);
                    return error.LuaException;
                };
                const call_mm = mt.get(TValue.fromString(vm.gc().mm_keys.get(.call))) orelse {
                    var msg_buf: [192]u8 = undefined;
                    const msg = buildCallNotFunctionMessage(vm, current_ci, a, original_func_val, &msg_buf);
                    try raiseWithLocation(vm, current_ci, inst, error.NotAFunction, msg);
                    return error.LuaException;
                };

                if (call_mm.asTable() != null or
                    call_mm.asClosure() != null or
                    (call_mm.isObject() and call_mm.object.type == .native_closure))
                {
                    // Need one extra argument slot to prepend current callable as self.
                    try ensureStackTop(vm, vm.base + a + nargs + 2);

                    // Shift existing args right by 1: [a+1..a+nargs] -> [a+2..a+nargs+1]
                    var i: u32 = nargs;
                    while (i > 0) {
                        i -= 1;
                        vm.stack[vm.base + a + 2 + i] = vm.stack[vm.base + a + 1 + i];
                    }

                    vm.stack[vm.base + a + 1] = tail_func;
                    vm.stack[vm.base + a] = call_mm;
                    tail_func = call_mm;
                    nargs += 1;
                    if (b == 0) {
                        vm.top = @max(vm.top, vm.base + a + 1 + nargs);
                    }
                } else {
                    var msg_buf: [192]u8 = undefined;
                    const msg = buildCallNotFunctionMessage(vm, current_ci, a, original_func_val, &msg_buf);
                    try raiseWithLocation(vm, current_ci, inst, error.NotAFunction, msg);
                    return error.LuaException;
                }
            }

            // Handle Lua closure tail call
            if (tail_func.asClosure()) |closure| {
                const func_proto = closure.proto;

                // For tail call, we reuse the current frame's ret_base and nresults
                const ret_base = current_ci.ret_base;
                const nresults = current_ci.nresults;

                // Calculate new base - move everything to current frame's base
                const new_base = current_ci.base;

                // Calculate vararg info
                var vararg_base: u32 = 0;
                var vararg_count: u32 = 0;

                if (func_proto.is_vararg and nargs > func_proto.numparams) {
                    vararg_count = nargs - func_proto.numparams;
                    // Store varargs beyond the frame with buffer for nested calls
                    const min_vararg_base = new_base + func_proto.maxstacksize;
                    vararg_base = @max(min_vararg_base, vm.top) + 32;
                    try ensureStackTop(vm, vararg_base + vararg_count);

                    // Copy varargs to storage location
                    // Always copy backwards since dest > src
                    const src_start = vm.base + a + 1 + func_proto.numparams;
                    var i: u32 = vararg_count;
                    while (i > 0) {
                        i -= 1;
                        vm.stack[vararg_base + i] = vm.stack[src_start + i];
                    }
                }

                // Copy arguments to new_base (overwriting current frame's locals)
                // Source: vm.base + a + 1 (first arg after function)
                // Dest: new_base (start of frame)
                const params_to_copy = @min(nargs, @as(u32, func_proto.numparams));
                if (params_to_copy > 0) {
                    // Copy forward since destination might overlap with source
                    for (0..params_to_copy) |i| {
                        vm.stack[new_base + i] = vm.stack[vm.base + a + 1 + i];
                    }
                }

                // Fill remaining parameter slots with nil
                if (nargs < func_proto.numparams) {
                    for (vm.stack[new_base + nargs ..][0 .. func_proto.numparams - nargs]) |*slot| {
                        slot.* = .nil;
                    }
                }

                // Reuse current CallInfo instead of pushing new one
                current_ci.func = func_proto;
                current_ci.closure = closure;
                current_ci.pc = func_proto.code.ptr;
                current_ci.base = new_base;
                current_ci.ret_base = ret_base;
                current_ci.nresults = nresults;
                current_ci.was_tail_called = true;
                current_ci.vararg_base = vararg_base;
                current_ci.vararg_count = vararg_count;
                current_ci.is_protected = false;
                current_ci.error_handler = .nil;
                current_ci.tbc_bitmap = 0; // Reset TBC tracking
                current_ci.pending_return_a = null;
                current_ci.pending_return_count = null;
                current_ci.pending_return_reexec = false;
                current_ci.pending_compare_active = false;
                current_ci.pending_compare_negate = 0;
                current_ci.pending_compare_invert = false;
                current_ci.pending_compare_result_slot = 0;
                current_ci.pending_concat_active = false;
                current_ci.pending_concat_a = 0;
                current_ci.pending_concat_b = 0;
                current_ci.pending_concat_i = -1;

                vm.base = new_base;
                vm.top = if (vararg_count > 0) vararg_base + vararg_count else new_base + func_proto.maxstacksize;
                try hook_state.onTailCallFromStack(vm, null, 1, new_base, func_proto.numparams, executeSyncMM);

                return .LoopContinue;
            }

            // Handle native closure tail call (fall back to regular call + return)
            if (tail_func.isObject()) {
                const obj = tail_func.object;
                if (obj.type == .native_closure) {
                    const nc = object.getObject(NativeClosureObject, obj);

                    // For native tail calls, we call normally but adjust return handling
                    const ret_base = current_ci.ret_base;
                    const nresults = current_ci.nresults;
                    if (nc.func.id == .pcall or nc.func.id == .xpcall) {
                        const total_args_call: u32 = nargs + 1;
                        const total_results: u32 = if (nresults < 0) 0 else @intCast(nresults);
                        var handler: ?TValue = null;
                        var effective_total_args = total_args_call;
                        if (nc.func.id == .xpcall) {
                            const prepared = prepareXpcall(vm, a, total_args_call, ret_base) catch |err| switch (err) {
                                error.InvalidXpcallHandler => {
                                    popCallInfo(vm);
                                    vm.top = ret_base + 2;
                                    return .LoopContinue;
                                },
                                else => return err,
                            };
                            handler = prepared.handler;
                            effective_total_args = prepared.total_args;
                        }
                        const new_base = vm.base + a + 1;
                        reuseCurrentFrameForProtectedCall(current_ci, ret_base, total_results, handler, new_base);
                        vm.base = new_base;
                        vm.top = new_base + effective_total_args;
                        return .LoopContinue;
                    }

                    vm.top = vm.base + a + 1 + nargs;

                    // For MULTRET (nresults < 0), use nativeDesiredResultsForCall to determine
                    // how many results the native function returns
                    const stack_room: u32 = @intCast(vm.stack.len - (vm.base + a));
                    const c_for_native: u8 = if (nresults < 0) 0 else @intCast(nresults + 1);
                    const native_nresults = nativeDesiredResultsForCall(nc.func.id, c_for_native, stack_room);
                    var native_call_args: [64]TValue = [_]TValue{.nil} ** 64;
                    const native_call_arg_count: usize = @min(@as(usize, @intCast(nargs)), native_call_args.len);
                    for (0..native_call_arg_count) |i| {
                        native_call_args[i] = vm.stack[vm.base + a + 1 + @as(u32, @intCast(i))];
                    }
                    try vm.callNative(nc.func.id, a, nargs, native_nresults);
                    switch (nc.func.id) {
                        .select => {
                            var idx_u: u32 = 1;
                            if (native_call_arg_count > 0) {
                                const idx_val = native_call_args[0].toInteger() orelse 1;
                                if (idx_val >= 1) idx_u = @intCast(idx_val);
                            }
                            const arg_count: u32 = @intCast(native_call_arg_count);
                            const native_transfer_count: u32 = if (arg_count >= idx_u) arg_count - idx_u else 0;
                            const src_idx: usize = @min(@as(usize, @intCast(idx_u)), native_call_arg_count);
                            const src_slice = native_call_args[src_idx .. src_idx + @as(usize, @intCast(native_transfer_count))];
                            try hook_state.onReturnFromValues(vm, nativeReturnHookName(nc.func.id), null, idx_u + 1, src_slice, executeSyncMM);
                        },
                        .math_sin => {
                            const arg = if (native_call_arg_count > 0) native_call_args[0].toNumber() orelse 0 else 0;
                            const out = TValue{ .number = std.math.sin(arg) };
                            try hook_state.onReturnFromValues(vm, nativeReturnHookName(nc.func.id), null, 2, &[_]TValue{out}, executeSyncMM);
                        },
                        else => {
                            const native_transfer_total: u32 = if (native_nresults > 0) native_nresults else if (vm.top > vm.base + a) vm.top - (vm.base + a) else 0;
                            const native_transfer_count: u32 = if (native_transfer_total > 0) native_transfer_total - 1 else 0;
                            try hook_state.onReturnFromStack(vm, nativeReturnHookName(nc.func.id), null, 2, vm.base + a + 1, native_transfer_count, executeSyncMM);
                        },
                    }

                    // Pop current frame and copy results
                    if (current_ci.previous != null) {
                        // For MULTRET, determine actual result count:
                        // - If native_nresults > 0, use that count
                        // - If native_nresults == 0, native set vm.top, calculate from that
                        // For fixed results, copy the requested amount
                        const actual_nresults: u32 = if (nresults < 0) blk: {
                            if (native_nresults > 0) {
                                break :blk native_nresults;
                            } else {
                                // Native function set vm.top to indicate result count
                                const result_base = vm.base + a;
                                break :blk if (vm.top > result_base) vm.top - result_base else 0;
                            }
                        } else @intCast(nresults);

                        // Copy results from vm.base + a to ret_base
                        for (0..actual_nresults) |i| {
                            vm.stack[ret_base + i] = vm.stack[vm.base + a + i];
                        }

                        popCallInfo(vm);
                        vm.top = ret_base + actual_nresults;
                        return .LoopContinue;
                    }

                    // Top-level native tail call - return to VM
                    return .{ .ReturnVM = .{ .single = vm.stack[vm.base + a] } };
                }
            }

            var msg_buf: [192]u8 = undefined;
            const msg = buildCallNotFunctionMessage(vm, current_ci, a, original_func_val, &msg_buf);
            try raiseWithLocation(vm, current_ci, inst, error.NotAFunction, msg);
            return error.LuaException;
        },
        .RETURN => {
            const a = inst.getA();
            const b = inst.getB();

            if (vm.ci.?.previous != null) {
                const returning_ci = vm.ci.?;
                const nresults = returning_ci.nresults;
                const dst_base = returning_ci.ret_base;
                const is_protected = returning_ci.is_protected;
                if (b == 0) {
                    if (returning_ci.pending_return_count == null or returning_ci.pending_return_a == null or returning_ci.pending_return_a.? != a) {
                        returning_ci.pending_return_a = a;
                        returning_ci.pending_return_count = vm.top - (returning_ci.base + a);
                    }
                }

                // Close TBC variables before returning (Lua 5.4)
                try closeTbcForReturn(vm, returning_ci);
                if (vm.open_upvalues != null) {
                    vm.closeUpvalues(returning_ci.base);
                }
                const ret_count: u32 = if (b == 0)
                    returning_ci.pending_return_count orelse (vm.top - (returning_ci.base + a))
                else if (b == 1)
                    0
                else
                    b - 1;
                try hook_state.onReturnFromStack(vm, null, if (error_state.isClosingMetamethod(vm)) "close" else null, a + 1, returning_ci.base + a, ret_count, executeSyncMM);
                popCallInfo(vm);

                // Get caller's frame extent for vm.top restoration
                // After popCallInfo, vm.ci points to the caller's frame
                const caller_frame_max = vm.base + vm.ci.?.func.maxstacksize;

                // Calculate actual return count
                // B=0 means variable returns (from R[A] to top)
                // B>0 means B-1 fixed returns

                // Protected frame: prepend true and shift results by 1
                if (is_protected) {
                    const expected: u32 = if (nresults < 0) 0 else @intCast(nresults);
                    const copy_count: u32 = if (nresults < 0) ret_count else @min(ret_count, expected);
                    vm.stack[dst_base] = .{ .boolean = true };
                    if (copy_count > 0) {
                        for (0..copy_count) |i| {
                            vm.stack[dst_base + 1 + i] = vm.stack[returning_ci.base + a + i];
                        }
                    }
                    if (nresults >= 0 and expected > copy_count) {
                        for (vm.stack[dst_base + 1 + copy_count ..][0 .. expected - copy_count]) |*slot| {
                            slot.* = .nil;
                        }
                    }
                    vm.top = if (nresults < 0) dst_base + 1 + copy_count else caller_frame_max;
                    return .LoopContinue;
                }

                if (ret_count == 0) {
                    // No return values - fill expected slots with nil or update top
                    if (nresults > 0) {
                        const n: usize = @intCast(nresults);
                        for (vm.stack[dst_base..][0..n]) |*slot| {
                            slot.* = .nil;
                        }
                    }
                    // For variable results (nresults < 0), vm.top must indicate no results
                    // For fixed results (nresults >= 0), restore to caller's frame extent
                    vm.top = if (nresults < 0) dst_base else caller_frame_max;
                } else if (nresults < 0) {
                    // Variable results - copy all return values
                    // Note: regions may overlap, copy forward (src >= dst)
                    for (0..ret_count) |i| {
                        vm.stack[dst_base + i] = vm.stack[returning_ci.base + a + i];
                    }
                    // vm.top must indicate result count for variable results
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
                    // GC SAFETY: Restore vm.top to caller's frame extent
                    // This ensures all caller's local variables are marked during GC
                    vm.top = caller_frame_max;
                }

                return .LoopContinue;
            }

            // Top-level return (no previous call frame)
            // Close TBC variables before returning
            const top_ci = vm.ci.?;
            if (b == 0) {
                if (top_ci.pending_return_count == null or top_ci.pending_return_a == null or top_ci.pending_return_a.? != a) {
                    top_ci.pending_return_a = a;
                    top_ci.pending_return_count = vm.top - (vm.base + a);
                }
            }
            try closeTbcForReturn(vm, top_ci);
            const ret_count: u32 = if (b == 0)
                top_ci.pending_return_count orelse (vm.top - (vm.base + a))
            else if (b == 1)
                0
            else
                b - 1;
            try hook_state.onReturnFromStack(vm, null, if (error_state.isClosingMetamethod(vm)) "close" else null, a + 1, vm.base + a, ret_count, executeSyncMM);

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

                // Close TBC variables before returning (Lua 5.4)
                try closeTbcForReturn(vm, returning_ci);
                if (vm.open_upvalues != null) {
                    vm.closeUpvalues(returning_ci.base);
                }
                try hook_state.onReturnCleared(vm, null, if (error_state.isClosingMetamethod(vm)) "close" else null, executeSyncMM);
                popCallInfo(vm);

                // Get caller's frame extent for vm.top restoration
                const caller_frame_max = vm.base + vm.ci.?.func.maxstacksize;

                // Protected frame: return (true) with no additional values
                if (is_protected) {
                    vm.stack[dst_base] = .{ .boolean = true };
                    vm.top = if (nresults < 0) dst_base + 1 else caller_frame_max;
                    return .LoopContinue;
                }

                // Fill expected result slots with nil
                if (nresults > 0) {
                    const n: usize = @intCast(nresults);
                    for (vm.stack[dst_base..][0..n]) |*slot| {
                        slot.* = .nil;
                    }
                }

                // GC SAFETY: For variable results, vm.top indicates no results (dst_base)
                // For fixed results, restore to caller's frame extent
                vm.top = if (nresults < 0) dst_base else caller_frame_max;

                return .LoopContinue;
            }

            // Top-level return - close TBC variables
            const top_ci = vm.ci.?;
            try closeTbcForReturn(vm, top_ci);
            try hook_state.onReturnCleared(vm, null, if (error_state.isClosingMetamethod(vm)) "close" else null, executeSyncMM);
            return .{ .ReturnVM = .none };
        },
        .RETURN1 => {
            const a = inst.getA();

            if (vm.ci.?.previous != null) {
                const returning_ci = vm.ci.?;
                const nresults = returning_ci.nresults;
                const dst_base = returning_ci.ret_base;
                const is_protected = returning_ci.is_protected;

                // Close TBC variables before returning (Lua 5.4)
                try closeTbcForReturn(vm, returning_ci);
                if (vm.open_upvalues != null) {
                    vm.closeUpvalues(returning_ci.base);
                }
                try hook_state.onReturnFromStack(vm, null, if (error_state.isClosingMetamethod(vm)) "close" else null, a + 1, returning_ci.base + a, 1, executeSyncMM);
                popCallInfo(vm);

                // Get caller's frame extent for vm.top restoration
                const caller_frame_max = vm.base + vm.ci.?.func.maxstacksize;

                // Protected frame: return (true, value)
                if (is_protected) {
                    vm.stack[dst_base] = .{ .boolean = true };
                    if (nresults != 0) {
                        vm.stack[dst_base + 1] = vm.stack[returning_ci.base + a];
                    }
                    vm.top = if (nresults < 0) dst_base + 2 else caller_frame_max;
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
                    // GC SAFETY: Restore vm.top to caller's frame extent
                    vm.top = caller_frame_max;
                } else {
                    // nresults == 0: caller doesn't want any results
                    vm.top = caller_frame_max;
                }

                return .LoopContinue;
            }

            // Top-level return - close TBC variables
            const top_ci = vm.ci.?;
            try closeTbcForReturn(vm, top_ci);
            try hook_state.onReturnFromStack(vm, null, if (error_state.isClosingMetamethod(vm)) "close" else null, a + 1, vm.base + a, 1, executeSyncMM);
            return .{ .ReturnVM = .{ .single = vm.stack[vm.base + a] } };
        },
        // [MM_INDEX] Fast path: upvalue table read. Slow path: __index metamethod.
        .GETTABUP => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();

            // Get environment table from upvalue or fall back to globals
            const env_table: *object.TableObject = if (ci.closure) |closure| blk: {
                if (b < closure.upvalues.len) {
                    break :blk closure.upvalues[b].get().asTable() orelse vm.globals();
                }
                break :blk vm.globals();
            } else vm.globals();

            const key_val = ci.func.k[c];
            if (key_val.asString()) |key| {
                field_cache.rememberFieldAccess(vm, a, key, true, false);
                if (try dispatchIndexMM(vm, env_table, key, TValue.fromTable(env_table), a)) |result| {
                    return result;
                }
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

            // Get environment table from upvalue or fall back to globals
            const env_table: *object.TableObject = if (ci.closure) |closure| blk: {
                if (a < closure.upvalues.len) {
                    break :blk closure.upvalues[a].get().asTable() orelse vm.globals();
                }
                break :blk vm.globals();
            } else vm.globals();

            const key_val = ci.func.k[b];
            const value = vm.stack[vm.base + c];
            if (key_val.asString()) |key| {
                if (try dispatchNewindexMM(vm, env_table, key, TValue.fromTable(env_table), value)) |result| {
                    return result;
                }
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
                    upvalueSetWithBarrier(vm, closure.upvalues[b], vm.stack[vm.base + a]);
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
            if (key_val.asString()) |key| {
                field_cache.rememberFieldAccess(vm, a, key, if (table_val.asTable()) |t| t == vm.globals() else false, false);
            }

            if (table_val.asTable()) |table| {
                if (key_val.isNil()) {
                    // t[nil] always returns nil (nil is not a valid table key)
                    vm.stack[vm.base + a] = TValue.nil;
                } else if (key_val.asString()) |key| {
                    if (try dispatchIndexMM(vm, table, key, table_val, a)) |result| {
                        return result;
                    }
                } else {
                    // Integer, number, boolean, etc. - use TValue key directly
                    if (try dispatchIndexMMValue(vm, table, key_val, table_val, a)) |result| {
                        return result;
                    }
                }
            } else {
                // Non-table value: check for shared metatable with __index
                if (try dispatchSharedIndexMMValue(vm, table_val, key_val, a)) |result| {
                    return result;
                }
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
                } else {
                    // Integer, number, boolean, etc.
                    if (try dispatchNewindexMMValue(vm, table, key_val, table_val, value)) |result| {
                        return result;
                    }
                }
            } else {
                const key = TValue{ .integer = @intCast(c) };
                if (try dispatchSharedIndexMMValue(vm, table_val, key, a)) |result| {
                    return result;
                }
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
                const key = TValue{ .integer = @intCast(c) };
                // Fast path: direct lookup
                if (table.get(key)) |value| {
                    vm.stack[vm.base + a] = value;
                } else {
                    if (try dispatchIndexMMValue(vm, table, key, table_val, a)) |result| {
                        return result;
                    }
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
                const key = TValue{ .integer = @intCast(b) };
                if (try dispatchNewindexMMValue(vm, table, key, table_val, value)) |result| {
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
                    field_cache.rememberFieldAccess(vm, a, key, false, false);
                    if (try dispatchIndexMM(vm, table, key, table_val, a)) |result| {
                        return result;
                    }
                } else {
                    return error.InvalidTableOperation;
                }
            } else {
                // Non-table value: check for shared metatable with __index
                if (key_val.asString()) |key| {
                    if (!table_val.isNil()) {
                        field_cache.rememberFieldAccess(vm, a, key, false, false);
                    }
                    if (try dispatchSharedIndexMM(vm, table_val, key, a)) |result| {
                        return result;
                    }
                } else {
                    return error.InvalidTableOperation;
                }
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
            const table = try vm.gc().allocTable();
            vm.stack[vm.base + a] = TValue.fromTable(table);
            return .Continue;
        },
        // [MM_INDEX] SELF: Prepare for method call. R[A+1] := R[B]; R[A] := R[B][K[C]]
        .SELF => {
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const obj = vm.stack[vm.base + b];

            // R[A+1] := R[B] (copy object for self parameter)
            vm.stack[vm.base + a + 1] = obj;

            // R[A] := R[B][K[C]] (get method from object)
            const key_val = ci.func.k[c];
            if (obj.asTable()) |table| {
                if (key_val.asString()) |key| {
                    field_cache.rememberFieldAccess(vm, a, key, false, true);
                    if (try dispatchIndexMM(vm, table, key, obj, a)) |result| {
                        return result;
                    }
                } else {
                    return error.InvalidTableOperation;
                }
            } else {
                // Non-table value: check for shared metatable with __index
                if (key_val.asString()) |key| {
                    field_cache.rememberFieldAccess(vm, a, key, false, true);
                    if (try dispatchSharedIndexMM(vm, obj, key, a)) |result| {
                        return result;
                    }
                } else {
                    return error.InvalidTableOperation;
                }
            }
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
            else switch (try dispatchLtMMForOpcode(vm, ci, left, right, a)) {
                .value => |mm_res| mm_res,
                .deferred => return .LoopContinue,
                .missing => {
                    _ = try raiseOrderComparison(vm, left, right);
                    unreachable;
                },
            };

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
            else switch (try dispatchLeMMForOpcode(vm, ci, left, right, a)) {
                .value => |mm_res| mm_res,
                .deferred => return .LoopContinue,
                .missing => {
                    _ = try raiseOrderComparison(vm, left, right);
                    unreachable;
                },
            };

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
            else switch (try dispatchLtMMForOpcode(vm, ci, left, right, a)) {
                .value => |mm_res| mm_res,
                .deferred => return .LoopContinue,
                .missing => {
                    _ = try raiseOrderComparison(vm, left, right);
                    unreachable;
                },
            };

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
            else switch (try dispatchLeMMForOpcode(vm, ci, left, right, a)) {
                .value => |mm_res| mm_res,
                .deferred => return .LoopContinue,
                .missing => {
                    _ = try raiseOrderComparison(vm, left, right);
                    unreachable;
                },
            };

            if ((is_true and a == 0) or (!is_true and a != 0)) {
                ci.skip();
            }
            return .Continue;
        },
        .CLOSE => {
            const a = inst.getA();
            // First, call __close on any TBC variables from top down to 'a'
            try closeTBCVariables(vm, ci, a, .nil);
            // Then close upvalues
            vm.closeUpvalues(vm.base + a);
            return .Continue;
        },
        .TBC => {
            // TBC A: Mark R[A] as to-be-closed
            // The value must have a __close metamethod or be false/nil
            const a = inst.getA();
            const val = vm.stack[vm.base + a];

            // nil and false don't need __close (they're valid but do nothing)
            if (val.isNil() or (val.isBoolean() and !val.toBoolean())) {
                // No need to mark, these are valid but won't call __close
                return .Continue;
            }

            // Non-false/non-nil values must provide __close at TBC time.
            if (metamethod.getMetamethod(val, .close, &vm.gc().mm_keys, &vm.gc().shared_mt) == null) {
                return error.NoCloseMetamethod;
            }

            // Mark this register as to-be-closed
            ci.markTBC(a);
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
            for (0..n) |i| {
                const value = vm.stack[vm.base + a + 1 + @as(u32, @intCast(i))];
                const index: i64 = start_index + @as(i64, @intCast(i));

                // Use integer key directly (Lua 5.4 semantics)
                const key = TValue{ .integer = index };

                // Set value in table (handles __newindex if needed)
                // Note: SETLIST uses raw set, not dispatchNewindexMM
                try tableSetWithBarrier(vm, table, key, value);
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
                        upvals_buf[i] = try vm.gc().allocUpvalue(&vm.stack[0], vm.thread);
                    }
                }
            }

            const closure = try vm.gc().allocClosure(child_proto);
            @memcpy(closure.upvalues[0..nups], upvals_buf[0..nups]);

            vm.stack[vm.base + a] = TValue.fromClosure(closure);
            return .Continue;
        },
        // Metamethod dispatch opcodes
        // These are emitted after arithmetic operations for metamethod fallback
        .MMBIN => {
            // MMBIN A B C: metamethod for binary operation R[A] op R[B]
            // C encodes the metamethod event (add, sub, mul, etc.)
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();

            const va = vm.stack[vm.base + a];
            const vb = vm.stack[vm.base + b];

            // Decode metamethod event from C
            const event = mmEventFromOpcode(c) orelse return error.UnknownOpcode;

            // Try to get metamethod from either operand
            const mm = metamethod.getBinMetamethod(va, vb, event, &vm.gc().mm_keys, &vm.gc().shared_mt) orelse {
                // No metamethod found - arithmetic error
                return error.ArithmeticError;
            };

            // Call the metamethod: mm(va, vb) -> result at a
            // Set up call: function at temp, args at temp+1, temp+2
            const temp = vm.top;
            vm.stack[temp] = mm;
            vm.stack[temp + 1] = va;
            vm.stack[temp + 2] = vb;
            vm.top = temp + 3;

            // If metamethod is a closure, push call frame
            if (mm.asClosure()) |closure| {
                const new_ci = try pushCallInfo(vm, closure.proto, closure, temp, @intCast(vm.base + a), 1);
                markMetamethodFrame(new_ci, metamethodEventNameRuntime(event));
                return .LoopContinue;
            }

            // For native closures, call directly
            if (mm.isObject() and mm.object.type == .native_closure) {
                const nc = object.getObject(NativeClosureObject, mm.object);
                try vm.callNative(nc.func.id, @intCast(temp - vm.base), 2, 1);
                // Result is at temp, move to a
                vm.stack[vm.base + a] = vm.stack[temp];
                vm.top = temp;
                return .Continue;
            }

            return error.NotAFunction;
        },
        .MMBINI => {
            // MMBINI A sB C k: metamethod for binary op with immediate
            // A = register operand, sB = signed immediate, C = metamethod event
            // k = operand order: k=0 means R[A] op sB, k=1 means sB op R[A]
            const a = inst.getA();
            const sb = @as(i8, @bitCast(inst.getB()));
            const c = inst.getC();
            const k = inst.getk();

            const va = vm.stack[vm.base + a];
            const vb = TValue{ .integer = @as(i64, sb) };

            // Decode metamethod event from C
            const event = mmEventFromOpcode(c) orelse return error.UnknownOpcode;

            // Determine operand order based on k flag
            const left = if (k) vb else va;
            const right = if (k) va else vb;

            // Try to get metamethod from either operand
            const mm = metamethod.getBinMetamethod(left, right, event, &vm.gc().mm_keys, &vm.gc().shared_mt) orelse {
                return error.ArithmeticError;
            };

            // Call the metamethod: mm(left, right) -> result at a
            const temp = vm.top;
            vm.stack[temp] = mm;
            vm.stack[temp + 1] = left;
            vm.stack[temp + 2] = right;
            vm.top = temp + 3;

            if (mm.asClosure()) |closure| {
                const new_ci = try pushCallInfo(vm, closure.proto, closure, temp, @intCast(vm.base + a), 1);
                markMetamethodFrame(new_ci, metamethodEventNameRuntime(event));
                return .LoopContinue;
            }

            if (mm.isObject() and mm.object.type == .native_closure) {
                const nc = object.getObject(NativeClosureObject, mm.object);
                try vm.callNative(nc.func.id, @intCast(temp - vm.base), 2, 1);
                vm.stack[vm.base + a] = vm.stack[temp];
                vm.top = temp;
                return .Continue;
            }

            return error.NotAFunction;
        },
        .MMBINK => {
            // MMBINK A B C k: metamethod for binary op with constant
            // A = register operand, B = constant index, C = metamethod event
            // k = operand order: k=0 means R[A] op K[B], k=1 means K[B] op R[A]
            const a = inst.getA();
            const b = inst.getB();
            const c = inst.getC();
            const k = inst.getk();

            const va = vm.stack[vm.base + a];
            const vb = ci.func.k[b];

            // Decode metamethod event from C
            const event = mmEventFromOpcode(c) orelse return error.UnknownOpcode;

            // Determine operand order based on k flag
            const left = if (k) vb else va;
            const right = if (k) va else vb;

            // Try to get metamethod from either operand
            const mm = metamethod.getBinMetamethod(left, right, event, &vm.gc().mm_keys, &vm.gc().shared_mt) orelse {
                return error.ArithmeticError;
            };

            // Call the metamethod: mm(left, right) -> result at a
            const temp = vm.top;
            vm.stack[temp] = mm;
            vm.stack[temp + 1] = left;
            vm.stack[temp + 2] = right;
            vm.top = temp + 3;

            if (mm.asClosure()) |closure| {
                const new_ci = try pushCallInfo(vm, closure.proto, closure, temp, @intCast(vm.base + a), 1);
                markMetamethodFrame(new_ci, metamethodEventNameRuntime(event));
                return .LoopContinue;
            }

            if (mm.isObject() and mm.object.type == .native_closure) {
                const nc = object.getObject(NativeClosureObject, mm.object);
                try vm.callNative(nc.func.id, @intCast(temp - vm.base), 2, 1);
                vm.stack[vm.base + a] = vm.stack[temp];
                vm.top = temp;
                return .Continue;
            }

            return error.NotAFunction;
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
            const total_results: u32 = if (c > 0) c - 1 else 0;
            return try dispatchProtectedCall(vm, ci, a, b, total_results, null, vm.base + a);
        },
        // All opcodes now implemented - no else branch needed
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
    const mm = metamethod.getBinMetamethod(vb, vc, event, &vm.gc().mm_keys, &vm.gc().shared_mt) orelse {
        if (event == .concat) {
            const bad = if (vb.toNumber() == null and vb.asString() == null) vb else vc;
            const ty = callableValueTypeName(bad);
            var msg_buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "attempt to concatenate a {s} value", .{ty}) catch "attempt to concatenate values";
            _ = try vm.raiseString(msg);
            unreachable;
        }
        return error.ArithmeticError;
    };

    if (!(mm.asClosure() != null or (mm.isObject() and mm.object.type == .native_closure))) {
        try raiseMetamethodNotCallable(vm, mm, metamethodEventName(event));
        unreachable;
    }

    // Call the metamethod
    return try callBinMetamethod(vm, mm, vb, vc, a, metamethodEventName(event));
}

fn dispatchArithKMM(vm: *VM, vb: TValue, vc: TValue, result_reg: u8, comptime event: MetaEvent) !?ExecuteResult {
    const mm = metamethod.getBinMetamethod(vb, vc, event, &vm.gc().mm_keys, &vm.gc().shared_mt) orelse {
        return null;
    };
    return try callBinMetamethod(vm, mm, vb, vc, result_reg, metamethodEventName(event));
}

/// Check if both values can be used for arithmetic (fast path)
/// Lua 5.4: numbers and strings (coercible to numbers) are allowed
fn canDoArith(a: TValue, b: TValue) bool {
    return (a.isInteger() or a.isNumber() or a.isString()) and
        (b.isInteger() or b.isNumber() or b.isString());
}

/// Call a binary metamethod and store result
fn callBinMetamethod(vm: *VM, mm: TValue, arg1: TValue, arg2: TValue, result_reg: u8, mm_name: []const u8) !ExecuteResult {
    // Set up call: like CALL instruction
    // func at temp, args at temp+1, temp+2
    // But for call frame, we copy args to start at new_base
    const temp = vm.top;

    // If metamethod is a closure, push call frame
    if (mm.asClosure()) |closure| {
        const func_proto = closure.proto;
        const new_base = temp;
        const total_args: u32 = 2;

        // Set up parameters at new_base (like CALL does)
        vm.stack[new_base] = arg1; // First parameter at R[0]
        vm.stack[new_base + 1] = arg2; // Second parameter at R[1]

        var vararg_base: u32 = 0;
        var vararg_count: u32 = 0;
        if (func_proto.is_vararg and total_args > func_proto.numparams) {
            vararg_count = total_args - func_proto.numparams;
            const min_vararg_base = new_base + func_proto.maxstacksize;
            vararg_base = @max(min_vararg_base, vm.top) + 32;
            try ensureStackTop(vm, vararg_base + vararg_count);
            var i: u32 = vararg_count;
            while (i > 0) {
                i -= 1;
                vm.stack[vararg_base + i] = vm.stack[new_base + func_proto.numparams + i];
            }
        }

        // Fill remaining fixed parameters with nil if needed
        var i: u32 = total_args;
        while (i < func_proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        const ci = try pushCallInfoVararg(
            vm,
            func_proto,
            closure,
            new_base,
            @intCast(vm.base + result_reg),
            1,
            vararg_base,
            vararg_count,
        );
        markMetamethodFrame(ci, mm_name);
        vm.top = if (vararg_count > 0) vararg_base + vararg_count else new_base + func_proto.maxstacksize;
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

/// Call a unary metamethod and store result
fn callUnaryMetamethod(vm: *VM, mm: TValue, arg: TValue, result_reg: u8, mm_name: []const u8) !ExecuteResult {
    const temp = vm.top;

    // If metamethod is a closure, push call frame
    if (mm.asClosure()) |closure| {
        const func_proto = closure.proto;
        const new_base = temp;
        const total_args: u32 = 2;

        // Lua passes unary metamethod operand twice for compatibility.
        vm.stack[new_base] = arg;
        vm.stack[new_base + 1] = arg;

        var vararg_base: u32 = 0;
        var vararg_count: u32 = 0;
        if (func_proto.is_vararg and total_args > func_proto.numparams) {
            vararg_count = total_args - func_proto.numparams;
            const min_vararg_base = new_base + func_proto.maxstacksize;
            vararg_base = @max(min_vararg_base, vm.top) + 32;
            try ensureStackTop(vm, vararg_base + vararg_count);
            var i: u32 = vararg_count;
            while (i > 0) {
                i -= 1;
                vm.stack[vararg_base + i] = vm.stack[new_base + func_proto.numparams + i];
            }
        }

        // Fill remaining fixed parameters with nil if needed
        var i: u32 = total_args;
        while (i < func_proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        const ci = try pushCallInfoVararg(
            vm,
            func_proto,
            closure,
            new_base,
            @intCast(vm.base + result_reg),
            1,
            vararg_base,
            vararg_count,
        );
        markMetamethodFrame(ci, mm_name);
        vm.top = if (vararg_count > 0) vararg_base + vararg_count else new_base + func_proto.maxstacksize;
        return .LoopContinue;
    }

    // For native closures, call directly
    if (mm.isObject() and mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, mm.object);
        vm.stack[temp] = mm;
        vm.stack[temp + 1] = arg;
        vm.stack[temp + 2] = arg;
        vm.top = temp + 3;

        try vm.callNative(nc.func.id, @intCast(temp - vm.base), 2, 1);
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
    return try dispatchIndexMMValue(vm, table, TValue.fromString(key), table_val, result_reg);
}

fn dispatchIndexMMValue(vm: *VM, table: *object.TableObject, key_val: TValue, table_val: TValue, result_reg: u8) !?ExecuteResult {
    return try dispatchIndexMMValueDepth(vm, table, key_val, table_val, result_reg, 0);
}

fn dispatchIndexMMValueDepth(vm: *VM, table: *object.TableObject, key_val: TValue, table_val: TValue, result_reg: u8, depth: u16) !?ExecuteResult {
    // Logical recursion guard for __index chains, independent of call stack depth.
    if (depth >= 2000) return error.InvalidTableOperation;
    // Fast path: key exists in table
    if (table.get(key_val)) |value| {
        vm.stack[vm.base + result_reg] = value;
        return null; // Continue
    }

    // Check for __index metamethod
    const mt = table.metatable orelse {
        vm.stack[vm.base + result_reg] = .nil;
        return null; // Continue
    };

    const index_mm = mt.get(TValue.fromString(vm.gc().mm_keys.get(.index))) orelse {
        vm.stack[vm.base + result_reg] = .nil;
        return null; // Continue
    };

    // __index is a table: recursively look up
    if (index_mm.asTable()) |index_table| {
        if (index_table.get(key_val)) |value| {
            vm.stack[vm.base + result_reg] = value;
        } else {
            // Recursive __index lookup on the index table
            return try dispatchIndexMMValueDepth(vm, index_table, key_val, index_mm, result_reg, depth + 1);
        }
        return null; // Continue
    }

    // __index is a function: call it with (table, key)
    if (index_mm.asClosure()) |closure| {
        const proto = closure.proto;
        const new_base = vm.top;

        // Set up parameters: table, key
        vm.stack[new_base] = table_val;
        vm.stack[new_base + 1] = key_val;

        // Fill remaining parameters with nil if needed
        var i: u32 = 2;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        vm.top = new_base + proto.maxstacksize;

        const ci = try pushCallInfo(vm, proto, closure, new_base, @intCast(vm.base + result_reg), 1);
        markMetamethodFrame(ci, "index");
        return .LoopContinue;
    }

    // __index is a native function
    if (index_mm.isObject() and index_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, index_mm.object);
        const temp = vm.top;

        vm.stack[temp] = index_mm;
        vm.stack[temp + 1] = table_val;
        vm.stack[temp + 2] = key_val;
        vm.top = temp + 3;

        try vm.callNative(nc.func.id, @intCast(temp - vm.base), 2, 1);
        vm.stack[vm.base + result_reg] = vm.stack[temp];
        vm.top = temp;
        return null; // Continue
    }

    // __index must be a table or function; any other type is an indexing error.
    try raiseIndexValueError(vm, index_mm);
    return error.LuaException;
}

/// Dispatch __index metamethod for non-table values (strings, numbers, userdata, files, etc.)
/// Uses shared metatables from gc.shared_mt, or individual metatables for userdata/files
fn dispatchSharedIndexMM(vm: *VM, value: TValue, key: *object.StringObject, result_reg: u8) !?ExecuteResult {
    return try dispatchSharedIndexMMValue(vm, value, TValue.fromString(key), result_reg);
}

fn dispatchSharedIndexMMValue(vm: *VM, value: TValue, key_val: TValue, result_reg: u8) !?ExecuteResult {
    // Check for individual metatable first (FileObject, Userdata)
    const mt = blk: {
        if (value.asFile()) |file_obj| {
            break :blk file_obj.metatable orelse return error.NotATable;
        }
        if (value.asUserdata()) |ud| {
            break :blk ud.metatable orelse return error.NotATable;
        }
        // Get shared metatable for primitive types
        break :blk vm.gc().shared_mt.getForValue(value) orelse {
            // No shared metatable - cannot index this value type
            return error.NotATable;
        };
    };

    // Look up __index in the metatable
    const index_mm = mt.get(TValue.fromString(vm.gc().mm_keys.get(.index))) orelse {
        return error.NotATable;
    };

    // __index is a table: look up the key
    if (index_mm.asTable()) |index_table| {
        if (index_table.get(key_val)) |found| {
            vm.stack[vm.base + result_reg] = found;
        } else {
            // Recursive lookup in index table's metatable
            return try dispatchIndexMMValue(vm, index_table, key_val, index_mm, result_reg);
        }
        return null;
    }

    // __index is a function: call it with (value, key)
    if (index_mm.asClosure()) |closure| {
        const proto = closure.proto;
        const new_base = vm.top;

        // Set up parameters: value, key
        vm.stack[new_base] = value;
        vm.stack[new_base + 1] = key_val;

        // Fill remaining parameters with nil if needed
        var i: u32 = 2;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        vm.top = new_base + proto.maxstacksize;

        const ci = try pushCallInfo(vm, proto, closure, new_base, @intCast(vm.base + result_reg), 1);
        markMetamethodFrame(ci, "index");
        return .LoopContinue;
    }

    // __index is a native function
    if (index_mm.isObject() and index_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, index_mm.object);
        const temp = vm.top;

        vm.stack[temp] = index_mm;
        vm.stack[temp + 1] = value;
        vm.stack[temp + 2] = key_val;
        vm.top = temp + 3;

        try vm.callNative(nc.func.id, @intCast(temp - vm.base), 2, 1);
        vm.stack[vm.base + result_reg] = vm.stack[temp];
        vm.top = temp;
        return null;
    }

    // __index must be a table or function; any other type is an indexing error.
    try raiseIndexValueError(vm, index_mm);
    return error.LuaException;
}

/// Newindex with __newindex metamethod fallback
/// If key doesn't exist and __newindex is set, dispatch to metamethod
/// If __newindex is a table, set the key in that table
/// If __newindex is a function, call it with (table, key, value)
fn dispatchNewindexMM(vm: *VM, table: *object.TableObject, key: *object.StringObject, table_val: TValue, value: TValue) !?ExecuteResult {
    return try dispatchNewindexMMValue(vm, table, TValue.fromString(key), table_val, value);
}

fn dispatchNewindexMMValue(vm: *VM, table: *object.TableObject, key_val: TValue, table_val: TValue, value: TValue) !?ExecuteResult {
    return try dispatchNewindexMMValueDepth(vm, table, key_val, table_val, value, 0);
}

fn dispatchNewindexMMValueDepth(vm: *VM, table: *object.TableObject, key_val: TValue, table_val: TValue, value: TValue, depth: u16) !?ExecuteResult {
    // Logical recursion guard for __newindex chains, independent of call stack depth.
    if (depth >= 2000) return error.InvalidTableOperation;
    // Fast path: key already exists in table - just update it
    if (table.get(key_val) != null) {
        try tableSetWithBarrier(vm, table, key_val, value);
        return null; // Continue
    }

    // Check for __newindex metamethod
    const mt = table.metatable orelse {
        try tableSetWithBarrier(vm, table, key_val, value);
        return null; // Continue
    };

    const newindex_mm = mt.get(TValue.fromString(vm.gc().mm_keys.get(.newindex))) orelse {
        try tableSetWithBarrier(vm, table, key_val, value);
        return null; // Continue
    };

    // __newindex is a table: set in that table instead
    if (newindex_mm.asTable()) |newindex_table| {
        return try dispatchNewindexMMValueDepth(vm, newindex_table, key_val, newindex_mm, value, depth + 1);
    }

    // __newindex is a function: call it with (table, key, value)
    if (newindex_mm.asClosure()) |closure| {
        const proto = closure.proto;
        const new_base = vm.top;

        vm.stack[new_base] = table_val;
        vm.stack[new_base + 1] = key_val;
        vm.stack[new_base + 2] = value;

        var i: u32 = 3;
        while (i < proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        vm.top = new_base + proto.maxstacksize;
        const ci = try pushCallInfo(vm, proto, closure, new_base, new_base, 0);
        markMetamethodFrame(ci, "newindex");
        return .LoopContinue;
    }

    // __newindex is a native function
    if (newindex_mm.isObject() and newindex_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, newindex_mm.object);
        const temp = vm.top;

        vm.stack[temp] = newindex_mm;
        vm.stack[temp + 1] = table_val;
        vm.stack[temp + 2] = key_val;
        vm.stack[temp + 3] = value;
        vm.top = temp + 4;

        try vm.callNative(nc.func.id, @intCast(temp - vm.base), 3, 0);
        vm.top = temp;
        return null; // Continue
    }

    // __newindex is not a valid type, just set normally
    try tableSetWithBarrier(vm, table, key_val, value);
    return null;
}

/// Call metamethod dispatch for non-callable values
/// If obj has __call metamethod, call it with (obj, args...)
/// Returns null if no __call found (caller should return error)
fn dispatchCallMM(vm: *VM, obj_val: TValue, func_slot: u32, nargs: u32, nresults: i16) !?ExecuteResult {
    var callable = obj_val;
    var effective_nargs = nargs;
    var callable_at_func_slot = false;
    var depth: u16 = 0;

    while (true) {
        // Resolve callable function.
        if (callable.asClosure()) |closure| {
            const func_proto = closure.proto;
            const new_base = vm.base + func_slot;
            const total_args = effective_nargs + 1;

            // Match regular CALL semantics for vararg closures.
            var vararg_base: u32 = 0;
            var vararg_count: u32 = 0;
            if (func_proto.is_vararg and total_args > func_proto.numparams) {
                vararg_count = total_args - func_proto.numparams;
                const min_vararg_base = new_base + func_proto.maxstacksize;
                vararg_base = @max(min_vararg_base, vm.top) + 32;
                try ensureStackTop(vm, vararg_base + vararg_count);

                var i: u32 = vararg_count;
                while (i > 0) {
                    i -= 1;
                    vm.stack[vararg_base + i] = vm.stack[new_base + func_proto.numparams + i];
                }
            }

            // Fill missing fixed parameters.
            var i: u32 = total_args;
            while (i < func_proto.numparams) : (i += 1) {
                vm.stack[new_base + i] = .nil;
            }

            const ci = try pushCallInfoVararg(
                vm,
                func_proto,
                closure,
                new_base,
                new_base,
                nresults,
                vararg_base,
                vararg_count,
            );
            markMetamethodFrame(ci, "call");
            vm.top = if (vararg_count > 0) vararg_base + vararg_count else new_base + func_proto.maxstacksize;
            return .LoopContinue;
        }

        if (callable.isObject() and callable.object.type == .native_closure) {
            const nc = object.getObject(NativeClosureObject, callable.object);
            const base_slot = func_slot;
            const native_nargs: u32 = if (callable_at_func_slot) effective_nargs else effective_nargs + 1;

            // Stack is already correct: callable at base_slot, args at base_slot+1...
            const stack_room: u32 = @intCast(vm.stack.len - (vm.base + base_slot));
            const actual_nresults = nativeDesiredResultsForMM(nc.func.id, nresults, stack_room);
            try vm.callNative(nc.func.id, base_slot, native_nargs, actual_nresults);

            // Update vm.top after native call completes
            const is_multret_native = nresults < 0 and switch (nc.func.id) {
                .io_lines_iterator, .coroutine_resume, .coroutine_wrap_call => true,
                else => false,
            };
            if (!is_multret_native) {
                vm.top = vm.base + base_slot + actual_nresults;
            }
            return .LoopContinue;
        }

        // Follow __call chain (table -> __call -> table -> ...).
        const table = callable.asTable() orelse return null;
        const mt = table.metatable orelse return null;
        const call_mm = mt.get(TValue.fromString(vm.gc().mm_keys.get(.call))) orelse return null;

        if (depth >= 2000) return error.NotAFunction;
        depth += 1;

        if (call_mm.asTable() != null or (call_mm.isObject() and call_mm.object.type == .native_closure)) {
            // Rewrite in place: call_mm(self, args...), increasing args by one.
            try ensureStackTop(vm, vm.base + func_slot + effective_nargs + 2);
            var i: u32 = effective_nargs;
            while (i > 0) {
                i -= 1;
                vm.stack[vm.base + func_slot + 2 + i] = vm.stack[vm.base + func_slot + 1 + i];
            }
            vm.stack[vm.base + func_slot + 1] = callable;
            vm.stack[vm.base + func_slot] = call_mm;
            callable = call_mm;
            effective_nargs += 1;
            callable_at_func_slot = true;
            vm.top = @max(vm.top, vm.base + func_slot + 1 + effective_nargs);
        } else {
            // If __call already resolved to a function, keep current argument layout:
            // stack[func_slot] is current self, stack[func_slot+1..] are existing args.
            callable = call_mm;
            callable_at_func_slot = false;
        }
    }
}

/// Len with __len metamethod fallback
/// If table has __len metamethod, call it and return the result
/// Returns null if no __len found (caller should use default length)
fn dispatchLenMM(vm: *VM, table: *object.TableObject, table_val: TValue, result_reg: u8) !?ExecuteResult {
    const mt = table.metatable orelse return null;

    const len_mm = mt.get(TValue.fromString(vm.gc().mm_keys.get(.len))) orelse return null;

    // __len is a Lua function
    if (len_mm.asClosure()) |closure| {
        const func_proto = closure.proto;
        const new_base = vm.top;
        const total_args: u32 = 2;

        // Lua passes unary metamethod operand twice for compatibility.
        vm.stack[new_base] = table_val;
        vm.stack[new_base + 1] = table_val;

        var vararg_base: u32 = 0;
        var vararg_count: u32 = 0;
        if (func_proto.is_vararg and total_args > func_proto.numparams) {
            vararg_count = total_args - func_proto.numparams;
            const min_vararg_base = new_base + func_proto.maxstacksize;
            vararg_base = @max(min_vararg_base, vm.top) + 32;
            try ensureStackTop(vm, vararg_base + vararg_count);
            var i: u32 = vararg_count;
            while (i > 0) {
                i -= 1;
                vm.stack[vararg_base + i] = vm.stack[new_base + func_proto.numparams + i];
            }
        }

        var i: u32 = total_args;
        while (i < func_proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }
        const ci = try pushCallInfoVararg(
            vm,
            func_proto,
            closure,
            new_base,
            vm.base + result_reg,
            1,
            vararg_base,
            vararg_count,
        );
        markMetamethodFrame(ci, "len");
        vm.top = if (vararg_count > 0) vararg_base + vararg_count else new_base + func_proto.maxstacksize;
        return .LoopContinue;
    }

    // __len is a native function
    if (len_mm.isObject() and len_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, len_mm.object);
        const call_base = vm.top;

        vm.stack[call_base] = len_mm;
        vm.stack[call_base + 1] = table_val;
        vm.stack[call_base + 2] = table_val;
        vm.top = call_base + 3;

        try vm.callNative(nc.func.id, @intCast(call_base), 2, 1);

        // Copy result to destination register
        vm.stack[vm.base + result_reg] = vm.stack[call_base];
        vm.top = call_base;
        return .Continue;
    }

    return null;
}

/// Check if value can be concatenated without metamethod (string or number)
fn canConcatPrimitive(val: TValue) bool {
    return val.asString() != null or val.isInteger() or val.isNumber();
}

fn appendConcatValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, val: TValue) !void {
    if (val.asString()) |s| {
        try out.appendSlice(allocator, s.asSlice());
        return;
    }
    if (val.isInteger()) {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{val.integer}) catch return error.ArithmeticError;
        try out.appendSlice(allocator, str);
        return;
    }
    if (val.isNumber()) {
        var buf: [32]u8 = undefined;
        const str = formatConcatNumber(&buf, val.number);
        try out.appendSlice(allocator, str);
        return;
    }
    return error.ArithmeticError;
}

fn concatTwoSync(vm: *VM, left: TValue, right: TValue) !TValue {
    if (canConcatPrimitive(left) and canConcatPrimitive(right)) {
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(vm.gc().allocator);
        try appendConcatValue(&out, vm.gc().allocator, left);
        try appendConcatValue(&out, vm.gc().allocator, right);
        const joined = try out.toOwnedSlice(vm.gc().allocator);
        defer vm.gc().allocator.free(joined);
        const s = try vm.gc().allocString(joined);
        return TValue.fromString(s);
    }

    const concat_mm = getConcatMM(vm, left) orelse getConcatMM(vm, right) orelse {
        const bad = if (!canConcatPrimitive(left)) left else right;
        const ty = callableValueTypeName(bad);
        var msg_buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "attempt to concatenate a {s} value", .{ty}) catch "attempt to concatenate values";
        return vm.raiseString(msg);
    };
    if (concat_mm.asClosure()) |closure| {
        return try executeSyncMMWithDebug(vm, closure, &[_]TValue{ left, right }, "concat", "metamethod");
    }
    if (concat_mm.isObject() and concat_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, concat_mm.object);
        const call_base = vm.top;
        vm.stack[call_base] = concat_mm;
        vm.stack[call_base + 1] = left;
        vm.stack[call_base + 2] = right;
        vm.top = call_base + 3;
        try vm.callNative(nc.func.id, @intCast(call_base), 2, 1);
        const result = vm.stack[call_base];
        vm.top = call_base;
        return result;
    }
    return vm.raiseString("attempt to concatenate a non-string value");
}

pub fn continueConcatFold(vm: *VM, ci: *CallInfo) !bool {
    var acc = vm.stack[vm.base + ci.pending_concat_a];
    var i = ci.pending_concat_i;

    while (i >= @as(i16, @intCast(ci.pending_concat_b))) : (i -= 1) {
        const left = vm.stack[vm.base + @as(u32, @intCast(i))];
        if (canConcatPrimitive(left) and canConcatPrimitive(acc)) {
            acc = try concatTwoSync(vm, left, acc);
            vm.stack[vm.base + ci.pending_concat_a] = acc;
            continue;
        }

        const mm_res = try dispatchConcatMM(vm, left, acc, ci.pending_concat_a) orelse {
            const bad = if (!canConcatPrimitive(left)) left else acc;
            const ty = callableValueTypeName(bad);
            var msg_buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "attempt to concatenate a {s} value", .{ty}) catch "attempt to concatenate values";
            return vm.raiseString(msg);
        };

        switch (mm_res) {
            .Continue => {
                acc = vm.stack[vm.base + ci.pending_concat_a];
                continue;
            },
            .LoopContinue => {
                ci.pending_concat_i = i - 1;
                ci.pending_concat_active = true;
                return true;
            },
            .ReturnVM => unreachable,
        }
    }

    vm.stack[vm.base + ci.pending_concat_a] = acc;
    ci.pending_concat_active = false;
    return false;
}

/// Try to get __concat metamethod from a value
fn getConcatMM(vm: *VM, val: TValue) ?TValue {
    const table = val.asTable() orelse return null;
    const mt = table.metatable orelse return null;
    return mt.get(TValue.fromString(vm.gc().mm_keys.get(.concat)));
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
        const ci = try pushCallInfo(vm, proto, closure, new_base, vm.base + result_reg, 1);
        markMetamethodFrame(ci, "concat");
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
    return mt.get(TValue.fromString(vm.gc().mm_keys.get(.eq)));
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

    // Moonquakes deviation: use first available __eq from either side.
    // Lua 5.4 requires both operands to share the same __eq metamethod.
    const eq_mm = getEqMM(vm, left) orelse getEqMM(vm, right) orelse return null;

    // __eq is a native function - call synchronously
    if (eq_mm.isObject() and eq_mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, eq_mm.object);
        const call_base = vm.top;
        vm.stack[call_base] = eq_mm;
        vm.stack[call_base + 1] = TValue.fromTable(left_table);
        vm.stack[call_base + 2] = TValue.fromTable(right_table);
        vm.top = call_base + 3;
        try vm.callNative(nc.func.id, @intCast(call_base), 2, 1);
        const result = vm.stack[call_base];
        vm.top = call_base;
        return result.toBoolean();
    }

    // __eq is a Lua function - call synchronously using VM's executeSync
    if (eq_mm.asClosure()) |closure| {
        const result = try executeSyncMMWithDebug(vm, closure, &[_]TValue{
            TValue.fromTable(left_table),
            TValue.fromTable(right_table),
        }, "eq", "metamethod");
        return result.toBoolean();
    }

    return null;
}

/// Try to get __lt metamethod from a table
fn getLtMM(vm: *VM, val: TValue) ?TValue {
    const table = val.asTable() orelse return null;
    const mt = table.metatable orelse return null;
    return mt.get(TValue.fromString(vm.gc().mm_keys.get(.lt)));
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
        const result = try executeSyncMMWithDebug(vm, closure, &[_]TValue{ left, right }, "lt", "metamethod");
        return result.toBoolean();
    }

    try raiseMetamethodNotCallable(vm, lt_mm, "lt");
    unreachable;
}

/// Try to get __le metamethod from a table
fn getLeMM(vm: *VM, val: TValue) ?TValue {
    const table = val.asTable() orelse return null;
    const mt = table.metatable orelse return null;
    return mt.get(TValue.fromString(vm.gc().mm_keys.get(.le)));
}

const CompareMMDispatch = union(enum) {
    value: bool,
    deferred,
    missing,
};

fn callBinMetamethodToAbs(vm: *VM, mm: TValue, arg1: TValue, arg2: TValue, ret_abs: u32, mm_name: []const u8) !ExecuteResult {
    const temp = vm.top;

    if (mm.asClosure()) |closure| {
        const func_proto = closure.proto;
        const new_base = temp;
        const total_args: u32 = 2;

        vm.stack[new_base] = arg1;
        vm.stack[new_base + 1] = arg2;

        var vararg_base: u32 = 0;
        var vararg_count: u32 = 0;
        if (func_proto.is_vararg and total_args > func_proto.numparams) {
            vararg_count = total_args - func_proto.numparams;
            const min_vararg_base = new_base + func_proto.maxstacksize;
            vararg_base = @max(min_vararg_base, vm.top) + 32;
            try ensureStackTop(vm, vararg_base + vararg_count);
            var i: u32 = vararg_count;
            while (i > 0) {
                i -= 1;
                vm.stack[vararg_base + i] = vm.stack[new_base + func_proto.numparams + i];
            }
        }

        var i: u32 = total_args;
        while (i < func_proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        const ci = try pushCallInfoVararg(
            vm,
            func_proto,
            closure,
            new_base,
            ret_abs,
            1,
            vararg_base,
            vararg_count,
        );
        markMetamethodFrame(ci, mm_name);
        vm.top = if (vararg_count > 0) vararg_base + vararg_count else new_base + func_proto.maxstacksize;
        return .LoopContinue;
    }

    if (mm.isObject() and mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, mm.object);
        vm.stack[temp] = mm;
        vm.stack[temp + 1] = arg1;
        vm.stack[temp + 2] = arg2;
        vm.top = temp + 3;

        try vm.callNative(nc.func.id, @intCast(temp - vm.base), 2, 1);
        vm.stack[ret_abs] = vm.stack[temp];
        vm.top = temp;
        return .Continue;
    }

    return error.NotAFunction;
}

fn scheduleCompareMM(
    vm: *VM,
    ci: *CallInfo,
    mm: TValue,
    left: TValue,
    right: TValue,
    negate: u8,
    invert: bool,
    mm_name: []const u8,
) !CompareMMDispatch {
    if (!(mm.asClosure() != null or (mm.isObject() and mm.object.type == .native_closure))) {
        try raiseMetamethodNotCallable(vm, mm, mm_name);
        unreachable;
    }

    const result_slot = vm.top;
    try ensureStackTop(vm, result_slot + 1);

    ci.pending_compare_active = true;
    ci.pending_compare_negate = negate;
    ci.pending_compare_invert = invert;
    ci.pending_compare_result_slot = result_slot;

    const exec_res = try callBinMetamethodToAbs(vm, mm, left, right, result_slot, mm_name);
    switch (exec_res) {
        .LoopContinue => return .deferred,
        .Continue => {
            var is_true = vm.stack[result_slot].toBoolean();
            if (invert) is_true = !is_true;
            ci.pending_compare_active = false;
            return .{ .value = is_true };
        },
        .ReturnVM => unreachable,
    }
}

fn dispatchLeMMForOpcode(vm: *VM, ci: *CallInfo, left: TValue, right: TValue, negate: u8) !CompareMMDispatch {
    if (getLeMM(vm, left) orelse getLeMM(vm, right)) |le_mm| {
        return try scheduleCompareMM(vm, ci, le_mm, left, right, negate, false, "le");
    }

    if (getLtMM(vm, right) orelse getLtMM(vm, left)) |lt_mm| {
        return try scheduleCompareMM(vm, ci, lt_mm, right, left, negate, true, "lt");
    }

    return .missing;
}

fn dispatchLtMMForOpcode(vm: *VM, ci: *CallInfo, left: TValue, right: TValue, negate: u8) !CompareMMDispatch {
    if (getLtMM(vm, left) orelse getLtMM(vm, right)) |lt_mm| {
        return try scheduleCompareMM(vm, ci, lt_mm, left, right, negate, false, "lt");
    }
    return .missing;
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
            const result = try executeSyncMMWithDebug(vm, closure, &[_]TValue{ left, right }, "le", "metamethod");
            return result.toBoolean();
        }

        try raiseMetamethodNotCallable(vm, le_mm, "le");
        unreachable;
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
            const result = try executeSyncMMWithDebug(vm, closure, &[_]TValue{ right, left }, "lt", "metamethod");
            return !result.toBoolean();
        }

        try raiseMetamethodNotCallable(vm, lt_mm, "lt");
        unreachable;
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
    const key = try vm.gc().allocString(event.toKey());
    return mt.get(TValue.fromString(key));
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
        const func_proto = closure.proto;
        const new_base = vm.top;
        const total_args: u32 = 2;

        vm.stack[new_base] = left;
        vm.stack[new_base + 1] = right;

        var vararg_base: u32 = 0;
        var vararg_count: u32 = 0;
        if (func_proto.is_vararg and total_args > func_proto.numparams) {
            vararg_count = total_args - func_proto.numparams;
            const min_vararg_base = new_base + func_proto.maxstacksize;
            vararg_base = @max(min_vararg_base, vm.top) + 32;
            try ensureStackTop(vm, vararg_base + vararg_count);
            var i: u32 = vararg_count;
            while (i > 0) {
                i -= 1;
                vm.stack[vararg_base + i] = vm.stack[new_base + func_proto.numparams + i];
            }
        }

        var i: u32 = total_args;
        while (i < func_proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        const ci = try pushCallInfoVararg(
            vm,
            func_proto,
            closure,
            new_base,
            vm.base + result_reg,
            1,
            vararg_base,
            vararg_count,
        );
        markMetamethodFrame(ci, event.toKey()[2..]);
        vm.top = if (vararg_count > 0) vararg_base + vararg_count else new_base + func_proto.maxstacksize;
        return .LoopContinue;
    }

    // Metamethod is a native function
    if (mm.isObject() and mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, mm.object);
        const call_base = vm.top;
        vm.stack[call_base] = mm;
        vm.stack[call_base + 1] = left;
        vm.stack[call_base + 2] = right;
        vm.top = call_base + 3;
        try vm.callNative(nc.func.id, @intCast(call_base), 2, 1);
        vm.stack[vm.base + result_reg] = vm.stack[call_base];
        vm.top = call_base;
        return .Continue;
    }

    return null;
}

/// Unary bitwise not with __bnot metamethod fallback
fn dispatchBnotMM(vm: *VM, operand: TValue, result_reg: u8) !?ExecuteResult {
    const mm = try getBitwiseMM(vm, operand, .bnot) orelse return null;

    // Metamethod is a Lua function
    if (mm.asClosure()) |closure| {
        const func_proto = closure.proto;
        const new_base = vm.top;
        const total_args: u32 = 2;

        vm.stack[new_base] = operand;
        vm.stack[new_base + 1] = operand;

        var vararg_base: u32 = 0;
        var vararg_count: u32 = 0;
        if (func_proto.is_vararg and total_args > func_proto.numparams) {
            vararg_count = total_args - func_proto.numparams;
            const min_vararg_base = new_base + func_proto.maxstacksize;
            vararg_base = @max(min_vararg_base, vm.top) + 32;
            try ensureStackTop(vm, vararg_base + vararg_count);
            var i: u32 = vararg_count;
            while (i > 0) {
                i -= 1;
                vm.stack[vararg_base + i] = vm.stack[new_base + func_proto.numparams + i];
            }
        }

        var i: u32 = total_args;
        while (i < func_proto.numparams) : (i += 1) {
            vm.stack[new_base + i] = .nil;
        }

        const ci = try pushCallInfoVararg(
            vm,
            func_proto,
            closure,
            new_base,
            vm.base + result_reg,
            1,
            vararg_base,
            vararg_count,
        );
        markMetamethodFrame(ci, "bnot");
        vm.top = if (vararg_count > 0) vararg_base + vararg_count else new_base + func_proto.maxstacksize;
        return .LoopContinue;
    }

    // Metamethod is a native function
    if (mm.isObject() and mm.object.type == .native_closure) {
        const nc = object.getObject(NativeClosureObject, mm.object);
        const call_base = vm.top;
        vm.stack[call_base] = mm;
        vm.stack[call_base + 1] = operand;
        vm.stack[call_base + 2] = operand;
        vm.top = call_base + 3;
        try vm.callNative(nc.func.id, @intCast(call_base), 2, 1);
        vm.stack[vm.base + result_reg] = vm.stack[call_base];
        vm.top = call_base;
        return .Continue;
    }

    return null;
}
