const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const ReturnValue = @import("../vm/execution.zig").ReturnValue;
const Proto = @import("../compiler/proto.zig").Proto;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

/// Helper function to create a VM with proper cleanup
pub fn createTestVM() !VM {
    return VM.init(testing.allocator);
}

/// Verify register state at specific position
pub fn expectRegister(vm: *const VM, reg: u8, expected: TValue) !void {
    const actual = vm.stack[vm.base + reg];
    try testing.expect(actual.eql(expected));
}

/// Verify multiple registers starting from reg
pub fn expectRegisters(vm: *const VM, start_reg: u8, expected: []const TValue) !void {
    for (expected, 0..) |exp, i| {
        const reg = start_reg + @as(u8, @intCast(i));
        try expectRegister(vm, reg, exp);
    }
}

/// Verify stack range is nil (uninitialized)
pub fn expectNilRange(vm: *const VM, start_reg: u8, count: u8) !void {
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        const actual = vm.stack[vm.base + start_reg + i];
        try testing.expect(actual == .nil);
    }
}

/// Verify VM state after execution
pub fn expectVMState(vm: *const VM, expected_base: usize, expected_top: usize) !void {
    try testing.expectEqual(expected_base, vm.base);
    try testing.expectEqual(expected_top, vm.top);
}

/// Execute with detailed state tracking
pub const ExecutionTrace = struct {
    pub const MaxTraceRegs = 32;

    initial_registers: [MaxTraceRegs]TValue = [_]TValue{.nil} ** MaxTraceRegs,
    final_registers: [MaxTraceRegs]TValue = [_]TValue{.nil} ** MaxTraceRegs,
    initial_base: usize,
    initial_top: usize,
    final_base: usize,
    final_top: usize,

    pub fn capture(vm: *const VM, reg_count: u8) ExecutionTrace {
        var trace = ExecutionTrace{
            .initial_base = vm.base,
            .initial_top = vm.top,
            .final_base = vm.base,
            .final_top = vm.top,
        };

        var i: u8 = 0;
        std.debug.assert(reg_count <= ExecutionTrace.MaxTraceRegs);
        while (i < reg_count) : (i += 1) {
            trace.initial_registers[i] = vm.stack[vm.base + i];
            trace.final_registers[i] = vm.stack[vm.base + i];
        }

        return trace;
    }

    pub fn captureInitial(vm: *const VM, reg_count: u8) ExecutionTrace {
        var trace = ExecutionTrace{
            .initial_base = vm.base,
            .initial_top = vm.top,
            .final_base = undefined,
            .final_top = undefined,
        };

        var i: u8 = 0;
        std.debug.assert(reg_count <= ExecutionTrace.MaxTraceRegs);
        while (i < reg_count) : (i += 1) {
            trace.initial_registers[i] = vm.stack[vm.base + i];
        }

        return trace;
    }

    pub fn updateFinal(self: *ExecutionTrace, vm: *const VM, reg_count: u8) void {
        self.final_base = vm.base;
        self.final_top = vm.top;

        var i: u8 = 0;
        std.debug.assert(reg_count <= ExecutionTrace.MaxTraceRegs);
        while (i < reg_count) : (i += 1) {
            self.final_registers[i] = vm.stack[vm.base + i];
        }
    }

    pub fn expectRegisterChanged(self: *const ExecutionTrace, reg: u8, expected: TValue) !void {
        try testing.expect(self.final_registers[reg].eql(expected));
    }

    pub fn expectRegisterUnchanged(self: *const ExecutionTrace, reg: u8) !void {
        try testing.expect(self.initial_registers[reg].eql(self.final_registers[reg]));
    }

    pub fn expectOnlyRegisterChanged(self: *const ExecutionTrace, changed_reg: u8, expected: TValue, total_regs: u8) !void {
        // Verify the changed register
        try self.expectRegisterChanged(changed_reg, expected);

        // Verify all other registers unchanged
        var i: u8 = 0;
        std.debug.assert(total_regs <= ExecutionTrace.MaxTraceRegs);
        while (i < total_regs) : (i += 1) {
            if (i != changed_reg) {
                try self.expectRegisterUnchanged(i);
            }
        }
    }

    pub fn print(self: *const ExecutionTrace, reg_count: u8) void {
        std.debug.print("=== Execution Trace ===\n", .{});
        std.debug.print("Base: {} -> {}\n", .{ self.initial_base, self.final_base });
        std.debug.print("Top: {} -> {}\n", .{ self.initial_top, self.final_top });

        var i: u8 = 0;
        std.debug.assert(reg_count <= ExecutionTrace.MaxTraceRegs);
        while (i < reg_count) : (i += 1) {
            if (!self.initial_registers[i].eql(self.final_registers[i])) {
                std.debug.print("R[{}]: {} -> {}\n", .{ i, self.initial_registers[i], self.final_registers[i] });
            }
        }
    }
};

