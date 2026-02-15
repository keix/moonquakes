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

test "VARARGPREP continues execution" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // VARARGPREP A: prepare vararg function with A fixed parameters
    // In our implementation, this is mostly a no-op since CALL handles setup
    // Just verify it doesn't crash and continues to next instruction
    const code = [_]Instruction{
        Instruction.initAsBx(.LOADI, 0, 42), // R0 = 42
        Instruction.initABC(.VARARGPREP, 2, 0, 0), // 2 fixed params (no-op)
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &[_]TValue{}, &code, 2, true, 3);
    const result = try Mnemonics.execute(&ctx.vm, proto);

    try expectSingleResult(result, TValue{ .integer = 42 });
}

test "VARARG loads first vararg with C=2" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // VARARG A C: load C-1 varargs into R[A]...
    // C=2 means load 1 value
    // This test simulates a vararg function called with extra args

    // We'll create a closure that uses varargs and call it
    const inner_code = [_]Instruction{
        Instruction.initABC(.VARARGPREP, 1, 0, 0), // 1 fixed param
        Instruction.initABC(.VARARG, 1, 0, 2), // R1 = first vararg (C=2 means 1 value)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const inner_proto = try test_utils.createTestProto(&ctx.vm, &[_]TValue{}, &inner_code, 1, true, 4);

    // Create closure via GC
    const inner_closure = try ctx.vm.gc.allocClosure(inner_proto);

    // Main code: call the vararg function with args (10, 20, 30)
    // The function has 1 fixed param, so varargs are (20, 30)
    var constants = [_]TValue{
        TValue.fromClosure(inner_closure),
        .{ .integer = 10 }, // first arg (fixed)
        .{ .integer = 20 }, // second arg (first vararg)
        .{ .integer = 30 }, // third arg (second vararg)
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = closure
        Instruction.initABx(.LOADK, 1, 1), // R1 = 10
        Instruction.initABx(.LOADK, 2, 2), // R2 = 20
        Instruction.initABx(.LOADK, 3, 3), // R3 = 30
        Instruction.initABC(.CALL, 0, 4, 2), // call R0(R1,R2,R3), expect 1 result
        Instruction.initABC(.RETURN, 0, 2, 0), // return result
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 5);
    const result = try Mnemonics.execute(&ctx.vm, proto);

    // Function receives (10, 20, 30), fixed param is 10, varargs are (20, 30)
    // VARARG with C=2 loads first vararg = 20
    try expectSingleResult(result, TValue{ .integer = 20 });
}

test "VARARG with no varargs returns nil" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // When function is called with only fixed params, varargs should be empty
    const inner_code = [_]Instruction{
        Instruction.initABC(.VARARGPREP, 1, 0, 0), // 1 fixed param
        Instruction.initABC(.VARARG, 1, 0, 2), // R1 = first vararg (should be nil)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const inner_proto = try test_utils.createTestProto(&ctx.vm, &[_]TValue{}, &inner_code, 1, true, 4);

    // Create closure via GC
    const inner_closure = try ctx.vm.gc.allocClosure(inner_proto);

    var constants = [_]TValue{
        TValue.fromClosure(inner_closure),
        .{ .integer = 42 }, // only fixed param
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = closure
        Instruction.initABx(.LOADK, 1, 1), // R1 = 42
        Instruction.initABC(.CALL, 0, 2, 2), // call R0(R1), expect 1 result
        Instruction.initABC(.RETURN, 0, 2, 0), // return result
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);
    const result = try Mnemonics.execute(&ctx.vm, proto);

    // No varargs passed, so first vararg should be nil
    try expectSingleResult(result, .nil);
}

test "vararg function with no fixed params" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // function(...) return ... end
    const inner_code = [_]Instruction{
        Instruction.initABC(.VARARGPREP, 0, 0, 0), // 0 fixed params
        Instruction.initABC(.VARARG, 0, 0, 2), // R0 = first vararg
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    const inner_proto = try test_utils.createTestProto(&ctx.vm, &[_]TValue{}, &inner_code, 0, true, 3);

    // Create closure via GC
    const inner_closure = try ctx.vm.gc.allocClosure(inner_proto);

    var constants = [_]TValue{
        TValue.fromClosure(inner_closure),
        .{ .integer = 100 },
        .{ .integer = 200 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = closure
        Instruction.initABx(.LOADK, 1, 1), // R1 = 100
        Instruction.initABx(.LOADK, 2, 2), // R2 = 200
        Instruction.initABC(.CALL, 0, 3, 2), // call R0(100, 200)
        Instruction.initABC(.RETURN, 0, 2, 0),
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 4);
    const result = try Mnemonics.execute(&ctx.vm, proto);

    // All args are varargs, first one is 100
    try expectSingleResult(result, TValue{ .integer = 100 });
}
