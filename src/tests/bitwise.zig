const std = @import("std");
const testing = std.testing;

const TValue = @import("../core/value.zig").TValue;
const Proto = @import("../core/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

const utils = @import("test_utils.zig");

// ===== BNOT (Bitwise NOT) Tests =====

test "BNOT: basic integer negation" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 0
        Instruction.initABC(.BNOT, 1, 0, 0), // R1 = ~R0
        Instruction.initABx(.LOADK, 2, 1), // R2 = 5
        Instruction.initABC(.BNOT, 3, 2, 0), // R3 = ~R2
        Instruction.initABC(.RETURN, 1, 4, 0), // return R1, R2, R3
    };

    const constants = [_]TValue{
        .{ .integer = 0 },
        .{ .integer = 5 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 4,
    };

    var vm = VM.init();

    // Capture initial state
    var trace = utils.ExecutionTrace.captureInitial(&vm, 4);

    const result = try vm.execute(&proto);

    // Update final state
    trace.updateFinal(&vm, 4);

    // Verify result
    try testing.expect(result == .multiple);
    try testing.expectEqual(@as(usize, 3), result.multiple.len);
    try testing.expect(result.multiple[0].eql(TValue{ .integer = ~@as(i64, 0) })); // ~0 = -1
    try testing.expect(result.multiple[1].eql(TValue{ .integer = 5 }));
    try testing.expect(result.multiple[2].eql(TValue{ .integer = ~@as(i64, 5) })); // ~5 = -6

    // Verify register states
    try utils.expectRegisters(&vm, 0, &[_]TValue{
        .{ .integer = 0 }, // R0: original value
        .{ .integer = ~@as(i64, 0) }, // R1: ~0 = -1
        .{ .integer = 5 }, // R2: loaded value
        .{ .integer = ~@as(i64, 5) }, // R3: ~5 = -6
    });

    // Verify only expected registers changed
    try utils.expectRegistersUnchanged(&trace, 4, &[_]u8{ 0, 1, 2, 3 });
}

test "BNOT: float to integer conversion" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 42.0
        Instruction.initABC(.BNOT, 1, 0, 0), // R1 = ~R0
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const constants = [_]TValue{
        .{ .number = 42.0 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = ~@as(i64, 42) });
}

test "BNOT: float with fractional part should error" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 42.5
        Instruction.initABC(.BNOT, 1, 0, 0), // R1 = ~R0 (should error)
        Instruction.initABC(.RETURN, 1, 2, 0),
    };

    const constants = [_]TValue{
        .{ .number = 42.5 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = vm.execute(&proto);

    try testing.expectError(error.ArithmeticError, result);
}

// ===== BAND (Bitwise AND) Tests =====

test "BAND: basic integer AND" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 0b1111
        Instruction.initABx(.LOADK, 1, 1), // R1 = 0b1010
        Instruction.initABC(.BAND, 2, 0, 1), // R2 = R0 & R1
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const constants = [_]TValue{
        .{ .integer = 0b1111 }, // 15
        .{ .integer = 0b1010 }, // 10
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();

    // Execute with state tracking
    var trace = utils.ExecutionTrace.captureInitial(&vm, 3);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 3);

    // Verify result and VM state
    try utils.expectResultAndState(result, TValue{ .integer = 0b1010 }, &vm, 0, 3);

    // Verify register changes
    try trace.expectRegisterChanged(0, TValue{ .integer = 0b1111 });
    try trace.expectRegisterChanged(1, TValue{ .integer = 0b1010 });
    try trace.expectRegisterChanged(2, TValue{ .integer = 0b1010 }); // Result of AND

    // Verify no other registers were affected
    try utils.expectRegistersUnchanged(&trace, 3, &[_]u8{ 0, 1, 2 });
}

test "BAND: mixed integer and float" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 255 (integer)
        Instruction.initABx(.LOADK, 1, 1), // R1 = 15.0 (float)
        Instruction.initABC(.BAND, 2, 0, 1), // R2 = R0 & R1
        Instruction.initABC(.RETURN, 2, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 255 },
        .{ .number = 15.0 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = 15 }); // 255 & 15 = 15
}

