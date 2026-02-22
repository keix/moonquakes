const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const ReturnValue = @import("../vm/execution.zig").ReturnValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

const test_utils = @import("test_utils.zig");

fn expectNoResult(result: ReturnValue) !void {
    try testing.expect(result == .none);
}

fn expectSingleResult(result: ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

fn expectMultipleResults(result: ReturnValue, expected: []const TValue) !void {
    try testing.expect(result == .multiple);
    try testing.expectEqual(expected.len, result.multiple.len);
    for (expected, result.multiple) |exp, actual| {
        try testing.expect(exp.eql(actual));
    }
}

test "return: no values (RETURN with B=1)" {
    const code = [_]Instruction{
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &[_]TValue{}, &code, 0, false, 1);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try expectNoResult(result);
}

test "return: single value (RETURN with B=2)" {
    const constants = [_]TValue{
        .{ .integer = 42 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 42
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 1);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try expectSingleResult(result, TValue{ .integer = 42 });
}

test "return: multiple values (RETURN with B=4)" {
    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initABx(.LOADK, 1, 1), // R1 = 2
        Instruction.initABx(.LOADK, 2, 2), // R2 = 3
        Instruction.initABC(.RETURN, 0, 4, 0), // return R0, R1, R2 (B=4 means 3 values)
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 3);
    const result = try Mnemonics.execute(ctx.vm, proto);

    const expected = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
    };
    try expectMultipleResults(result, &expected);
}

test "return: RETURN0 - no values" {
    const code = [_]Instruction{
        Instruction.initABC(.RETURN0, 0, 0, 0), // return nothing
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &[_]TValue{}, &code, 0, false, 1);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try testing.expect(result == .none);
}

test "return: RETURN1 - single value" {
    const constants = [_]TValue{
        .{ .integer = 42 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 42
        Instruction.initABC(.RETURN1, 0, 0, 0), // return R0
    };

    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &code, 0, false, 1);
    const result = try Mnemonics.execute(ctx.vm, proto);

    try expectSingleResult(result, TValue{ .integer = 42 });
}
