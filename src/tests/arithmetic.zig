const std = @import("std");
const testing = std.testing;

const TValue = @import("../core/value.zig").TValue;
const Proto = @import("../vm/func.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

const utils = @import("test_utils.zig");

fn expectSingleResult(result: VM.ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

fn expectApproxResult(result: VM.ReturnValue, expected_value: f64, tolerance: f64) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.isNumber());
    try testing.expectApproxEqAbs(result.single.number, expected_value, tolerance);
}

test "arithmetic: 10 - 3 * 2 = 4" {
    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 3 },
        .{ .integer = 2 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3
        Instruction.initABx(.LOADK, 2, 2), // R2 = 2
        Instruction.initABC(.MUL, 3, 1, 2), // R3 = R1 * R2 = 6
        Instruction.initABC(.SUB, 4, 0, 3), // R4 = R0 - R3 = 4
        Instruction.initABC(.RETURN, 4, 2, 0), // return R4
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 5,
    };

    var vm = VM.init();

    // Capture initial state
    var trace = utils.ExecutionTrace.captureInitial(&vm, 5);

    const result = try vm.execute(&proto);

    // Update final state
    trace.updateFinal(&vm, 5);

    // Verify result
    try utils.expectResultAndState(result, TValue{ .integer = 4 }, &vm, 0, 5);

    // Verify register states
    try trace.expectRegisterChanged(0, TValue{ .integer = 10 }); // R0 loaded 10
    try trace.expectRegisterChanged(1, TValue{ .integer = 3 }); // R1 loaded 3
    try trace.expectRegisterChanged(2, TValue{ .integer = 2 }); // R2 loaded 2
    try trace.expectRegisterChanged(3, TValue{ .integer = 6 }); // R3 = 3 * 2 = 6
    try trace.expectRegisterChanged(4, TValue{ .integer = 4 }); // R4 = 10 - 6 = 4

    // Verify no other registers were affected
    try utils.expectRegistersUnchanged(&trace, 5, &[_]u8{ 0, 1, 2, 3, 4 });
}

test "arithmetic: 10 / 3 with side effect verification" {
    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3
        Instruction.initABC(.DIV, 2, 0, 1), // R2 = R0 / R1
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 6, // Extra space to test side effects
    };

    var vm = VM.init();

    // Set up registers beyond what we need to verify no side effects
    vm.stack[3] = TValue{ .integer = 999 };
    vm.stack[4] = TValue{ .boolean = true };
    vm.stack[5] = TValue{ .number = 3.14 };

    var trace = utils.ExecutionTrace.captureInitial(&vm, 6);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 6);

    // Verify result
    try testing.expect(result == .single);
    try testing.expect(result.single.isNumber());
    try testing.expectApproxEqAbs(result.single.number, 3.333333, 0.00001);

    // Verify only expected registers changed
    try trace.expectRegisterChanged(0, TValue{ .integer = 10 });
    try trace.expectRegisterChanged(1, TValue{ .integer = 3 });
    try testing.expect(vm.stack[vm.base + 2].isNumber());
    try testing.expectApproxEqAbs(vm.stack[vm.base + 2].number, 3.333333, 0.00001);

    // Verify registers 3-5 are unchanged (side effect check)
    try trace.expectRegisterUnchanged(3);
    try trace.expectRegisterUnchanged(4);
    try trace.expectRegisterUnchanged(5);

    // Alternative: verify all except 0,1,2
    try utils.expectRegistersUnchanged(&trace, 6, &[_]u8{ 0, 1, 2 });
}

test "arithmetic: 10 // 3 = 3" {
    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3
        Instruction.initABC(.IDIV, 2, 0, 1), // R2 = R0 // R1 = 3
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();

    // Added: Stack and register verification
    var trace = utils.ExecutionTrace.captureInitial(&vm, 3);

    const result = try vm.execute(&proto);

    trace.updateFinal(&vm, 3);

    // Existing verification
    try expectSingleResult(result, TValue{ .number = 3 });

    // Added: Register state verification
    try trace.expectRegisterChanged(0, TValue{ .integer = 10 });
    try trace.expectRegisterChanged(1, TValue{ .integer = 3 });
    try trace.expectRegisterChanged(2, TValue{ .number = 3 }); // IDIV always returns float

    // VM state verification
    try utils.expectVMState(&vm, 0, 3);
}

test "arithmetic: 10 % 3 = 1" {
    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3
        Instruction.initABC(.MOD, 2, 0, 1), // R2 = R0 % R1 = 1
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();

    // Added: ExecutionTrace for state tracking
    var trace = utils.ExecutionTrace.captureInitial(&vm, 3);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 3);

    // Existing verification
    try expectSingleResult(result, TValue{ .number = 1 });

    // Added: Detailed state verification
    try utils.expectRegisters(&vm, 0, &[_]TValue{
        .{ .integer = 10 }, // R0
        .{ .integer = 3 }, // R1
        .{ .number = 1 }, // R2 (MOD always returns float)
    });

    // Verify all registers changed as expected
    try utils.expectRegistersUnchanged(&trace, 3, &[_]u8{ 0, 1, 2 });
}
