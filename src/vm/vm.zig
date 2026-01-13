const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const Closure = @import("../runtime/closure.zig").Closure;
const Proto = @import("../compiler/proto.zig").Proto;
const Table = @import("../runtime/table.zig").Table;
const Function = @import("../runtime/function.zig").Function;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const GC = @import("../runtime/gc/gc.zig").GC;
const StringObject = @import("../runtime/gc/object.zig").StringObject;
const opcodes = @import("../compiler/opcodes.zig");
const OpCode = opcodes.OpCode;
const Instruction = opcodes.Instruction;
const builtin = @import("../builtin/dispatch.zig");
const ErrorHandler = @import("error.zig");

// CallInfo represents a function call in the call stack
pub const CallInfo = struct {
    func: *const Proto,
    pc: [*]const Instruction,
    base: u32,
    ret_base: u32, // Where to place return values in caller's frame
    savedpc: ?[*]const Instruction, // saved pc for yielding
    nresults: i16, // expected number of results (-1 = multiple)
    previous: ?*CallInfo, // previous frame in the call stack

    /// Fetch next instruction and advance PC
    /// Encapsulates PC bounds checking as an invariant
    pub inline fn fetch(self: *CallInfo) !Instruction {
        try self.validatePC();
        const inst = self.pc[0];
        self.skip();

        return inst;
    }

    /// Skip next instruction (increment PC by 1)
    pub inline fn skip(self: *CallInfo) void {
        self.pc += 1;
    }

    /// Jump relatively from current PC position
    /// Handles both forward and backward jumps
    pub inline fn jumpRel(self: *CallInfo, offset: i32) !void {
        if (offset >= 0) {
            self.pc += @as(usize, @intCast(offset));
        } else {
            self.pc -= @as(usize, @intCast(-offset));
        }

        try self.validatePC();
    }

    /// Fetch next instruction expecting it to be EXTRAARG
    /// Used by instructions like LOADKX that consume 2-word opcodes
    pub inline fn fetchExtraArg(self: *CallInfo) !Instruction {
        const inst = try self.fetch();
        if (inst.getOpCode() != .EXTRAARG) {
            return error.UnknownOpcode;
        }
        return inst;
    }

    /// Validate PC is within function bounds
    inline fn validatePC(self: *CallInfo) !void {
        const pc_offset = @intFromPtr(self.pc) - @intFromPtr(self.func.code.ptr);
        const pc_index = pc_offset / @sizeOf(Instruction);
        if (pc_index >= self.func.code.len) {
            return error.PcOutOfRange;
        }
    }
};

