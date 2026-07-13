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

fn expectMultipleResults(result: ReturnValue, expected: []const TValue) !void {
    try testing.expect(result == .multiple);
    try testing.expectEqual(expected.len, result.multiple.len);
    for (expected, result.multiple) |e, r| {
        try testing.expect(e.eql(r));
    }
}

test "LOADI: load signed immediate integer" {
    const code = [_]Instruction{
        Instruction.initAsBx(.LOADI, 0, 42), // R0 = 42
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &[_]TValue{}, &code, 0, false, 1);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try expectSingleResult(result, TValue.fromInt(42));
}

test "LOADI: load negative signed immediate" {
    const code = [_]Instruction{
        Instruction.initAsBx(.LOADI, 0, -100), // R0 = -100
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &[_]TValue{}, &code, 0, false, 1);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try expectSingleResult(result, TValue.fromInt(-100));
}

test "LOADF: load signed immediate as float" {
    const code = [_]Instruction{
        Instruction.initAsBx(.LOADF, 0, 42), // R0 = 42.0
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &[_]TValue{}, &code, 0, false, 1);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try expectSingleResult(result, TValue.fromFloat(42.0));
}

test "LOADFALSE: load false" {
    const code = [_]Instruction{
        Instruction.initABC(.LOADFALSE, 0, 0, 0), // R0 = false
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &[_]TValue{}, &code, 0, false, 1);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try expectSingleResult(result, TValue.fromBool(false));
}

test "LOADTRUE: load true" {
    const code = [_]Instruction{
        Instruction.initABC(.LOADTRUE, 0, 0, 0), // R0 = true
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &[_]TValue{}, &code, 0, false, 1);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try expectSingleResult(result, TValue.fromBool(true));
}

test "LFALSESKIP: load false and skip" {
    const code = [_]Instruction{
        Instruction.initABC(.LFALSESKIP, 0, 0, 0), // R0 = false, skip next
        Instruction.initABC(.LOADTRUE, 0, 0, 0), // This should be skipped
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0 (should be false)
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &[_]TValue{}, &code, 0, false, 1);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try expectSingleResult(result, TValue.fromBool(false));
}

test "LOADNIL: single register" {
    const constants = [_]TValue{
        TValue.fromInt(42), // Some initial value
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 42
        Instruction.initABC(.LOADNIL, 0, 0, 0), // R0 = nil (B=0 means only R[A])
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 1);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try expectSingleResult(result, TValue.nil);
}

test "LOADNIL: multiple registers" {
    const constants = [_]TValue{
        TValue.fromInt(1),
        TValue.fromInt(2),
        TValue.fromInt(3),
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initABx(.LOADK, 1, 1), // R1 = 2
        Instruction.initABx(.LOADK, 2, 2), // R2 = 3
        Instruction.initABC(.LOADNIL, 0, 2, 0), // R0, R1, R2 = nil (B=2 means R[A]..R[A+2])
        Instruction.initABC(.RETURN, 0, 4, 0), // return R0, R1, R2
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 3);
    const result = try Mnemonics.execute(ctx.vm, proto);

    const expected = [_]TValue{ .nil, .nil, .nil };
    try expectMultipleResults(result, &expected);
}

test "LOADNIL: range in middle of stack" {
    const constants = [_]TValue{
        TValue.fromInt(1),
        TValue.fromInt(5),
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initABx(.LOADK, 4, 1), // R4 = 5
        Instruction.initABC(.LOADNIL, 1, 2, 0), // R1, R2, R3 = nil
        Instruction.initABC(.RETURN, 0, 6, 0), // return R0, R1, R2, R3, R4
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 5);
    const result = try Mnemonics.execute(ctx.vm, proto);

    const expected = [_]TValue{
        TValue.fromInt(1),
        .nil,
        .nil,
        .nil,
        TValue.fromInt(5),
    };
    try expectMultipleResults(result, &expected);
}