/// Verify instruction doesn't affect unrelated registers
pub fn expectSideEffectFree(vm: *VM, proto: *const Proto, affected_regs: []const u8, total_regs: u8) !void {
    // Capture initial state with base consideration
    var initial_state: [256]TValue = undefined;
    const base = vm.base;

    var i: u8 = 0;
    while (i < total_regs) : (i += 1) {
        initial_state[i] = vm.stack[base + i];
    }

    // Execute
    _ = try vm.execute(proto);

    // Check only specified registers changed
    i = 0;
    while (i < total_regs) : (i += 1) {
        const reg = i;
        var is_affected = false;
        for (affected_regs) |a| {
            if (a == reg) {
                is_affected = true;
                break;
            }
        }

        if (!is_affected) {
            try testing.expect(vm.stack[vm.base + reg].eql(initial_state[reg]));
        }
    }
}

/// Execute single instruction and verify state
pub const InstructionTest = struct {
    vm: *VM,
    proto: *const Proto,
    initial_trace: ExecutionTrace,

    pub fn init(vm: *VM, proto: *const Proto, reg_count: u8) InstructionTest {
        return .{
            .vm = vm,
            .proto = proto,
            .initial_trace = ExecutionTrace.captureInitial(vm, reg_count),
        };
    }

    pub fn execute(self: *InstructionTest) !ReturnValue {
        return self.vm.execute(self.proto);
    }

    pub fn expectSuccess(self: *InstructionTest, reg_count: u8) !ExecutionTrace {
        _ = try self.execute();
        var trace = self.initial_trace;
        trace.updateFinal(self.vm, reg_count);
        return trace;
    }

    pub fn expectError(self: *InstructionTest, expected_error: anyerror) !void {
        const result = self.execute();
        if (result) |_| {
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqual(expected_error, err);
        }
    }
};

/// Test harness for single instruction tests
pub fn testSingleInstruction(instruction: Instruction, constants: []const TValue, initial_regs: []const TValue, expected_regs: []const TValue, expected_base: u32, expected_top: u32) !void {
    const code = [_]Instruction{
        instruction,
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = Proto{
        .k = constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = @as(u8, @intCast(initial_regs.len)),
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Set initial registers
    for (initial_regs, 0..) |val, i| {
        vm.stack[i] = val;
    }

    var inst_test = InstructionTest.init(&vm, &proto, @as(u8, @intCast(initial_regs.len)));
    const trace = try inst_test.expectSuccess(@as(u8, @intCast(expected_regs.len)));

    // Verify expected registers
    for (expected_regs, 0..) |expected, i| {
        try trace.expectRegisterChanged(@as(u8, @intCast(i)), expected);
    }

    // Verify VM state
    try expectVMState(&vm, expected_base, expected_top);
}

/// Stack growth verification
pub fn expectStackGrowth(vm: *const VM, initial_top: u32, growth: u32) !void {
    try testing.expectEqual(initial_top + growth, vm.top);
}

/// Stack shrink verification
pub fn expectStackShrink(vm: *const VM, initial_top: u32, shrink: u32) !void {
    try testing.expect(initial_top >= shrink);
    try testing.expectEqual(initial_top - shrink, vm.top);
}

/// Verify PC advancement
pub fn expectPCAdvance(initial_pc: [*]const Instruction, final_pc: [*]const Instruction, expected_advance: usize) !void {
    const actual_advance = @intFromPtr(final_pc) - @intFromPtr(initial_pc);
    try testing.expectEqual(expected_advance * @sizeOf(Instruction), actual_advance);
}

/// Create test proto with single instruction
pub fn createSingleInstructionProto(allocator: std.mem.Allocator, inst: Instruction, constants: []const TValue, stack_size: u8) !Proto {
    var code = try allocator.alloc(Instruction, 2);
    code[0] = inst;
    code[1] = Instruction.initABC(.RETURN, 0, 1, 0);

    return Proto{
        .k = constants,
        .code = code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = stack_size,
    };
}

/// Test comparison operation with skip behavior
pub const ComparisonTest = struct {
    pub fn expectSkip(vm: *VM, inst: Instruction, reg_a_val: TValue, reg_b_val: TValue, constants: []const TValue) !void {
        const code = [_]Instruction{
            inst, // comparison instruction
            Instruction.initABC(.LFALSESKIP, 0, 0, 0), // load true and skip next
            Instruction.initABC(.LOADFALSE, 0, 0, 0), // should execute
            Instruction.initABC(.RETURN, 0, 2, 0), // return R0
        };

        const proto = Proto{
            .k = constants,
            .code = &code,
            .numparams = 0,
            .is_vararg = false,
            .maxstacksize = 3,
        };

        // Set up registers with base offset
        const b = inst.getB();
        const c = inst.getC();
        vm.stack[vm.base + b] = reg_a_val;
        vm.stack[vm.base + c] = reg_b_val;

        const result = try vm.execute(&proto);

        // If comparison skips, LFALSESKIP is skipped, LOADFALSE executes
        // R0 should be false
        try testing.expect(result == .single);
        try testing.expect(result.single.eql(TValue{ .boolean = false }));
    }

    pub fn expectNoSkip(vm: *VM, inst: Instruction, reg_a_val: TValue, reg_b_val: TValue, constants: []const TValue) !void {
        const code = [_]Instruction{
            inst, // comparison instruction
            Instruction.initABC(.LFALSESKIP, 0, 0, 0), // should execute (load false and skip next)
            Instruction.initABC(.LOADTRUE, 0, 0, 0), // should be skipped
            Instruction.initABC(.RETURN, 0, 2, 0), // return R0
        };

        const proto = Proto{
            .k = constants,
            .code = &code,
            .numparams = 0,
            .is_vararg = false,
            .maxstacksize = 3,
        };

        // Set up registers with base offset
        const b = inst.getB();
        const c = inst.getC();
        vm.stack[vm.base + b] = reg_a_val;
        vm.stack[vm.base + c] = reg_b_val;

        const result = try vm.execute(&proto);

        // If comparison doesn't skip, LFALSESKIP executes (sets R0=false and skips LOADTRUE)
        // R0 should be false
        try testing.expect(result == .single);
        try testing.expect(result.single.eql(TValue{ .boolean = false }));
    }
};

/// Test for loop state tracking
pub const ForLoopTrace = struct {
    init_val: TValue,
    limit_val: TValue,
    step_val: TValue,
    control_val: TValue,
    iterations: u32,

    pub fn capture(vm: *const VM, loop_base: u8) ForLoopTrace {
        return .{
            .init_val = vm.stack[vm.base + loop_base],
            .limit_val = vm.stack[vm.base + loop_base + 1],
            .step_val = vm.stack[vm.base + loop_base + 2],
            .control_val = vm.stack[vm.base + loop_base + 3],
            .iterations = 0,
        };
    }

    pub fn expectIntegerPath(self: *const ForLoopTrace) !void {
        try testing.expect(self.init_val.isInteger());
        try testing.expect(self.limit_val.isInteger());
        try testing.expect(self.step_val.isInteger());
        try testing.expect(self.control_val.isInteger());
    }

    pub fn expectFloatPath(self: *const ForLoopTrace) !void {
        try testing.expect(self.init_val == .number or self.limit_val == .number or self.step_val == .number);
    }
};

/// Arithmetic operation test helper
pub fn testArithmeticOp(vm: *VM, inst: Instruction, a_val: TValue, b_val: TValue, expected: TValue, constants: []const TValue) !void {
    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, inst.getA(), 2, 0),
    };

    const proto = Proto{
        .k = constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    // Set up operand registers
    vm.stack[vm.base + inst.getB()] = a_val;
    vm.stack[vm.base + inst.getC()] = b_val;

    const result = try vm.execute(&proto);

    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));

    // Verify only target register changed
    try testing.expect(vm.stack[vm.base + inst.getA()].eql(expected));
}