// ===== BOR (Bitwise OR) Tests =====

test "BOR: basic integer OR" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 0b1100
        Instruction.initABx(.LOADK, 1, 1), // R1 = 0b0011
        Instruction.initABC(.BOR, 2, 0, 1), // R2 = R0 | R1
        Instruction.initABC(.RETURN, 2, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 0b1100 }, // 12
        .{ .integer = 0b0011 }, // 3
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = 0b1111 }); // 12 | 3 = 15
}

// ===== BXOR (Bitwise XOR) Tests =====

test "BXOR: basic integer XOR" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 0b1111
        Instruction.initABx(.LOADK, 1, 1), // R1 = 0b1010
        Instruction.initABC(.BXOR, 2, 0, 1), // R2 = R0 ~ R1 (XOR in Lua)
        Instruction.initABC(.RETURN, 2, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 0b1111 }, // 15
        .{ .integer = 0b1010 }, // 10
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = 0b0101 }); // 15 ^ 10 = 5
}

// ===== Constant Bitwise Operations Tests =====

test "BANDK: AND with constant and side effect verification" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 255
        Instruction.initABC(.BANDK, 1, 0, 1), // R1 = R0 & K[1] (mask)
        Instruction.initABC(.RETURN, 1, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 255 },
        .{ .integer = 0xF0 }, // mask high nibble
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();

    // Initialize other registers to verify no side effects
    vm.stack[2] = TValue{ .integer = 999 };
    vm.stack[3] = TValue{ .boolean = true };

    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = 0xF0 }); // 255 & 0xF0 = 240

    // Verify only R0 and R1 changed
    try utils.expectRegister(&vm, 0, TValue{ .integer = 255 });
    try utils.expectRegister(&vm, 1, TValue{ .integer = 0xF0 });

    // Verify other registers unchanged
    try utils.expectRegister(&vm, 2, TValue{ .integer = 999 });
    try utils.expectRegister(&vm, 3, TValue{ .boolean = true });
}

test "BORK: OR with constant" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 0x0F
        Instruction.initABC(.BORK, 1, 0, 1), // R1 = R0 | K[1]
        Instruction.initABC(.RETURN, 1, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 0x0F },
        .{ .integer = 0xF0 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = 0xFF }); // 0x0F | 0xF0 = 0xFF
}

test "BXORK: XOR with constant" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 0xFF
        Instruction.initABC(.BXORK, 1, 0, 1), // R1 = R0 ~ K[1] (toggle bits)
        Instruction.initABC(.RETURN, 1, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 0xFF },
        .{ .integer = 0x55 }, // alternating bits
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = 0xAA }); // 0xFF ^ 0x55 = 0xAA
}

// ===== Shift Operations Tests =====

test "SHL: shift left basic" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initABx(.LOADK, 1, 1), // R1 = 4 (shift amount)
        Instruction.initABC(.SHL, 2, 0, 1), // R2 = R0 << R1
        Instruction.initABC(.RETURN, 2, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 4 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();

    // Execute and track state
    var trace = utils.ExecutionTrace.captureInitial(&vm, 3);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 3);

    // Verify result
    try utils.expectResultAndState(result, TValue{ .integer = 16 }, &vm, 0, 3);

    // Verify register state changes
    try trace.expectRegisterChanged(0, TValue{ .integer = 1 }); // R0: loaded value
    try trace.expectRegisterChanged(1, TValue{ .integer = 4 }); // R1: shift amount
    try trace.expectRegisterChanged(2, TValue{ .integer = 16 }); // R2: 1 << 4 = 16
}

test "SHL: negative shift (becomes right shift)" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 32
        Instruction.initABx(.LOADK, 1, 1), // R1 = -3 (negative shift)
        Instruction.initABC(.SHL, 2, 0, 1), // R2 = R0 << R1 (actually >> 3)
        Instruction.initABC(.RETURN, 2, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 32 },
        .{ .integer = -3 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = 4 }); // 32 >> 3 = 4
}

