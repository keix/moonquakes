const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const ReturnValue = @import("../vm/execution.zig").ReturnValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

const test_utils = @import("test_utils.zig");

fn expectError(result: anyerror!ReturnValue, expected_error: anyerror) !void {
    if (result) |_| {
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(expected_error, err);
    }
}

test "DIV: division by zero (integer)" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10
        Instruction.initABx(.LOADK, 1, 1), // R1 = 0
        Instruction.initABC(.DIV, 2, 0, 1), // R2 = R0 / R1 (10 / 0)
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);
    const result = Mnemonics.execute(&ctx.vm, proto);

    try expectError(result, error.ArithmeticError);
}

test "DIV: division by zero (float)" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .number = 10.5 },
        .{ .number = 0.0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10.5
        Instruction.initABx(.LOADK, 1, 1), // R1 = 0.0
        Instruction.initABC(.DIV, 2, 0, 1), // R2 = R0 / R1 (10.5 / 0.0)
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);
    const result = Mnemonics.execute(&ctx.vm, proto);

    try expectError(result, error.ArithmeticError);
}

test "IDIV: integer division by zero" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 20 },
        .{ .integer = 0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 20
        Instruction.initABx(.LOADK, 1, 1), // R1 = 0
        Instruction.initABC(.IDIV, 2, 0, 1), // R2 = R0 // R1 (20 // 0)
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);
    const result = Mnemonics.execute(&ctx.vm, proto);

    try expectError(result, error.ArithmeticError);
}

test "MOD: modulo by zero" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 15 },
        .{ .integer = 0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 15
        Instruction.initABx(.LOADK, 1, 1), // R1 = 0
        Instruction.initABC(.MOD, 2, 0, 1), // R2 = R0 % R1 (15 % 0)
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);
    const result = Mnemonics.execute(&ctx.vm, proto);

    try expectError(result, error.ArithmeticError);
}

test "DIVK: division by zero constant" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 25 },
        .{ .number = 0.0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 25
        Instruction.initABC(.DIVK, 1, 0, 1), // R1 = R0 / K[1] (25 / 0.0)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 2);
    const result = Mnemonics.execute(&ctx.vm, proto);

    try expectError(result, error.ArithmeticError);
}

test "IDIVK: integer division by zero constant" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 30 },
        .{ .integer = 0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 30
        Instruction.initABC(.IDIVK, 1, 0, 1), // R1 = R0 // K[1] (30 // 0)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 2);
    const result = Mnemonics.execute(&ctx.vm, proto);

    try expectError(result, error.ArithmeticError);
}

test "MODK: modulo by zero constant" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 35 },
        .{ .integer = 0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 35
        Instruction.initABC(.MODK, 1, 0, 1), // R1 = R0 % K[1] (35 % 0)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 2);
    const result = Mnemonics.execute(&ctx.vm, proto);

    try expectError(result, error.ArithmeticError);
}

test "Division operations with non-zero divisors should succeed" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{
        .{ .integer = 20 },
        .{ .integer = 4 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 20
        Instruction.initABx(.LOADK, 1, 1), // R1 = 4
        Instruction.initABC(.DIV, 2, 0, 1), // R2 = R0 / R1 (20 / 4 = 5.0)
        Instruction.initABC(.IDIV, 3, 0, 1), // R3 = R0 // R1 (20 // 4 = 5.0)
        Instruction.initABC(.MOD, 4, 0, 1), // R4 = R0 % R1 (20 % 4 = 0.0)
        Instruction.initABC(.RETURN, 2, 4, 0), // return R2, R3, R4
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 5);
    const result = try Mnemonics.execute(&ctx.vm, proto);

    try testing.expect(result == .multiple);
    try testing.expectEqual(@as(usize, 3), result.multiple.len);
    try testing.expect(result.multiple[0].eql(TValue{ .number = 5.0 }));
    try testing.expect(result.multiple[1].eql(TValue{ .number = 5.0 }));
    try testing.expect(result.multiple[2].eql(TValue{ .number = 0.0 }));
}