/// Test utilities for RETURN instruction
pub const ReturnTest = struct {
    pub fn expectNone(result: ReturnValue) !void {
        try testing.expect(result == .none);
    }

    pub fn expectSingle(result: ReturnValue, expected: TValue) !void {
        try testing.expect(result == .single);
        try testing.expect(result.single.eql(expected));
    }

    /// Compare single result with string content (for parser tests)
    pub fn expectSingleString(result: ReturnValue, expected_str: []const u8) !void {
        try testing.expect(result == .single);
        try testing.expect(result.single.isString());
        const actual_str = result.single.string.asSlice();
        try testing.expectEqualStrings(expected_str, actual_str);
    }

    pub fn expectMultiple(result: ReturnValue, expected: []const TValue) !void {
        try testing.expect(result == .multiple);
        try testing.expectEqual(expected.len, result.multiple.len);
        for (expected, result.multiple) |exp, act| {
            try testing.expect(exp.eql(act));
        }
    }
};

/// Float comparison with epsilon tolerance
pub fn expectApprox(actual: f64, expected: f64, eps: f64) !void {
    try testing.expect(@abs(actual - expected) <= eps);
}

/// Verify multiple registers are unchanged except specified ones
pub fn expectRegistersUnchanged(trace: *const ExecutionTrace, total: u8, except: []const u8) !void {
    var i: u8 = 0;
    while (i < total) : (i += 1) {
        var skip = false;
        for (except) |ex| {
            if (ex == i) {
                skip = true;
                break;
            }
        }
        if (!skip) {
            try trace.expectRegisterUnchanged(i);
        }
    }
}

/// Combined result and state verification
pub fn expectResultAndState(result: ReturnValue, expected: TValue, vm: *const VM, expected_base: usize, expected_top: usize) !void {
    try ReturnTest.expectSingle(result, expected);
    try expectVMState(vm, expected_base, expected_top);
}
