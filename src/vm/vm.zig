const std = @import("std");
const TValue = @import("../core/value.zig").TValue;
const Closure = @import("../core/closure.zig").Closure;
const Proto = @import("../core/proto.zig").Proto;
const Table = @import("../core/table.zig").Table;
const Function = @import("../core/function.zig").Function;
const NativeFnId = @import("../core/native.zig").NativeFnId;
const opcodes = @import("../compiler/opcodes.zig");
const OpCode = opcodes.OpCode;
const Instruction = opcodes.Instruction;
const builtin = @import("../builtin/dispatch.zig");

// CallInfo represents a function call in the call stack
pub const CallInfo = struct {
    func: *const Proto,
    pc: [*]const Instruction,
    base: u32,
    ret_base: u32, // Where to place return values in caller's frame
    savedpc: ?[*]const Instruction, // saved pc for yielding
    nresults: i16, // expected number of results (-1 = multiple)
    previous: ?*CallInfo, // previous frame in the call stack
};

pub const VM = struct {
    stack: [256]TValue,
    stack_last: u32,
    top: u32,
    base: u32,
    ci: ?*CallInfo,
    base_ci: CallInfo,
    callstack: [20]CallInfo, // Support up to 20 nested calls
    callstack_size: u8,
    globals: *Table,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator, // TODO: Replace with GC when implemented

    pub fn init(allocator: std.mem.Allocator) !VM {
        const globals = try allocator.create(Table);
        globals.* = Table.init(allocator);

        // Initialize global environment
        try builtin.initGlobalEnvironment(globals, allocator);

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
            .arena = std.heap.ArenaAllocator.init(allocator), // TODO: Replace with GC.init()
        };
        for (&vm.stack) |*v| {
            v.* = .nil;
        }
        return vm;
    }

    pub fn deinit(self: *VM) void {
        // Clean up arena allocator
        // TODO: Replace with GC.deinit() when implemented
        self.arena.deinit();

        // Clean up io table
        if (self.globals.get("io")) |io_val| {
            if (io_val == .table) {
                io_val.table.deinit();
                self.allocator.destroy(io_val.table);
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

    const ArithOp = enum { add, sub, mul, div, idiv, mod };
    const BitwiseOp = enum { band, bor, bxor };

    // Push a new call info onto the call stack
    pub fn pushCallInfo(self: *VM, func: *const Proto, base: u32, ret_base: u32, nresults: i16) !*CallInfo {
        if (self.callstack_size >= self.callstack.len) {
            return error.CallStackOverflow;
        }

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

    // compareOp removed - EQ/LT/LE no longer write booleans to registers

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

    pub fn execute(self: *VM, proto: *const Proto) !ReturnValue {
        // Set up initial call frame
        self.base_ci = CallInfo{
            .func = proto,
            .pc = proto.code.ptr,
            .base = 0,
            .ret_base = 0, // Main function doesn't have a caller
            .savedpc = null,
            .nresults = -1, // multiple results expected
            .previous = null,
        };
        self.ci = &self.base_ci;
        self.base = 0;
        self.top = proto.maxstacksize;

        while (true) {
            var ci = self.ci.?;

            // Check PC is within bounds before instruction fetch
            const pc_offset = @intFromPtr(ci.pc) - @intFromPtr(ci.func.code.ptr);
            const pc_index = pc_offset / @sizeOf(Instruction);
            if (pc_index >= ci.func.code.len) {
                return error.PcOutOfRange;
            }

            const inst = ci.pc[0];
            ci.pc += 1;

            const op = inst.getOpCode();
            const a = inst.getA();

            switch (op) {
                .MOVE => {
                    const b = inst.getB();
                    self.stack[self.base + a] = self.stack[self.base + b];
                },
                .LOADK => {
                    const bx = inst.getBx();
                    self.stack[self.base + a] = ci.func.k[bx];
                },
                .LOADBOOL => {
                    const b = inst.getB();
                    const c = inst.getC();
                    self.stack[self.base + a] = .{ .boolean = (b != 0) };
                    if (c != 0) {
                        ci.pc += 1; // skip next instruction
                    }
                },
                .LOADNIL => {
                    const b = inst.getB();
                    var i: u8 = 0;
                    while (i <= b) : (i += 1) {
                        self.stack[self.base + a + i] = .nil;
                    }
                },
                .ADDI => {
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
                    const b = inst.getB();
                    const sc = inst.getC();
                    const vb = &self.stack[self.base + b];

                    // Convert value to integer
                    const value = if (vb.isInteger())
                        vb.integer
                    else if (vb.toNumber()) |n| blk: {
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
                    const b = inst.getB();
                    const sc = inst.getC();
                    const vb = &self.stack[self.base + b];

                    // Convert value to integer
                    const value = if (vb.isInteger())
                        vb.integer
                    else if (vb.toNumber()) |n| blk: {
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
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &proto.k[c];

                    const nb = vb.toNumber() orelse return error.ArithmeticError;
                    const nc = vc.toNumber() orelse return error.ArithmeticError;
                    if (nc == 0) return error.ArithmeticError;
                    self.stack[self.base + a] = .{ .number = luaMod(nb, nc) };
                },
                .BANDK => {
                    // Bitwise AND with constant
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
                    const b = inst.getB();
                    const vb = &self.stack[self.base + b];
                    self.stack[self.base + a] = .{ .boolean = !vb.toBoolean() };
                },
                .BNOT => {
                    // Bitwise NOT (~)
                    // Lua 5.3+ requires integer operand
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
                .EQ => {
                    const b = inst.getB();
                    const c = inst.getC();
                    const negate = inst.getA(); // A is negate flag (0: normal, 1: negated)
                    const is_true = eqOp(self.stack[self.base + b], self.stack[self.base + c]);
                    // if (is_true != (negate != 0)) then skip next instruction
                    if ((is_true and negate == 0) or (!is_true and negate != 0)) {
                        ci.pc += 1;
                    }
                },
                .LT => {
                    const b = inst.getB();
                    const c = inst.getC();
                    const negate = inst.getA();
                    const is_true = ltOp(self.stack[self.base + b], self.stack[self.base + c]) catch |err| switch (err) {
                        error.OrderComparisonError => return error.ArithmeticError,
                        else => return err,
                    };
                    if ((is_true and negate == 0) or (!is_true and negate != 0)) {
                        ci.pc += 1;
                    }
                },
                .LE => {
                    const b = inst.getB();
                    const c = inst.getC();
                    const negate = inst.getA();
                    const is_true = leOp(self.stack[self.base + b], self.stack[self.base + c]) catch |err| switch (err) {
                        error.OrderComparisonError => return error.ArithmeticError,
                        else => return err,
                    };
                    if ((is_true and negate == 0) or (!is_true and negate != 0)) {
                        ci.pc += 1;
                    }
                },
                .JMP => {
                    const sj = inst.getsJ();
                    // PC is already pointing to next instruction after this JMP
                    // sJ is relative to the instruction AFTER the JMP
                    if (sj >= 0) {
                        ci.pc += @as(usize, @intCast(sj));
                    } else {
                        ci.pc -= @as(usize, @intCast(-sj));
                    }

                    // Validate PC after jump
                    const new_pc_offset = @intFromPtr(ci.pc) - @intFromPtr(ci.func.code.ptr);
                    const new_pc_index = new_pc_offset / @sizeOf(Instruction);
                    if (new_pc_index >= ci.func.code.len) {
                        return error.PcOutOfRange;
                    }
                },
                .TEST => {
                    const k = inst.getk();
                    const va = &self.stack[self.base + a];
                    // if not (truth(va) == k) then skip
                    if (va.toBoolean() != k) {
                        ci.pc += 1;
                    }
                },
                .TESTSET => {
                    const b = inst.getB();
                    const k = inst.getk();
                    const vb = &self.stack[self.base + b];
                    if (vb.toBoolean() == k) {
                        // True: copy value and continue execution (no skip)
                        self.stack[self.base + a] = vb.*;
                    } else {
                        // False: skip next instruction
                        ci.pc += 1;
                    }
                },
                .FORPREP => {
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

                    if (sbx >= 0) ci.pc += @as(usize, @intCast(sbx)) else ci.pc -= @as(usize, @intCast(-sbx));
                },
                .FORLOOP => {
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
                                _ = try self.pushCallInfo(func_proto, self.base + a, self.base + a, @intCast(nresults));
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
                .GETTABUP => {
                    // GETTABUP A B C: R[A] := UpValue[B][K[C]]
                    // For globals: R[A] := _ENV[K[C]]
                    const b = inst.getB();
                    const c = inst.getC();
                    _ = b; // Assume B=0 for _ENV (global environment)

                    const key_val = ci.func.k[c];
                    if (key_val.isString()) {
                        const key = key_val.string;
                        const value = self.globals.get(key) orelse .nil;
                        self.stack[self.base + a] = value;
                    } else {
                        return error.InvalidTableKey;
                    }
                },
                .GETUPVAL => {
                    // Legacy opcode - might need proper implementation later
                    // For now, set to nil
                    const b = inst.getB();
                    _ = b; // Suppress unused warning
                    self.stack[self.base + a] = .nil;
                },
                .GETTABLE => {
                    // GETTABLE A B C: R[A] := R[B][R[C]]
                    const b = inst.getB();
                    const c = inst.getC();
                    const table_val = self.stack[self.base + b];
                    const key_val = self.stack[self.base + c];

                    if (table_val.isTable() and key_val.isString()) {
                        const table = table_val.table;
                        const key = key_val.string;
                        const value = table.get(key) orelse .nil;
                        self.stack[self.base + a] = value;
                    } else {
                        return error.InvalidTableOperation;
                    }
                },
                .NEWTABLE => {
                    // Basic table creation (not fully implemented)
                    // For now, just set to nil
                    self.stack[self.base + a] = .nil;
                },
                else => return error.UnknownOpcode,
            }
        }
    }
};
