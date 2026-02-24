const std = @import("std");
const testing = std.testing;
const Mnemonics = @import("../vm/mnemonics.zig");
const TValue = @import("../runtime/value.zig").TValue;
const Instruction = @import("../compiler/opcodes.zig").Instruction;
const test_utils = @import("test_utils.zig");

test "CALL returns multiple values" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const func_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = 10
        Instruction.initABx(.LOADK, 1, 1), // R[1] = 20
        Instruction.initABC(.RETURN, 0, 3, 0), // return R[0], R[1]
    };
    const func_constants = [_]TValue{ .{ .integer = 10 }, .{ .integer = 20 } };

    const func_proto = try test_utils.createTestProto(ctx.vm, &func_constants, &func_code, 0, false, 2);
    const func_closure = try ctx.vm.gc().allocClosure(func_proto);

    const main_constants = [_]TValue{TValue.fromClosure(func_closure)};
    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = func
        Instruction.initABC(.CALL, 0, 1, 3), // expect 2 results in R[0], R[1]
        Instruction.initABC(.RETURN, 0, 3, 0), // return R[0], R[1]
    };
    const main_proto = try test_utils.createTestProto(ctx.vm, &main_constants, &main_code, 0, false, 2);

    const result = try Mnemonics.execute(ctx.vm, main_proto);
    try test_utils.ReturnTest.expectMultiple(result, &[_]TValue{ .{ .integer = 10 }, .{ .integer = 20 } });
}

test "CALL fills nil when callee returns no values" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const func_code = [_]Instruction{
        Instruction.initABC(.RETURN0, 0, 0, 0), // return no values
    };

    const func_proto = try test_utils.createTestProto(ctx.vm, &[_]TValue{}, &func_code, 0, false, 1);
    const func_closure = try ctx.vm.gc().allocClosure(func_proto);

    const main_constants = [_]TValue{TValue.fromClosure(func_closure)};
    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = func
        Instruction.initABC(.CALL, 0, 1, 2), // expect 1 result in R[0]
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const main_proto = try test_utils.createTestProto(ctx.vm, &main_constants, &main_code, 0, false, 1);

    const result = try Mnemonics.execute(ctx.vm, main_proto);
    try test_utils.ReturnTest.expectSingle(result, .nil);
}

test "CALL pads missing results with nil" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const func_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = 99
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const func_constants = [_]TValue{.{ .integer = 99 }};

    const func_proto = try test_utils.createTestProto(ctx.vm, &func_constants, &func_code, 0, false, 1);
    const func_closure = try ctx.vm.gc().allocClosure(func_proto);

    const main_constants = [_]TValue{TValue.fromClosure(func_closure)};
    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = func
        Instruction.initABC(.CALL, 0, 1, 3), // expect 2 results in R[0], R[1]
        Instruction.initABC(.RETURN, 0, 3, 0), // return R[0], R[1]
    };
    const main_proto = try test_utils.createTestProto(ctx.vm, &main_constants, &main_code, 0, false, 2);

    const result = try Mnemonics.execute(ctx.vm, main_proto);
    try test_utils.ReturnTest.expectMultiple(result, &[_]TValue{ .{ .integer = 99 }, .nil });
}
