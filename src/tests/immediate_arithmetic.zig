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

test "ADDI: positive immediate with integer" {
    const constants = [_]TValue{
        .{ .integer = 10 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10
        Instruction.initABC(.ADDI, 1, 0, 5), // R1 = R0 + 5
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const proto = try test_utils.createTestProto(&vm, &constants, &code, 0, false, 2);
    const result = try Mnemonics.execute(&vm, proto);

    try expectSingleResult(result, TValue{ .integer = 15 });
}

test "ADDI: negative immediate with integer" {
    const constants = [_]TValue{
        .{ .integer = 10 },
    };

    // -3 as u8 = 253
    const neg_3: u8 = @bitCast(@as(i8, -3));

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10
        Instruction.initABC(.ADDI, 1, 0, neg_3), // R1 = R0 + (-3)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const proto = try test_utils.createTestProto(&vm, &constants, &code, 0, false, 2);
    const result = try Mnemonics.execute(&vm, proto);

    try expectSingleResult(result, TValue{ .integer = 7 });
}

test "ADDI: with float number" {
    const constants = [_]TValue{
        .{ .number = 10.5 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10.5
        Instruction.initABC(.ADDI, 1, 0, 3), // R1 = R0 + 3
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const proto = try test_utils.createTestProto(&vm, &constants, &code, 0, false, 2);
    const result = try Mnemonics.execute(&vm, proto);

    try expectSingleResult(result, TValue{ .number = 13.5 });
}

test "ADDI: maximum positive immediate" {
    const constants = [_]TValue{
        .{ .integer = 100 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 100
        Instruction.initABC(.ADDI, 1, 0, 127), // R1 = R0 + 127 (max i8)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const proto = try test_utils.createTestProto(&vm, &constants, &code, 0, false, 2);
    const result = try Mnemonics.execute(&vm, proto);

    try expectSingleResult(result, TValue{ .integer = 227 });
}

test "ADDI: maximum negative immediate" {
    const constants = [_]TValue{
        .{ .integer = 100 },
    };

    // -128 as u8 = 128
    const neg_128: u8 = @bitCast(@as(i8, -128));

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 100
        Instruction.initABC(.ADDI, 1, 0, neg_128), // R1 = R0 + (-128)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const proto = try test_utils.createTestProto(&vm, &constants, &code, 0, false, 2);
    const result = try Mnemonics.execute(&vm, proto);

    try expectSingleResult(result, TValue{ .integer = -28 });
}

test "ADDI: loop counter optimization" {
    const constants = [_]TValue{
        .{ .integer = 0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 0 (counter)
        Instruction.initABC(.ADDI, 0, 0, 1), // R0 = R0 + 1
        Instruction.initABC(.ADDI, 0, 0, 1), // R0 = R0 + 1
        Instruction.initABC(.ADDI, 0, 0, 1), // R0 = R0 + 1
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const proto = try test_utils.createTestProto(&vm, &constants, &code, 0, false, 1);
    const result = try Mnemonics.execute(&vm, proto);

    try expectSingleResult(result, TValue{ .integer = 3 });
}