test "SHR: shift right basic" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 16
        Instruction.initABx(.LOADK, 1, 1), // R1 = 2
        Instruction.initABC(.SHR, 2, 0, 1), // R2 = R0 >> R1
        Instruction.initABC(.RETURN, 2, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 16 },
        .{ .integer = 2 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = 4 }); // 16 >> 2 = 4
}

test "SHR: arithmetic shift with negative number" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = -16
        Instruction.initABx(.LOADK, 1, 1), // R1 = 2
        Instruction.initABC(.SHR, 2, 0, 1), // R2 = R0 >> R1 (arithmetic shift)
        Instruction.initABC(.RETURN, 2, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = -16 },
        .{ .integer = 2 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = -4 }); // -16 >> 2 = -4 (sign preserved)
}

// ===== Immediate Shift Tests =====

test "SHLI: shift left immediate" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 3
        Instruction.initABC(.SHLI, 1, 0, 3), // R1 = R0 << 3 (immediate)
        Instruction.initABC(.RETURN, 1, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 3 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = 24 }); // 3 << 3 = 24
}

test "SHRI: shift right immediate" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 64
        Instruction.initABC(.SHRI, 1, 0, 4), // R1 = R0 >> 4 (immediate)
        Instruction.initABC(.RETURN, 1, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 64 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try utils.ReturnTest.expectSingle(result, TValue{ .integer = 4 }); // 64 >> 4 = 4
}

// ===== Complex Bitwise Operations Test =====

test "Bitwise: complex expression with state tracking" {
    // Test: (a & b) | (~c ^ d)
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = a = 0xFF
        Instruction.initABx(.LOADK, 1, 1), // R1 = b = 0x0F
        Instruction.initABx(.LOADK, 2, 2), // R2 = c = 0x55
        Instruction.initABx(.LOADK, 3, 3), // R3 = d = 0xAA
        Instruction.initABC(.BAND, 4, 0, 1), // R4 = a & b = 0x0F
        Instruction.initABC(.BNOT, 5, 2, 0), // R5 = ~c = ~0x55
        Instruction.initABC(.BXOR, 6, 5, 3), // R6 = (~c) ^ d
        Instruction.initABC(.BOR, 7, 4, 6), // R7 = (a & b) | ((~c) ^ d)

        Instruction.initABC(.RETURN, 7, 2, 0),
    };

    const constants = [_]TValue{
        .{ .integer = 0xFF },
        .{ .integer = 0x0F },
        .{ .integer = 0x55 },
        .{ .integer = 0xAA },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 8,
    };

    var vm = VM.init();

    // Capture execution state
    var trace = utils.ExecutionTrace.captureInitial(&vm, 8);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 8);

    // Calculate expected: (0xFF & 0x0F) | ((~0x55) ^ 0xAA)
    const expected = (0xFF & 0x0F) | ((~@as(i64, 0x55)) ^ 0xAA);
    try utils.ReturnTest.expectSingle(result, TValue{ .integer = expected });

    // Verify intermediate calculations in registers
    try trace.expectRegisterChanged(4, TValue{ .integer = 0x0F }); // a & b
    try trace.expectRegisterChanged(5, TValue{ .integer = ~@as(i64, 0x55) }); // ~c
    try trace.expectRegisterChanged(6, TValue{ .integer = (~@as(i64, 0x55)) ^ 0xAA }); // (~c) ^ d
    try trace.expectRegisterChanged(7, TValue{ .integer = expected }); // final result

    // Verify VM state consistency
    try utils.expectVMState(&vm, 0, 8);

    // Print trace for debugging (optional)
    // trace.print(8);
}

// ===== Error Cases =====

test "Bitwise operations with non-integer values should error" {
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = "hello"
        Instruction.initABx(.LOADK, 1, 1), // R1 = 5
        Instruction.initABC(.BAND, 2, 0, 1), // R2 = R0 & R1 (should error)
        Instruction.initABC(.RETURN, 2, 2, 0),
    };

    const constants = [_]TValue{
        .{ .boolean = true }, // Using boolean as non-numeric type
        .{ .integer = 5 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();
    const result = vm.execute(&proto);

    try testing.expectError(error.ArithmeticError, result);
}
