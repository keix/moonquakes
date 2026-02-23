const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const ReturnValue = @import("../vm/execution.zig").ReturnValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const OpCode = opcodes.OpCode;

const test_utils = @import("test_utils.zig");

fn expectSingleResult(result: ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

test "FORPREP minimal test" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 5 }, // init
        .{ .integer = 1 }, // step
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5 (init)
        Instruction.initABx(.LOADK, 2, 1), // R2 = 1 (step)
        Instruction.initAsBx(.FORPREP, 0, 0), // FORPREP A=0, sBx=0 (jump to next = RETURN)
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0 (should be 5-1=4)
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 3);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try expectSingleResult(result, TValue{ .number = 4.0 }); // init - step = 5 - 1 = 4
}

test "for loop: simple integer loop 1 to 3" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 1 }, // init (R0)
        .{ .integer = 3 }, // limit (R1)
        .{ .integer = 1 }, // step  (R2)
        .{ .integer = 0 }, // accumulator (R4)
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3
        Instruction.initABx(.LOADK, 2, 2), // R2 = 1
        Instruction.initABx(.LOADK, 4, 3), // R4 = 0
        // ---- FOR structure ----
        // index 4: FORPREP jumps directly to index 6 (FORLOOP)
        Instruction.initAsBx(.FORPREP, 0, 1), // (PC += 1 -> FORLOOP)
        // index 5: loop body
        Instruction.initABC(.ADD, 4, 4, 3), // R4 += R3 (control variable)
        // index 6:
        Instruction.initAsBx(.FORLOOP, 0, -2), // if continue: jump back to index 5
        // index 7:
        Instruction.initABC(.RETURN, 4, 2, 0), // return R4
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 5);

    // Added: Comprehensive state tracking
    var trace = test_utils.ExecutionTrace.captureInitial(ctx.vm, 5);

    const result = try Mnemonics.execute(ctx.vm, proto);

    trace.updateFinal(ctx.vm, 5);

    // Existing verification
    try expectSingleResult(result, TValue{ .integer = 6 }); // 1+2+3 = 6

    // Added: Verify loop variables and control flow
    // R0 (index) should be 3 after loop (last value before exit)
    try trace.expectRegisterChanged(0, TValue{ .integer = 3 });
    try trace.expectRegisterChanged(1, TValue{ .integer = 3 }); // limit unchanged
    try trace.expectRegisterChanged(2, TValue{ .integer = 1 }); // step unchanged
    try trace.expectRegisterChanged(3, TValue{ .integer = 3 }); // control variable (last value)
    try trace.expectRegisterChanged(4, TValue{ .integer = 6 }); // accumulator
}

// Added: Critical edge case tests for potential bugs

test "for loop: negative step (countdown)" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 5 }, // init (R0)
        .{ .integer = 1 }, // limit (R1)
        .{ .integer = -1 }, // step (R2) - negative!
        .{ .integer = 0 }, // accumulator (R4)
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5
        Instruction.initABx(.LOADK, 1, 1), // R1 = 1
        Instruction.initABx(.LOADK, 2, 2), // R2 = -1
        Instruction.initABx(.LOADK, 4, 3), // R4 = 0
        Instruction.initAsBx(.FORPREP, 0, 1),
        Instruction.initABC(.ADD, 4, 4, 3), // R4 += R3
        Instruction.initAsBx(.FORLOOP, 0, -2),
        Instruction.initABC(.RETURN, 4, 2, 0),
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 5);
    var trace = test_utils.ExecutionTrace.captureInitial(ctx.vm, 5);
    const result = try Mnemonics.execute(ctx.vm, proto);
    trace.updateFinal(ctx.vm, 5);

    // Should execute: 5, 4, 3, 2, 1 = 15
    try expectSingleResult(result, TValue{ .integer = 15 });

    // Verify final loop state
    try trace.expectRegisterChanged(0, TValue{ .integer = 1 }); // last valid index
    try trace.expectRegisterChanged(4, TValue{ .integer = 15 }); // sum
}

test "for loop: zero iterations (start > limit with positive step)" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 5 }, // init (R0) - starts above limit!
        .{ .integer = 3 }, // limit (R1)
        .{ .integer = 1 }, // step (R2) - positive
        .{ .integer = 99 }, // accumulator (R4) - should remain unchanged
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3
        Instruction.initABx(.LOADK, 2, 2), // R2 = 1
        Instruction.initABx(.LOADK, 4, 3), // R4 = 99
        Instruction.initAsBx(.FORPREP, 0, 1),
        Instruction.initABC(.ADD, 4, 4, 3), // R4 += R3 (should never execute)
        Instruction.initAsBx(.FORLOOP, 0, -2),
        Instruction.initABC(.RETURN, 4, 2, 0),
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 5);

    // Set up R3 to verify it never gets set
    ctx.vm.stack[3] = .nil;

    var trace = test_utils.ExecutionTrace.captureInitial(ctx.vm, 5);
    const result = try Mnemonics.execute(ctx.vm, proto);
    trace.updateFinal(ctx.vm, 5);

    // Should not execute any iterations
    try expectSingleResult(result, TValue{ .integer = 99 }); // unchanged

    // R3 should remain nil (control variable never set)
    try trace.expectRegisterUnchanged(3);
    try test_utils.expectRegister(ctx.vm, 3, .nil);

    // R4 should remain 99 (accumulator unchanged)
    try trace.expectRegisterChanged(4, TValue{ .integer = 99 });
}