pub const VM = struct {
    stack: [256]TValue,
    stack_last: u32,
    top: u32,
    base: u32,
    ci: ?*CallInfo,
    base_ci: CallInfo,
    callstack: [35]CallInfo, // Support up to 35 nested calls
    callstack_size: u8,
    globals: *Table,
    allocator: std.mem.Allocator,
    gc: GC, // Garbage collector (replaces arena)

    pub fn init(allocator: std.mem.Allocator) !VM {
        // Initialize GC first so we can allocate strings
        var gc = GC.init(allocator);

        const globals = try allocator.create(Table);
        globals.* = Table.init(allocator);

        // Initialize global environment (needs GC for string allocation)
        try builtin.initGlobalEnvironment(globals, &gc);

        var vm = VM{
            .stack = undefined,
            .stack_last = 256 - 1,
            .top = 0,
            .base = 0,
            .ci = null,
            .base_ci = undefined,
            .callstack = undefined,
            .callstack_size = 0,
            .globals = globals,
            .allocator = allocator,
            .gc = gc,
        };
        for (&vm.stack) |*v| {
            v.* = .nil;
        }
        return vm;
    }

    pub fn deinit(self: *VM) void {
        // Clean up GC (will free all GC objects)
        self.gc.deinit();

        // Clean up package table's nested tables first
        if (self.globals.get("package")) |package_val| {
            if (package_val == .table) {
                const package_subtables = [_][]const u8{ "loaded", "preload", "searchers" };
                for (package_subtables) |subtable_name| {
                    if (package_val.table.get(subtable_name)) |subtable_val| {
                        if (subtable_val == .table) {
                            subtable_val.table.deinit();
                            self.allocator.destroy(subtable_val.table);
                        }
                    }
                }
            }
        }

        // Clean up library tables (string, io, math, table, os, debug, utf8, coroutine, package)
        const library_names = [_][]const u8{ "string", "io", "math", "table", "os", "debug", "utf8", "coroutine", "package" };
        for (library_names) |lib_name| {
            if (self.globals.get(lib_name)) |lib_val| {
                if (lib_val == .table) {
                    lib_val.table.deinit();
                    self.allocator.destroy(lib_val.table);
                }
            }
        }

        // Clean up globals table
        self.globals.deinit();
        self.allocator.destroy(self.globals);
    }

    /// VM is just a bridge - dispatches to appropriate native function
    fn callNative(self: *VM, id: NativeFnId, func_reg: u32, nargs: u32, nresults: u32) !void {
        try builtin.invoke(id, self, func_reg, nargs, nresults);
    }

    /// Sugar Layer: Handle VM error with user-friendly reporting
    /// Translates internal VM errors to Lua error messages
    fn handleVMError(self: *VM, vm_error: anyerror) !void {
        // Check if this is a VM internal error that should be translated
        const vm_error_typed = switch (vm_error) {
            error.PcOutOfRange => ErrorHandler.VMError.PcOutOfRange,
            error.CallStackOverflow => ErrorHandler.VMError.CallStackOverflow,
            error.ArithmeticError => ErrorHandler.VMError.ArithmeticError,
            error.OrderComparisonError => ErrorHandler.VMError.OrderComparisonError,
            error.InvalidForLoopInit => ErrorHandler.VMError.InvalidForLoopInit,
            error.InvalidForLoopStep => ErrorHandler.VMError.InvalidForLoopStep,
            error.InvalidForLoopLimit => ErrorHandler.VMError.InvalidForLoopLimit,
            error.NotAFunction => ErrorHandler.VMError.NotAFunction,
            error.InvalidTableKey => ErrorHandler.VMError.InvalidTableKey,
            error.InvalidTableOperation => ErrorHandler.VMError.InvalidTableOperation,
            error.UnknownOpcode => ErrorHandler.VMError.UnknownOpcode,
            error.VariableReturnNotImplemented => ErrorHandler.VMError.VariableReturnNotImplemented,
            else => return vm_error, // Pass through non-VM errors
        };

        // Use Sugar Layer to translate and report the error
        const error_message = ErrorHandler.reportError(vm_error_typed, self.allocator, null) catch |err| switch (err) {
            error.OutOfMemory => "out of memory during error reporting",
            else => "unknown error occurred",
        };
        defer if (error_message.len > 0) self.allocator.free(error_message);

        // Print the user-friendly error message
        const stderr = std.io.getStdErr().writer();
        stderr.print("{s}\n", .{error_message}) catch {};

        // Propagate the original error for proper control flow
        return vm_error;
    }

    const ArithOp = enum { add, sub, mul, div, idiv, mod, pow };
    const BitwiseOp = enum { band, bor, bxor };

    // Push a new call info onto the call stack
    pub fn pushCallInfo(self: *VM, func: *const Proto, base: u32, ret_base: u32, nresults: i16) !*CallInfo {
        if (self.callstack_size >= self.callstack.len) {
            return error.CallStackOverflow;
        }

        // TODO: Move CallInfo creation into CallInfo.initCall().
        // Currently VM constructs call frames directly for clarity.
        // Revisit after CALL / TAILCALL / RETURN semantics are fully stabilized.

        const new_ci = &self.callstack[self.callstack_size];
        new_ci.* = CallInfo{
            .func = func,
            .pc = func.code.ptr,
            .base = base,
            .ret_base = ret_base,
            .savedpc = null,
            .nresults = nresults,
            .previous = self.ci,
        };

        self.callstack_size += 1;
        self.ci = new_ci;
        self.base = base;

        return new_ci;
    }

    // Pop a call info from the call stack
    pub fn popCallInfo(self: *VM) void {
        if (self.ci) |ci| {
            if (ci.previous) |prev| {
                self.ci = prev;
                self.base = prev.base;
                if (self.callstack_size > 0) {
                    self.callstack_size -= 1;
                }
            }
        }
    }

    fn arithBinary(self: *VM, inst: Instruction, comptime tag: ArithOp) !void {
        const a = inst.getA();
        const b = inst.getB();
        const c = inst.getC();
        const vb = &self.stack[self.base + b];
        const vc = &self.stack[self.base + c];

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
                self.stack[self.base + a] = .{ .integer = res };
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

        self.stack[self.base + a] = .{ .number = res };
    }

    fn luaFloorDiv(a: f64, b: f64) f64 {
        return @floor(a / b);
    }

    fn luaMod(a: f64, b: f64) f64 {
        return a - luaFloorDiv(a, b) * b;
    }

    fn bitwiseBinary(self: *VM, inst: Instruction, comptime tag: BitwiseOp) !void {
        // Bitwise operations in Lua 5.3+ work only on integers
        // Floats with no fractional part can be converted to integers
        const a = inst.getA();
        const b = inst.getB();
        const c = inst.getC();
        const vb = &self.stack[self.base + b];
        const vc = &self.stack[self.base + c];

        // Helper to convert value to integer for bitwise ops
        const toInt = struct {
            fn convert(v: *const TValue) !i64 {
                if (v.isInteger()) {
                    return v.integer;
                } else if (v.toNumber()) |n| {
                    // Check if it's a whole number
                    if (@floor(n) == n) {
                        return @as(i64, @intFromFloat(n));
                    }
                }
                return error.ArithmeticError;
            }
        }.convert;

        const ib = try toInt(vb);
        const ic = try toInt(vc);

        const res = switch (tag) {
            .band => ib & ic,
            .bor => ib | ic,
            .bxor => ib ^ ic,
        };

        self.stack[self.base + a] = .{ .integer = res };
    }

    fn eqOp(a: TValue, b: TValue) bool {
        return a.eql(b);
    }

    fn ltOp(a: TValue, b: TValue) !bool {
        const na = a.toNumber();
        const nb = b.toNumber();
        if (na != null and nb != null) {
            // In Lua, any comparison with NaN returns false
            if (std.math.isNan(na.?) or std.math.isNan(nb.?)) {
                return false;
            }
            return na.? < nb.?;
        }
        // TODO: string comparison will be added when string type is implemented
        // Non-numeric types cannot be ordered
        return error.OrderComparisonError;
    }

    fn leOp(a: TValue, b: TValue) !bool {
        const na = a.toNumber();
        const nb = b.toNumber();
        if (na != null and nb != null) {
            // In Lua, any comparison with NaN returns false
            if (std.math.isNan(na.?) or std.math.isNan(nb.?)) {
                return false;
            }
            return na.? <= nb.?;
        }
        // TODO: string comparison will be added when string type is implemented
        // Non-numeric types cannot be ordered
        return error.OrderComparisonError;
    }

    pub const ReturnValue = union(enum) {
        none,
        single: TValue,
        multiple: []TValue,
    };

    // TODO: Move CallInfo initialization to CallInfo.initMain().
    // This frame is a VM bootstrap (root frame), not a normal call frame.
    // Separate initialization when CallInfo responsibilities are clarified.
    fn setupMainFrame(self: *VM, proto: *const Proto) void {
        self.base_ci = CallInfo{
            .func = proto,
            .pc = proto.code.ptr,
            .base = 0,
            .ret_base = 0,
            .savedpc = null,
            .nresults = -1,
            .previous = null,
        };
        self.ci = &self.base_ci;
        self.base = 0;
        self.top = proto.maxstacksize;
    }

    pub fn execute(self: *VM, proto: *const Proto) !ReturnValue {
        self.setupMainFrame(proto);

        // TODO (mnemonics.do): semantics frozen here.
        // metamethod dispatch will be inserted at marked points.
        // changing this requires revisiting standard library and C API.
        //
        // Keep: fetch/decode/dispatch.
        // Move: stack/base/top mutations, CALL/RETURN frame transitions.
        while (true) {
            var ci = self.ci.?;
            const inst = try ci.fetch();

            switch (inst.getOpCode()) {
                .MOVE => {
                    const a = inst.getA();
                    const b = inst.getB();
                    self.stack[self.base + a] = self.stack[self.base + b];
                },
                .LOADK => {
                    const a = inst.getA();
                    const bx = inst.getBx();
                    self.stack[self.base + a] = ci.func.k[bx];
                },
                .LOADKX => {
                    // LOADKX A: R[A] := K[EXTRAARG]
                    // Extended constant loading - constant index comes from next EXTRAARG instruction
                    const a = inst.getA();
                    // Fetch the EXTRAARG instruction (2-word opcode)
                    const extraarg_inst = try ci.fetchExtraArg();
                    const ax = extraarg_inst.getAx();
                    self.stack[self.base + a] = ci.func.k[ax];
                },
                .LOADI => {
                    // LOADI A sBx: R[A] := sBx (signed immediate integer)
                    const a = inst.getA();
                    const sbx = inst.getSBx();
                    self.stack[self.base + a] = .{ .integer = @as(i64, sbx) };
                },
                .LOADF => {
                    // LOADF A sBx: R[A] := (lua_Number)sBx (signed immediate float)
                    const a = inst.getA();
                    const sbx = inst.getSBx();
                    self.stack[self.base + a] = .{ .number = @as(f64, @floatFromInt(sbx)) };
                },
                .LOADFALSE => {
                    // LOADFALSE A: R[A] := false
                    const a = inst.getA();
                    self.stack[self.base + a] = .{ .boolean = false };
                },
                .LFALSESKIP => {
                    // LFALSESKIP A: R[A] := false; pc++
                    const a = inst.getA();
                    self.stack[self.base + a] = .{ .boolean = false };
                    ci.skip();
                },
                .LOADTRUE => {
                    // LOADTRUE A: R[A] := true
                    const a = inst.getA();
                    self.stack[self.base + a] = .{ .boolean = true };
                },
                .LOADNIL => {
                    const a = inst.getA();
                    const b = inst.getB();
                    var i: u8 = 0;
                    while (i <= b) : (i += 1) {
                        self.stack[self.base + a + i] = .nil;
                    }
                },
                .ADDI => {
                    const a = inst.getA();
                    const b = inst.getB();
                    const sc = inst.getC();
                    const vb = &self.stack[self.base + b];

                    // ADDI uses C as a signed byte (-128 to 127)
                    const imm = @as(i8, @bitCast(@as(u8, sc)));

                    if (vb.isInteger()) {
                        const add_result = @addWithOverflow(vb.integer, @as(i64, imm));
                        if (add_result[1] == 0) {
                            self.stack[self.base + a] = .{ .integer = add_result[0] };
                        } else {
                            // Overflow occurred, fallback to float
                            const n = @as(f64, @floatFromInt(vb.integer)) + @as(f64, @floatFromInt(imm));
                            self.stack[self.base + a] = .{ .number = n };
                        }
                    } else if (vb.toNumber()) |n| {
                        self.stack[self.base + a] = .{ .number = n + @as(f64, @floatFromInt(imm)) };
                    } else {
                        return error.ArithmeticError;
                    }
                },
                .SHLI => {
                    // Shift left immediate
                    const a = inst.getA();
                    const b = inst.getB();
                    const sc = inst.getC();
                    const vb = &self.stack[self.base + b];

                    // Convert value to integer
                    const value = if (vb.isInteger()) vb.integer else if (vb.toNumber()) |n| blk: {
                        if (@floor(n) == n) {
                            break :blk @as(i64, @intFromFloat(n));
                        } else {
                            return error.ArithmeticError;
                        }
                    } else {
                        return error.ArithmeticError;
                    };

                    // C is unsigned immediate shift amount
                    const shift = @as(u8, sc);
                    self.stack[self.base + a] = .{ .integer = std.math.shl(i64, value, @as(u6, @intCast(shift))) };
                },
                .SHRI => {
                    // Shift right immediate (arithmetic)
                    const a = inst.getA();
                    const b = inst.getB();
                    const sc = inst.getC();
                    const vb = &self.stack[self.base + b];

                    // Convert value to integer
                    const value = if (vb.isInteger()) vb.integer else if (vb.toNumber()) |n| blk: {
                        if (@floor(n) == n) {
                            break :blk @as(i64, @intFromFloat(n));
                        } else {
                            return error.ArithmeticError;
                        }
                    } else {
                        return error.ArithmeticError;
                    };

                    // C is unsigned immediate shift amount
                    const shift = @as(u8, sc);
                    self.stack[self.base + a] = .{ .integer = std.math.shr(i64, value, @as(u6, @intCast(shift))) };
                },
                .ADDK => {
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &ci.func.k[c]; // C is always a constant index for ADDK

                    if (vb.isInteger() and vc.isInteger()) {
                        self.stack[self.base + a] = .{ .integer = vb.integer + vc.integer };
                    } else {
                        const nb = vb.toNumber() orelse return error.ArithmeticError;
                        const nc = vc.toNumber() orelse return error.ArithmeticError;
                        self.stack[self.base + a] = .{ .number = nb + nc };
                    }
                },
                .SUBK => {
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &ci.func.k[c];

                    if (vb.isInteger() and vc.isInteger()) {
                        self.stack[self.base + a] = .{ .integer = vb.integer - vc.integer };
                    } else {
                        const nb = vb.toNumber() orelse return error.ArithmeticError;
                        const nc = vc.toNumber() orelse return error.ArithmeticError;
                        self.stack[self.base + a] = .{ .number = nb - nc };
                    }
                },
                .MULK => {
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &proto.k[c];

                    if (vb.isInteger() and vc.isInteger()) {
                        self.stack[self.base + a] = .{ .integer = vb.integer * vc.integer };
                    } else {
                        const nb = vb.toNumber() orelse return error.ArithmeticError;
                        const nc = vc.toNumber() orelse return error.ArithmeticError;
                        self.stack[self.base + a] = .{ .number = nb * nc };
                    }
                },
                .DIVK => {
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &proto.k[c];

                    const nb = vb.toNumber() orelse return error.ArithmeticError;
                    const nc = vc.toNumber() orelse return error.ArithmeticError;
                    if (nc == 0) return error.ArithmeticError;
                    self.stack[self.base + a] = .{ .number = nb / nc };
                },
                .IDIVK => {
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &proto.k[c];

                    const nb = vb.toNumber() orelse return error.ArithmeticError;
                    const nc = vc.toNumber() orelse return error.ArithmeticError;
                    if (nc == 0) return error.ArithmeticError;
                    self.stack[self.base + a] = .{ .number = luaFloorDiv(nb, nc) };
                },
                .MODK => {
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &proto.k[c];

                    const nb = vb.toNumber() orelse return error.ArithmeticError;
                    const nc = vc.toNumber() orelse return error.ArithmeticError;
                    if (nc == 0) return error.ArithmeticError;
                    self.stack[self.base + a] = .{ .number = luaMod(nb, nc) };
                },
                .POWK => {
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &proto.k[c];

                    const nb = vb.toNumber() orelse return error.ArithmeticError;
                    const nc = vc.toNumber() orelse return error.ArithmeticError;
                    self.stack[self.base + a] = .{ .number = std.math.pow(f64, nb, nc) };
                },
                .BANDK => {
                    // Bitwise AND with constant
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &proto.k[c];

                    // Helper to convert value to integer
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
                    self.stack[self.base + a] = .{ .integer = ib & ic };
                },
                .BORK => {
                    // Bitwise OR with constant
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &proto.k[c];

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
                    self.stack[self.base + a] = .{ .integer = ib | ic };
                },
                .BXORK => {
                    // Bitwise XOR with constant
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &proto.k[c];

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
                    self.stack[self.base + a] = .{ .integer = ib ^ ic };
                },
                .ADD => {
                    try self.arithBinary(inst, .add);
                },
                .SUB => {
                    try self.arithBinary(inst, .sub);
                },
                .MUL => {
                    try self.arithBinary(inst, .mul);
                },
                .DIV => {
                    try self.arithBinary(inst, .div);
                },
                .IDIV => {
                    try self.arithBinary(inst, .idiv);
                },
                .MOD => {
                    try self.arithBinary(inst, .mod);
                },
                .POW => {
                    try self.arithBinary(inst, .pow);
                },
                .BAND => {
                    // Bitwise AND (&)
                    try self.bitwiseBinary(inst, .band);
                },
                .BOR => {
                    // Bitwise OR (|)
                    try self.bitwiseBinary(inst, .bor);
                },
                .BXOR => {
                    // Bitwise XOR (~)
                    // Note: In Lua, ~ is XOR for binary ops, NOT for unary
                    try self.bitwiseBinary(inst, .bxor);
                },
                .SHL => {
                    // Shift left (<<)
                    // In Lua, negative shifts shift in opposite direction
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &self.stack[self.base + c];

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

                    // Lua behavior: negative shift does right shift
                    const result = if (shift >= 0) blk: {
                        const s = std.math.cast(u6, shift) orelse 63;
                        break :blk std.math.shl(i64, value, s);
                    } else blk: {
                        const s = std.math.cast(u6, -shift) orelse 63;
                        break :blk std.math.shr(i64, value, s);
                    };

                    self.stack[self.base + a] = .{ .integer = result };
                },
                .SHR => {
                    // Shift right (>>)
                    // In Lua, this is arithmetic (sign-extending) shift
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &self.stack[self.base + c];

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

                    // Lua behavior: negative shift does left shift
                    const result = if (shift >= 0) blk: {
                        const s = std.math.cast(u6, shift) orelse 63;
                        break :blk std.math.shr(i64, value, s);
                    } else blk: {
                        const s = std.math.cast(u6, -shift) orelse 63;
                        break :blk std.math.shl(i64, value, s);
                    };

                    self.stack[self.base + a] = .{ .integer = result };
                },
                .UNM => {
                    const a = inst.getA();
                    const b = inst.getB();
                    const vb = &self.stack[self.base + b];
                    if (vb.isInteger()) {
                        self.stack[self.base + a] = .{ .integer = -vb.integer };
                    } else if (vb.toNumber()) |n| {
                        self.stack[self.base + a] = .{ .number = -n };
                    } else {
                        return error.ArithmeticError;
                    }
                },
                .NOT => {
                    const a = inst.getA();
                    const b = inst.getB();
                    const vb = &self.stack[self.base + b];
                    self.stack[self.base + a] = .{ .boolean = !vb.toBoolean() };
                },
                .BNOT => {
                    // Bitwise NOT (~)
                    // Lua 5.3+ requires integer operand
                    const a = inst.getA();
                    const b = inst.getB();
                    const vb = &self.stack[self.base + b];

                    if (vb.isInteger()) {
                        // Direct integer path
                        self.stack[self.base + a] = .{ .integer = ~vb.integer };
                    } else {
                        // Try to convert to integer
                        // In Lua, floats with no fractional part can be converted
                        if (vb.toNumber()) |n| {
                            // Check if it's a whole number
                            if (@floor(n) == n) {
                                const i = @as(i64, @intFromFloat(n));
                                self.stack[self.base + a] = .{ .integer = ~i };
                            } else {
                                return error.ArithmeticError;
                            }
                        } else {
                            return error.ArithmeticError;
                        }
                    }
                },
                .LEN => {
                    // Length operator (#)
                    const a = inst.getA();
                    const b = inst.getB();
                    const vb = &self.stack[self.base + b];

                    if (vb.isString()) {
                        self.stack[self.base + a] = .{ .integer = @as(i64, @intCast(vb.string.asSlice().len)) };
                    } else {
                        // TODO: table length support when tables are implemented
                        return error.LengthError;
                    }
                },
                .CONCAT => {
                    // String concatenation: R[A] := R[B] .. R[B+1] .. ... .. R[C]
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();

                    // Calculate total length needed
                    var total_len: usize = 0;
                    for (b..c + 1) |i| {
                        const val = &self.stack[self.base + i];
                        if (val.isString()) {
                            total_len += val.string.asSlice().len;
                        } else if (val.isInteger()) {
                            // Convert integer to string to get length
                            var buf: [32]u8 = undefined;
                            const str = std.fmt.bufPrint(&buf, "{d}", .{val.integer}) catch {
                                return error.ArithmeticError;
                            };
                            total_len += str.len;
                        } else if (val.isNumber()) {
                            // Convert number to string to get length
                            var buf: [32]u8 = undefined;
                            const str = std.fmt.bufPrint(&buf, "{d}", .{val.number}) catch {
                                return error.ArithmeticError;
                            };
                            total_len += str.len;
                        } else {
                            return error.ArithmeticError; // Cannot concatenate non-string/number values
                        }
                    }

                    // Allocate temporary buffer for concatenation
                    const result_buf = try self.allocator.alloc(u8, total_len);
                    defer self.allocator.free(result_buf);
                    var offset: usize = 0;

                    // Concatenate all values into buffer
                    for (b..c + 1) |i| {
                        const val = &self.stack[self.base + i];
                        if (val.isString()) {
                            const str_slice = val.string.asSlice();
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

                    // Allocate through GC and store result
                    const result_str = try self.gc.allocString(result_buf);
                    self.stack[self.base + a] = .{ .string = result_str };
                },
                .EQ => {
                    const negate = inst.getA(); // A is negate flag (0: normal, 1: negated)
                    const b = inst.getB();
                    const c = inst.getC();
                    const is_true = eqOp(self.stack[self.base + b], self.stack[self.base + c]);
                    // if (is_true != (negate != 0)) then skip next instruction
                    if ((is_true and negate == 0) or (!is_true and negate != 0)) {
                        ci.skip();
                    }
                },
                .LT => {
                    const negate = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const is_true = ltOp(self.stack[self.base + b], self.stack[self.base + c]) catch |err| switch (err) {
                        error.OrderComparisonError => return error.ArithmeticError,
                        else => return err,
                    };
                    if ((is_true and negate == 0) or (!is_true and negate != 0)) {
                        ci.skip();
                    }
                },
                .LE => {
                    const negate = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const is_true = leOp(self.stack[self.base + b], self.stack[self.base + c]) catch |err| switch (err) {
                        error.OrderComparisonError => return error.ArithmeticError,
                        else => return err,
                    };
                    if ((is_true and negate == 0) or (!is_true and negate != 0)) {
                        ci.skip();
                    }
                },
                .JMP => {
                    const sj = inst.getsJ();
                    // PC is already pointing to next instruction after this JMP
                    // sJ is relative to the instruction AFTER the JMP
                    try ci.jumpRel(sj);
                },
                .TEST => {
                    const a = inst.getA();
                    const k = inst.getk();
                    const va = &self.stack[self.base + a];
                    // if not (truth(va) == k) then skip
                    if (va.toBoolean() != k) {
                        ci.skip();
                    }
                },
                .TESTSET => {
                    const a = inst.getA();
                    const b = inst.getB();
                    const k = inst.getk();
                    const vb = &self.stack[self.base + b];
                    if (vb.toBoolean() == k) {
                        // True: copy value and continue execution (no skip)
                        self.stack[self.base + a] = vb.*;
                    } else {
                        // False: skip next instruction
                        ci.skip();
                    }
                },
                .FORPREP => {
                    const a = inst.getA();
                    const sbx = inst.getSBx();
                    const v_init = self.stack[self.base + a];
                    const v_limit = self.stack[self.base + a + 1];
                    const v_step = self.stack[self.base + a + 2];

                    if (v_init.isInteger() and v_limit.isInteger() and v_step.isInteger()) {
                        const ii = v_init.integer;
                        const is = v_step.integer;
                        // Check for zero step
                        if (is == 0) return error.InvalidForLoopStep;

                        const sub_result = @subWithOverflow(ii, is);
                        if (sub_result[1] == 0) {
                            self.stack[self.base + a] = .{ .integer = sub_result[0] };
                        } else {
                            // Overflow occurred, fallback to float path
                            const i = @as(f64, @floatFromInt(ii));
                            const s = @as(f64, @floatFromInt(is));
                            self.stack[self.base + a] = .{ .number = i - s };
                        }
                    } else {
                        const i = v_init.toNumber() orelse return error.InvalidForLoopInit;
                        const s = v_step.toNumber() orelse return error.InvalidForLoopStep;
                        // Check for zero step
                        if (s == 0) return error.InvalidForLoopStep;
                        self.stack[self.base + a] = .{ .number = i - s }; // float path
                    }

                    try ci.jumpRel(sbx);
                },
                .FORLOOP => {
                    const a = inst.getA();
                    const sbx = inst.getSBx();
                    const idx = &self.stack[self.base + a];
                    const limit = &self.stack[self.base + a + 1];
                    const step = &self.stack[self.base + a + 2];

                    if (idx.isInteger() and limit.isInteger() and step.isInteger()) {
                        // integer path
                        const i = idx.integer;
                        const l = limit.integer;
                        const s = step.integer;

                        // Compare first, then add (safer order)
                        if (s > 0) {
                            if (i < l) {
                                const add_result = @addWithOverflow(i, s);
                                if (add_result[1] == 0 and add_result[0] <= l) {
                                    const new_i = add_result[0];
                                    idx.* = .{ .integer = new_i };
                                    self.stack[self.base + a + 3] = .{ .integer = new_i };
                                    if (sbx >= 0) ci.pc += @as(usize, @intCast(sbx)) else ci.pc -= @as(usize, @intCast(-sbx));
                                }
                            }
                        } else if (s < 0) {
                            if (i > l) {
                                const add_result = @addWithOverflow(i, s);
                                if (add_result[1] == 0 and add_result[0] >= l) {
                                    const new_i = add_result[0];
                                    idx.* = .{ .integer = new_i };
                                    self.stack[self.base + a + 3] = .{ .integer = new_i };
                                    if (sbx >= 0) ci.pc += @as(usize, @intCast(sbx)) else ci.pc -= @as(usize, @intCast(-sbx));
                                }
                            }
                        }
                        // s == 0 should not happen (caught in FORPREP)
                    } else {
                        // float path
                        const i = idx.toNumber() orelse return error.InvalidForLoopInit;
                        const l = limit.toNumber() orelse return error.InvalidForLoopLimit;
                        const s = step.toNumber() orelse return error.InvalidForLoopStep;

                        const new_i = i + s;
                        const cont = if (s > 0) (new_i <= l) else (new_i >= l);
                        if (cont) {
                            idx.* = .{ .number = new_i };
                            self.stack[self.base + a + 3] = .{ .number = new_i };
                            if (sbx >= 0) ci.pc += @as(usize, @intCast(sbx)) else ci.pc -= @as(usize, @intCast(-sbx));
                        }
                    }
                },
                .CALL => {
                    // CALL A B C: R(A),...,R(A+C-2) := R(A)(R(A+1),...,R(A+B-1))
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();

                    // Get the function value
                    const func_val = &self.stack[self.base + a];

                    // Handle function calls
                    if (func_val.isFunction()) {
                        const function = func_val.function;
                        const nargs: u32 = if (b > 0) b - 1 else 0;
                        const nresults: u32 = if (c > 0) c - 1 else 0;

                        switch (function) {
                            .native => |native_fn| {
                                // VM just dispatches to native function
                                try self.callNative(native_fn.id, a, nargs, nresults);
                            },
                            .bytecode => |func_proto| {
                                // Handle bytecode function calls

                                const new_base = self.base + a;
                                const ret_base = self.base + a;

                                // Move arguments to correct positions if needed
                                // Arguments are already at R(A+1)..R(A+nargs), but callee expects them at R(0)..R(nargs-1)
                                // Since callee base = R(A), we need to shift arguments down by 1
                                if (nargs > 0) {
                                    var i: u32 = 0;
                                    while (i < nargs) : (i += 1) {
                                        self.stack[new_base + i] = self.stack[new_base + 1 + i];
                                    }
                                }

                                // Initialize remaining parameters to nil
                                var i: u32 = nargs;
                                while (i < func_proto.numparams) : (i += 1) {
                                    self.stack[new_base + i] = .nil;
                                }

                                _ = try self.pushCallInfo(func_proto, new_base, ret_base, @intCast(nresults));
                                self.top = new_base + func_proto.maxstacksize;
                            },
                        }
                        continue;
                    }

                    if (!func_val.isClosure()) {
                        return error.NotAFunction;
                    }
                    const closure = func_val.closure;
                    const func_proto = closure.proto;

                    // Calculate number of arguments
                    const nargs: u32 = if (b > 0) b - 1 else blk: {
                        // B == 0 means use all values from R(A+1) to top
                        const arg_start = self.base + a + 1;
                        break :blk self.top - arg_start;
                    };

                    // Calculate expected results
                    const nresults: i16 = if (c > 0) @as(i16, @intCast(c - 1)) else -1;

                    // New base for called function (Lua convention: callee starts at R(A))
                    const new_base = self.base + a;
                    const ret_base = self.base + a; // Results go back to R(A)

                    // Move arguments to correct positions if needed
                    // Arguments are already at R(A+1)..R(A+nargs), but callee expects them at R(0)..R(nargs-1)
                    // Since callee base = R(A), we need to shift arguments down by 1
                    if (nargs > 0) {
                        var i: u32 = 0;
                        while (i < nargs) : (i += 1) {
                            self.stack[new_base + i] = self.stack[new_base + 1 + i];
                        }
                    }

                    // Initialize remaining parameters to nil
                    var i: u32 = nargs;
                    while (i < func_proto.numparams) : (i += 1) {
                        self.stack[new_base + i] = .nil;
                    }

                    // Push new call info
                    _ = try self.pushCallInfo(func_proto, new_base, ret_base, nresults);

                    // Update top for the new function
                    self.top = new_base + func_proto.maxstacksize;
                },
                .RETURN => {
                    const a = inst.getA();
                    const b = inst.getB();

                    // Handle returns from nested calls
                    if (self.ci.?.previous != null) {
                        // We're returning from a nested call
                        const returning_ci = self.ci.?;
                        const nresults = returning_ci.nresults;
                        const dst_base = returning_ci.ret_base; // Where to place results in caller's frame

                        // Pop the call info
                        self.popCallInfo();

                        // Now handle copying results back
                        if (b == 0) {
                            // Return all values from R[A] to top
                            // TODO: implement variable return
                            return error.VariableReturnNotImplemented;
                        } else if (b == 1) {
                            // No return values
                            // Set expected number of results to nil
                            if (nresults > 0) {
                                var i: u16 = 0;
                                while (i < nresults) : (i += 1) {
                                    self.stack[dst_base + i] = .nil;
                                }
                            }
                        } else {
                            // Return b-1 values starting from R[A]
                            const ret_count = b - 1;

                            // Copy return values from callee's R[A+i] to caller's dst_base+i
                            if (nresults < 0) {
                                // Multiple results expected
                                var i: u16 = 0;
                                while (i < ret_count) : (i += 1) {
                                    self.stack[dst_base + i] = self.stack[returning_ci.base + a + i];
                                }
                                self.top = dst_base + ret_count;
                            } else {
                                // Fixed number of results
                                var i: u16 = 0;
                                while (i < nresults) : (i += 1) {
                                    if (i < ret_count) {
                                        self.stack[dst_base + i] = self.stack[returning_ci.base + a + i];
                                    } else {
                                        self.stack[dst_base + i] = .nil;
                                    }
                                }
                            }
                        }

                        // Continue execution in the calling function
                        continue;
                    }

                    // This is a return from the main function
                    if (b == 0) {
                        // return no values (used internally for tailcall)
                        return .none;
                    } else if (b == 1) {
                        // return nothing (return)
                        return .none;
                    } else if (b == 2) {
                        // return 1 value from R[A]
                        return .{ .single = self.stack[self.base + a] };
                    } else {
                        // return n-1 values from R[A]..R[A+n-2]
                        const count = b - 1;
                        const values = self.stack[self.base + a .. self.base + a + count];
                        return .{ .multiple = values };
                    }
                },
                .RETURN0 => {
                    // Return 0 values (specialized RETURN with B=1)
                    // Handle returns from nested calls
                    if (self.ci.?.previous != null) {
                        // We're returning from a nested call
                        const returning_ci = self.ci.?;
                        const nresults = returning_ci.nresults;
                        const dst_base = returning_ci.ret_base;

                        // Pop the call info
                        self.popCallInfo();

                        // Set expected number of results to nil
                        if (nresults > 0) {
                            var i: u16 = 0;
                            while (i < nresults) : (i += 1) {
                                self.stack[dst_base + i] = .nil;
                            }
                        }

                        // Continue execution in the calling function
                        continue;
                    }

                    // This is a return from the main function
                    return .none;
                },
                .RETURN1 => {
                    // Return 1 value from R[A] (specialized RETURN with B=2)
                    const a = inst.getA();

                    // Handle returns from nested calls
                    if (self.ci.?.previous != null) {
                        // We're returning from a nested call
                        const returning_ci = self.ci.?;
                        const nresults = returning_ci.nresults;
                        const dst_base = returning_ci.ret_base;

                        // Pop the call info
                        self.popCallInfo();

                        // Copy the single return value
                        if (nresults < 0) {
                            // Multiple results expected - return 1 value
                            self.stack[dst_base] = self.stack[returning_ci.base + a];
                            self.top = dst_base + 1;
                        } else {
                            // Fixed number of results
                            if (nresults > 0) {
                                self.stack[dst_base] = self.stack[returning_ci.base + a];
                                // Fill remaining with nil
                                var i: u16 = 1;
                                while (i < nresults) : (i += 1) {
                                    self.stack[dst_base + i] = .nil;
                                }
                            }
                        }

                        // Continue execution in the calling function
                        continue;
                    }

                    // This is a return from the main function
                    return .{ .single = self.stack[self.base + a] };
                },
                .GETTABUP => {
                    // GETTABUP A B C: R[A] := UpValue[B][K[C]]
                    // For globals: R[A] := _ENV[K[C]]
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    _ = b; // Assume B=0 for _ENV (global environment)

                    const key_val = ci.func.k[c];
                    if (key_val.isString()) {
                        const key = key_val.string.asSlice();
                        const value = self.globals.get(key) orelse .nil;
                        self.stack[self.base + a] = value;
                    } else {
                        return error.InvalidTableKey;
                    }
                },
                .SETTABUP => {
                    // SETTABUP A B C: UpValue[A][K[B]] := R[C]
                    // For globals: _ENV[K[B]] := R[C]
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    _ = a; // Assume A=0 for _ENV (global environment)

                    const key_val = ci.func.k[b];
                    const value = self.stack[self.base + c];
                    if (key_val.isString()) {
                        const key = key_val.string.asSlice();
                        try self.globals.set(key, value);
                    } else {
                        return error.InvalidTableKey;
                    }
                },
                .GETUPVAL => {
                    // Legacy opcode - might need proper implementation later
                    // For now, set to nil
                    const a = inst.getA();
                    const b = inst.getB();
                    _ = b; // Suppress unused warning
                    self.stack[self.base + a] = .nil;
                },
                .SETUPVAL => {
                    // SETUPVAL A B: UpValue[B] := R[A]
                    // For now, this is a no-op since we don't have proper upvalue implementation
                    // TODO: Implement proper upvalue setting when upvalues are added
                    const a = inst.getA();
                    const b = inst.getB();
                    _ = a; // Suppress unused warning
                    _ = b; // Suppress unused warning
                },
                .GETTABLE => {
                    // GETTABLE A B C: R[A] := R[B][R[C]]
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const table_val = self.stack[self.base + b];
                    const key_val = self.stack[self.base + c];

                    if (table_val.isTable() and key_val.isString()) {
                        const table = table_val.table;
                        const key = key_val.string.asSlice();
                        const value = table.get(key) orelse .nil;
                        self.stack[self.base + a] = value;
                    } else {
                        return error.InvalidTableOperation;
                    }
                },
                .SETTABLE => {
                    // SETTABLE A B C: R[A][R[B]] := R[C]
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const table_val = self.stack[self.base + a];
                    const key_val = self.stack[self.base + b];
                    const value = self.stack[self.base + c];

                    if (table_val.isTable() and key_val.isString()) {
                        const table = table_val.table;
                        const key = key_val.string.asSlice();
                        try table.set(key, value);
                    } else {
                        return error.InvalidTableOperation;
                    }
                },
                .GETI => {
                    // GETI A B C: R[A] := R[B][C] (C is integer immediate)
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const table_val = self.stack[self.base + b];

                    if (table_val.isTable()) {
                        const table = table_val.table;
                        // Convert integer index to string key (Lua tables use string keys internally)
                        var key_buffer: [32]u8 = undefined;
                        const key = std.fmt.bufPrint(&key_buffer, "{d}", .{c}) catch {
                            return error.InvalidTableKey;
                        };
                        const value = table.get(key) orelse .nil;
                        self.stack[self.base + a] = value;
                    } else {
                        return error.InvalidTableOperation;
                    }
                },
                .SETI => {
                    // SETI A B C: R[A][B] := R[C] (B is integer immediate)
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const table_val = self.stack[self.base + a];
                    const value = self.stack[self.base + c];

                    if (table_val.isTable()) {
                        const table = table_val.table;
                        // Convert integer index to string key
                        var key_buffer: [32]u8 = undefined;
                        const key = std.fmt.bufPrint(&key_buffer, "{d}", .{b}) catch {
                            return error.InvalidTableKey;
                        };
                        try table.set(key, value);
                    } else {
                        return error.InvalidTableOperation;
                    }
                },
                .GETFIELD => {
                    // GETFIELD A B C: R[A] := R[B][K[C]] (C is constant string index)
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const table_val = self.stack[self.base + b];
                    const key_val = ci.func.k[c];

                    if (table_val.isTable() and key_val.isString()) {
                        const table = table_val.table;
                        const key = key_val.string.asSlice();
                        const value = table.get(key) orelse .nil;
                        self.stack[self.base + a] = value;
                    } else {
                        return error.InvalidTableOperation;
                    }
                },
                .SETFIELD => {
                    // SETFIELD A B C: R[A][K[B]] := R[C] (B is constant string index)
                    const a = inst.getA();
                    const b = inst.getB();
                    const c = inst.getC();
                    const table_val = self.stack[self.base + a];
                    const key_val = ci.func.k[b];
                    const value = self.stack[self.base + c];

                    if (table_val.isTable() and key_val.isString()) {
                        const table = table_val.table;
                        const key = key_val.string.asSlice();
                        try table.set(key, value);
                    } else {
                        return error.InvalidTableOperation;
                    }
                },
                .NEWTABLE => {
                    // Basic table creation (not fully implemented)
                    // For now, just set to nil
                    const a = inst.getA();
                    self.stack[self.base + a] = .nil;
                },
                .EQK => {
                    // EQK A B C: if not (R[B] == K[C]) then pc++
                    const a = inst.getA(); // negate flag
                    const b = inst.getB();
                    const c = inst.getC();
                    const is_true = eqOp(self.stack[self.base + b], ci.func.k[c]);
                    if ((is_true and a == 0) or (!is_true and a != 0)) {
                        ci.skip();
                    }
                },
                .EQI => {
                    // EQI A B C: if not (R[B] == C) then pc++ (C is signed immediate)
                    const a = inst.getA(); // negate flag
                    const b = inst.getB();
                    const sc = inst.getC();
                    const imm = @as(i8, @bitCast(@as(u8, sc))); // signed byte
                    const imm_val = TValue{ .integer = @as(i64, imm) };
                    const is_true = eqOp(self.stack[self.base + b], imm_val);
                    if ((is_true and a == 0) or (!is_true and a != 0)) {
                        ci.skip();
                    }
                },
                .LTI => {
                    // LTI A B C: if not (R[B] < C) then pc++ (C is signed immediate)
                    const a = inst.getA(); // negate flag
                    const b = inst.getB();
                    const sc = inst.getC();
                    const imm = @as(i8, @bitCast(@as(u8, sc))); // signed byte
                    const imm_val = TValue{ .integer = @as(i64, imm) };
                    const is_true = ltOp(self.stack[self.base + b], imm_val) catch |err| switch (err) {
                        error.OrderComparisonError => return error.ArithmeticError,
                        else => return err,
                    };
                    if ((is_true and a == 0) or (!is_true and a != 0)) {
                        ci.skip();
                    }
                },
                .LEI => {
                    // LEI A B C: if not (R[B] <= C) then pc++ (C is signed immediate)
                    const a = inst.getA(); // negate flag
                    const b = inst.getB();
                    const sc = inst.getC();
                    const imm = @as(i8, @bitCast(@as(u8, sc))); // signed byte
                    const imm_val = TValue{ .integer = @as(i64, imm) };
                    const is_true = leOp(self.stack[self.base + b], imm_val) catch |err| switch (err) {
                        error.OrderComparisonError => return error.ArithmeticError,
                        else => return err,
                    };
                    if ((is_true and a == 0) or (!is_true and a != 0)) {
                        ci.skip();
                    }
                },
                .GTI => {
                    // GTI A B C: if not (R[B] > C) then pc++ (C is signed immediate)
                    const a = inst.getA(); // negate flag
                    const b = inst.getB();
                    const sc = inst.getC();
                    const imm = @as(i8, @bitCast(@as(u8, sc))); // signed byte
                    const imm_val = TValue{ .integer = @as(i64, imm) };
                    // R[B] > C is equivalent to C < R[B]
                    const is_true = ltOp(imm_val, self.stack[self.base + b]) catch |err| switch (err) {
                        error.OrderComparisonError => return error.ArithmeticError,
                        else => return err,
                    };
                    if ((is_true and a == 0) or (!is_true and a != 0)) {
                        ci.skip();
                    }
                },
                .GEI => {
                    // GEI A B C: if not (R[B] >= C) then pc++ (C is signed immediate)
                    const a = inst.getA(); // negate flag
                    const b = inst.getB();
                    const sc = inst.getC();
                    const imm = @as(i8, @bitCast(@as(u8, sc))); // signed byte
                    const imm_val = TValue{ .integer = @as(i64, imm) };
                    // R[B] >= C is equivalent to C <= R[B]
                    const is_true = leOp(imm_val, self.stack[self.base + b]) catch |err| switch (err) {
                        error.OrderComparisonError => return error.ArithmeticError,
                        else => return err,
                    };
                    if ((is_true and a == 0) or (!is_true and a != 0)) {
                        ci.skip();
                    }
                },
                .CLOSE => {
                    // CLOSE A: close upvalues from R[A] upward
                    // For now, this is a no-op since we don't have proper upvalue implementation
                    // TODO: Implement proper upvalue closing when upvalues are added
                    const a = inst.getA();
                    _ = a; // Suppress unused warning
                },
                .TBC => {
                    // TBC A: mark R[A] as to-be-closed variable
                    // For now, this is a no-op since we don't have proper to-be-closed implementation
                    // TODO: Implement proper to-be-closed marking when resource management is added
                    const a = inst.getA();
                    _ = a; // Suppress unused warning
                },
                .EXTRAARG => {
                    // EXTRAARG Ax: Extra argument for preceding instruction
                    // This instruction provides additional argument data for the previous instruction
                    // It should not be executed independently - handled by instructions like LOADKX
                    return error.UnknownOpcode; // Should not be executed directly
                },
                else => return error.UnknownOpcode,
            }
        }
    }
};
