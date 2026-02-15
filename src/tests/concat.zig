const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const ReturnValue = @import("../vm/execution.zig").ReturnValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

const test_utils = @import("test_utils.zig");

fn expectSingleResult(result: ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

test "concat: \"hello\" .. \"world\" = \"helloworld\"" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Allocate strings through GC
    const hello_str = try ctx.vm.gc.allocString("hello");
    const world_str = try ctx.vm.gc.allocString("world");
    const expected_str = try ctx.vm.gc.allocString("helloworld");

    const constants = [_]TValue{
        TValue.fromString(hello_str),
        TValue.fromString(world_str),
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = "hello"
        Instruction.initABx(.LOADK, 1, 1), // R1 = "world"
        Instruction.initABC(.CONCAT, 2, 0, 1), // R2 = R0 .. R1
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);

    var trace = test_utils.ExecutionTrace.captureInitial(&ctx.vm, 3);
    const result = try Mnemonics.execute(&ctx.vm, proto);
    trace.updateFinal(&ctx.vm, 3);

    try test_utils.expectResultAndState(result, TValue.fromString(expected_str), &ctx.vm, 0, 3);

    // Verify register changes
    try trace.expectRegisterChanged(0, TValue.fromString(hello_str));
    try trace.expectRegisterChanged(1, TValue.fromString(world_str));
    try trace.expectRegisterChanged(2, TValue.fromString(expected_str));

    // Verify no side effects
    try test_utils.expectRegistersUnchanged(&trace, 3, &[_]u8{ 0, 1, 2 });
}

test "concat: \"hello\" .. \"\" .. \"world\" = \"helloworld\"" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Allocate strings through GC
    const hello_str = try ctx.vm.gc.allocString("hello");
    const empty_str = try ctx.vm.gc.allocString("");
    const world_str = try ctx.vm.gc.allocString("world");
    const expected_str = try ctx.vm.gc.allocString("helloworld");

    const constants = [_]TValue{
        TValue.fromString(hello_str),
        TValue.fromString(empty_str),
        TValue.fromString(world_str),
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = "hello"
        Instruction.initABx(.LOADK, 1, 1), // R1 = ""
        Instruction.initABx(.LOADK, 2, 2), // R2 = "world"
        Instruction.initABC(.CONCAT, 3, 0, 2), // R3 = R0 .. R1 .. R2
        Instruction.initABC(.RETURN, 3, 2, 0), // return R3
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 5);

    // Set up registers beyond what we need to verify no side effects
    ctx.vm.stack[4] = TValue{ .boolean = true };

    var trace = test_utils.ExecutionTrace.captureInitial(&ctx.vm, 5);
    const result = try Mnemonics.execute(&ctx.vm, proto);
    trace.updateFinal(&ctx.vm, 5);

    try test_utils.expectResultAndState(result, TValue.fromString(expected_str), &ctx.vm, 0, 5);

    // Verify register states
    try test_utils.expectRegisters(&ctx.vm, 0, &[_]TValue{
        TValue.fromString(hello_str), // R0
        TValue.fromString(empty_str), // R1
        TValue.fromString(world_str), // R2
        TValue.fromString(expected_str), // R3
    });

    // Verify register 4 is unchanged (side effect check)
    try trace.expectRegisterUnchanged(4);
    try test_utils.expectRegistersUnchanged(&trace, 5, &[_]u8{ 0, 1, 2, 3 });
}

test "concat: \"number: \" .. 42 = \"number: 42\"" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Allocate strings through GC
    const prefix_str = try ctx.vm.gc.allocString("number: ");
    const expected_str = try ctx.vm.gc.allocString("number: 42");

    const constants = [_]TValue{
        TValue.fromString(prefix_str),
        .{ .integer = 42 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = "number: "
        Instruction.initABx(.LOADK, 1, 1), // R1 = 42
        Instruction.initABC(.CONCAT, 2, 0, 1), // R2 = R0 .. R1
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);

    var trace = test_utils.ExecutionTrace.captureInitial(&ctx.vm, 3);
    const result = try Mnemonics.execute(&ctx.vm, proto);
    trace.updateFinal(&ctx.vm, 3);

    try expectSingleResult(result, TValue.fromString(expected_str));

    // Verify register changes with specific values
    try trace.expectRegisterChanged(0, TValue.fromString(prefix_str));
    try trace.expectRegisterChanged(1, TValue{ .integer = 42 });
    try trace.expectRegisterChanged(2, TValue.fromString(expected_str));

    // VM state verification
    try test_utils.expectVMState(&ctx.vm, 0, 3);
}