test "for loop: float loop variables with integer path detection" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .number = 1.0 }, // init (R0) - float that could be integer
        .{ .number = 3.0 }, // limit (R1) - float that could be integer
        .{ .number = 1.0 }, // step (R2) - float that could be integer
        .{ .integer = 0 }, // accumulator (R4)
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1.0
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3.0
        Instruction.initABx(.LOADK, 2, 2), // R2 = 1.0
        Instruction.initABx(.LOADK, 4, 3), // R4 = 0
        Instruction.initAsBx(.FORPREP, 0, 1),
        Instruction.initABC(.ADD, 4, 4, 3), // R4 += R3
        Instruction.initAsBx(.FORLOOP, 0, -2),
        Instruction.initABC(.RETURN, 0, 5, 0), // return all registers
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 5);
    const loop_trace = test_utils.ForLoopTrace.capture(ctx.vm, 0);
    _ = loop_trace; // Will use after execution

    var trace = test_utils.ExecutionTrace.captureInitial(ctx.vm, 5);
    const result = try Mnemonics.execute(ctx.vm, proto);
    trace.updateFinal(ctx.vm, 5);

    // Check if VM optimized to integer path or stayed float
    const final_loop = test_utils.ForLoopTrace.capture(ctx.vm, 0);

    // These values might be converted to integers or stay as floats
    // This test exposes whether the VM does this optimization
    try testing.expect(result == .multiple);
    try testing.expectEqual(@as(usize, 4), result.multiple.len);

    // Print actual types for debugging
    if (result.multiple[0] == .integer) {
        try final_loop.expectIntegerPath();
    } else {
        try final_loop.expectFloatPath();
    }
}

test "for loop: step of zero should error" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 1 }, // init
        .{ .integer = 3 }, // limit
        .{ .integer = 0 }, // step - ZERO!
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0),
        Instruction.initABx(.LOADK, 1, 1),
        Instruction.initABx(.LOADK, 2, 2),
        Instruction.initAsBx(.FORPREP, 0, 1),
        Instruction.initABC(.LOADNIL, 3, 0, 0), // body (should not execute)
        Instruction.initAsBx(.FORLOOP, 0, -2),
        Instruction.initABC(.RETURN, 0, 1, 0),
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 4);
    const result = Mnemonics.execute(ctx.vm, proto);

    // Step of zero should cause an error
    // FIXED: VM now checks for zero step in FORPREP
    try testing.expectError(error.InvalidForLoopStep, result);
}

test "for loop: overflow behavior" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const max = std.math.maxInt(i64);
    const constants = [_]TValue{
        .{ .integer = max - 2 }, // init
        .{ .integer = max }, // limit
        .{ .integer = 1 }, // step
        .{ .integer = 0 }, // accumulator
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = max-2
        Instruction.initABx(.LOADK, 1, 1), // R1 = max
        Instruction.initABx(.LOADK, 2, 2), // R2 = 1
        Instruction.initABx(.LOADK, 4, 3), // R4 = 0
        Instruction.initAsBx(.FORPREP, 0, 1),
        Instruction.initABC(.ADDI, 4, 4, 1), // R4 += 1 (count iterations)
        Instruction.initAsBx(.FORLOOP, 0, -2),
        Instruction.initABC(.RETURN, 4, 2, 0),
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 5);
    const result = try Mnemonics.execute(ctx.vm, proto);

    // Should execute 3 times: max-2, max-1, max
    try expectSingleResult(result, TValue{ .integer = 3 });
}

test "for loop: side effects on unused registers" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 1 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initABx(.LOADK, 1, 1), // R1 = 2
        Instruction.initABx(.LOADK, 2, 2), // R2 = 1
        // Set up registers beyond loop to check for corruption
        Instruction.initABC(.LOADNIL, 5, 5, 0), // R5..R10 = nil
        Instruction.initAsBx(.FORPREP, 0, 1),
        Instruction.initABC(.LOADNIL, 4, 0, 0), // R4 = nil (dummy body)
        Instruction.initAsBx(.FORLOOP, 0, -2),
        Instruction.initABC(.RETURN, 0, 11, 0), // return R0..R10
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 11);

    // Initialize extra registers with specific values
    ctx.vm.stack[5] = TValue{ .integer = 555 };
    ctx.vm.stack[6] = TValue{ .boolean = true };
    ctx.vm.stack[7] = TValue{ .number = 3.14 };
    ctx.vm.stack[8] = .nil;
    ctx.vm.stack[9] = TValue{ .integer = 999 };
    ctx.vm.stack[10] = TValue{ .boolean = false };

    var trace = test_utils.ExecutionTrace.captureInitial(ctx.vm, 11);
    const result = try Mnemonics.execute(ctx.vm, proto);
    trace.updateFinal(ctx.vm, 11);

    // Use result to avoid unused warning
    try testing.expect(result == .multiple);
    try testing.expectEqual(@as(usize, 10), result.multiple.len);

    // Verify loop registers changed
    try trace.expectRegisterChanged(0, TValue{ .integer = 2 }); // final index
    try trace.expectRegisterChanged(1, TValue{ .integer = 2 }); // limit
    try trace.expectRegisterChanged(2, TValue{ .integer = 1 }); // step
    try trace.expectRegisterChanged(3, TValue{ .integer = 2 }); // control var
    try trace.expectRegisterChanged(4, .nil); // body executed

    // Verify R5-R10 are corrupted by LOADNIL instruction, not by loop
    try trace.expectRegisterChanged(5, .nil);
    try trace.expectRegisterChanged(6, .nil);
    try trace.expectRegisterChanged(7, .nil);
    try trace.expectRegisterChanged(8, .nil);
    try trace.expectRegisterChanged(9, .nil);
    try trace.expectRegisterChanged(10, .nil);
}
