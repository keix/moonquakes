const std = @import("std");
const testing = std.testing;

const TValue = @import("../core/value.zig").TValue;
const Proto = @import("../vm/func.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

const utils = @import("test_utils.zig");

test "MOVE with stack verification" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 42
        Instruction.initABC(.MOVE, 1, 0, 0), // R1 = R0
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const constants = [_]TValue{
        .{ .integer = 42 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();

    // Capture initial state
    const trace = utils.ExecutionTrace.captureInitial(&vm, 2);

    // Execute
    const result = try vm.execute(&proto);

    // Update final state
    var final_trace = trace;
    final_trace.updateFinal(&vm, 2);

    // Verify result
    try utils.ReturnTest.expectSingle(result, TValue{ .integer = 42 });

    // Verify registers
    try final_trace.expectRegisterChanged(0, TValue{ .integer = 42 });
    try final_trace.expectRegisterChanged(1, TValue{ .integer = 42 });

    // Verify stack boundaries
    try utils.expectVMState(&vm, 0, 2);
}

test "LOADK with comprehensive state tracking" {
    const constants = [_]TValue{
        .{ .integer = 100 },
        .{ .number = 3.14 },
        .{ .boolean = true },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 100
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3.14
        Instruction.initABx(.LOADK, 2, 2), // R2 = true
        Instruction.initABC(.RETURN, 0, 4, 0), // return R0, R1, R2
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();

    // Verify initial state - all registers should be nil
    try utils.expectNilRange(&vm, 0, 3);

    var inst_test = utils.InstructionTest.init(&vm, &proto, 3);
    _ = try inst_test.expectSuccess(3);

    // Verify final state
    try utils.expectRegisters(&vm, 0, &[_]TValue{
        .{ .integer = 100 },
        .{ .number = 3.14 },
        .{ .boolean = true },
    });

    // Verify VM state didn't change unexpectedly
    try utils.expectVMState(&vm, 0, 3);
}

test "ADD instruction with side effect verification" {
    const initial_regs = [_]TValue{
        .nil, // R0
        .{ .integer = 5 }, // R1
        .{ .integer = 7 }, // R2
        .{ .integer = 99 }, // R3 - should not change
    };

    const expected_regs = [_]TValue{
        .{ .integer = 12 }, // R0 = R1 + R2
        .{ .integer = 5 }, // R1 unchanged
        .{ .integer = 7 }, // R2 unchanged
        .{ .integer = 99 }, // R3 unchanged
    };

    try utils.testSingleInstruction(Instruction.initABC(.ADD, 0, 1, 2), &[_]TValue{}, // no constants needed
        &initial_regs, &expected_regs, 0, // expected base
        4 // expected top
    );
}

test "Arithmetic operation helper usage" {
    var vm = VM.init();

    // Test integer addition
    try utils.testArithmeticOp(&vm, Instruction.initABC(.ADD, 2, 0, 1), TValue{ .integer = 10 }, TValue{ .integer = 20 }, TValue{ .integer = 30 }, &[_]TValue{});

    // Reset VM
    vm = VM.init();

    // Test float multiplication
    try utils.testArithmeticOp(&vm, Instruction.initABC(.MUL, 2, 0, 1), TValue{ .number = 2.5 }, TValue{ .number = 4.0 }, TValue{ .number = 10.0 }, &[_]TValue{});
}

test "EQ comparison with skip verification" {
    var vm = VM.init();

    // Test equal values with A=0 (skip if equal)
    try utils.ComparisonTest.expectSkip(&vm, Instruction.initABC(.EQ, 0, 0, 1), // if (R0 == R1) == (A==0) then skip
        TValue{ .integer = 42 }, TValue{ .integer = 42 }, &[_]TValue{});

    // Reset VM
    vm = VM.init();

    // Test unequal values with A=0 (don't skip if unequal)
    try utils.ComparisonTest.expectNoSkip(&vm, Instruction.initABC(.EQ, 0, 0, 1), // if (R0 == R1) == (A==0) then skip
        TValue{ .integer = 42 }, TValue{ .integer = 43 }, &[_]TValue{});

    // Reset VM
    vm = VM.init();

    // Test equal values with A=1 (don't skip if equal, because A=1 negates)
    try utils.ComparisonTest.expectNoSkip(&vm, Instruction.initABC(.EQ, 1, 0, 1), // if (R0 == R1) == (A==0) then skip
        TValue{ .integer = 42 }, TValue{ .integer = 42 }, &[_]TValue{});
}

test "FORPREP/FORLOOP with state tracking" {
    const code = [_]Instruction{
        // Initialize loop variables
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1 (init)
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3 (limit)
        Instruction.initABx(.LOADK, 2, 2), // R2 = 1 (step)

        // For loop
        Instruction.initAsBx(.FORPREP, 0, 1), // prepare loop, jump to FORLOOP
        Instruction.initABC(.LOADNIL, 4, 0, 0), // loop body (just a placeholder)
        Instruction.initAsBx(.FORLOOP, 0, -2), // loop back
        Instruction.initABC(.RETURN, 0, 5, 0), // return R0..R3
    };

    const constants = [_]TValue{
        .{ .integer = 1 }, // init
        .{ .integer = 3 }, // limit
        .{ .integer = 1 }, // step
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 5,
    };

    var vm = VM.init();

    // Capture loop state before execution
    const initial_loop = utils.ForLoopTrace.capture(&vm, 0);
    _ = initial_loop;

    const result = try vm.execute(&proto);

    // Capture final loop state
    const final_loop = utils.ForLoopTrace.capture(&vm, 0);

    // Verify integer path was used
    try final_loop.expectIntegerPath();

    // Verify final loop state
    try testing.expect(result == .multiple);
    try testing.expectEqual(@as(usize, 4), result.multiple.len);
    try testing.expect(result.multiple[0].eql(TValue{ .integer = 3 })); // init after loop (last valid value)
    try testing.expect(result.multiple[1].eql(TValue{ .integer = 3 })); // limit
    try testing.expect(result.multiple[2].eql(TValue{ .integer = 1 })); // step
    try testing.expect(result.multiple[3].eql(TValue{ .integer = 3 })); // control (last value)
}