test "concat: 1 .. 2 .. 3 = \"123\"" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Allocate expected string through GC
    const expected_str = try ctx.vm.gc.allocString("123");

    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initABx(.LOADK, 1, 1), // R1 = 2
        Instruction.initABx(.LOADK, 2, 2), // R2 = 3
        Instruction.initABC(.CONCAT, 3, 0, 2), // R3 = R0 .. R1 .. R2
        Instruction.initABC(.RETURN, 3, 2, 0), // return R3
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 6);

    // Initialize extra registers to test side effects
    const untouched_str = try ctx.vm.gc.allocString("untouched");
    ctx.vm.stack[4] = TValue.fromString(untouched_str);
    ctx.vm.stack[5] = TValue{ .number = 9.99 };

    var trace = test_utils.ExecutionTrace.captureInitial(&ctx.vm, 6);
    const result = try Mnemonics.execute(&ctx.vm, proto);
    trace.updateFinal(&ctx.vm, 6);

    try test_utils.expectResultAndState(result, TValue.fromString(expected_str), &ctx.vm, 0, 6);

    // Verify all register states
    try test_utils.expectRegisters(&ctx.vm, 0, &[_]TValue{
        .{ .integer = 1 }, // R0
        .{ .integer = 2 }, // R1
        .{ .integer = 3 }, // R2
        TValue.fromString(expected_str), // R3
    });

    // Verify no side effects on registers 4 and 5
    try trace.expectRegisterUnchanged(4);
    try trace.expectRegisterUnchanged(5);
    try test_utils.expectRegistersUnchanged(&trace, 6, &[_]u8{ 0, 1, 2, 3 });
}

test "concat: 3.14 .. \" is pi\" = \"3.14 is pi\"" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Allocate strings through GC
    const suffix_str = try ctx.vm.gc.allocString(" is pi");
    const expected_str = try ctx.vm.gc.allocString("3.14 is pi");

    const constants = [_]TValue{
        .{ .number = 3.14 },
        TValue.fromString(suffix_str),
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 3.14
        Instruction.initABx(.LOADK, 1, 1), // R1 = " is pi"
        Instruction.initABC(.CONCAT, 2, 0, 1), // R2 = R0 .. R1
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);

    var trace = test_utils.ExecutionTrace.captureInitial(&ctx.vm, 3);
    const result = try Mnemonics.execute(&ctx.vm, proto);
    trace.updateFinal(&ctx.vm, 3);

    try expectSingleResult(result, TValue.fromString(expected_str));

    // Detailed register verification
    try trace.expectRegisterChanged(0, TValue{ .number = 3.14 });
    try trace.expectRegisterChanged(1, TValue.fromString(suffix_str));
    try trace.expectRegisterChanged(2, TValue.fromString(expected_str));

    // Complete state verification
    try test_utils.expectVMState(&ctx.vm, 0, 3);
    try test_utils.expectRegistersUnchanged(&trace, 3, &[_]u8{ 0, 1, 2 });
}

test "concat: empty concatenation (single string)" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Allocate string through GC
    const alone_str = try ctx.vm.gc.allocString("alone");

    const constants = [_]TValue{
        TValue.fromString(alone_str),
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = "alone"
        Instruction.initABC(.CONCAT, 1, 0, 0), // R1 = R0 (single value concat)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 2);

    var trace = test_utils.ExecutionTrace.captureInitial(&ctx.vm, 2);
    const result = try Mnemonics.execute(&ctx.vm, proto);
    trace.updateFinal(&ctx.vm, 2);

    try test_utils.expectResultAndState(result, TValue.fromString(alone_str), &ctx.vm, 0, 2);

    // Verify single value concatenation behavior
    try trace.expectRegisterChanged(0, TValue.fromString(alone_str));
    try trace.expectRegisterChanged(1, TValue.fromString(alone_str));

    // Ensure no other registers affected
    try test_utils.expectRegistersUnchanged(&trace, 2, &[_]u8{ 0, 1 });
}
