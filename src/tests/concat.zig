const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

const utils = @import("test_utils.zig");

fn expectSingleResult(result: VM.ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

test "concat: \"hello\" .. \"world\" = \"helloworld\"" {
    const constants = [_]TValue{
        .{ .string = "hello" },
        .{ .string = "world" },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = "hello"
        Instruction.initABx(.LOADK, 1, 1), // R1 = "world"
        Instruction.initABC(.CONCAT, 2, 0, 1), // R2 = R0 .. R1
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var trace = utils.ExecutionTrace.captureInitial(&vm, 3);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 3);

    try utils.expectResultAndState(result, TValue{ .string = "helloworld" }, &vm, 0, 3);

    // Verify register changes
    try trace.expectRegisterChanged(0, TValue{ .string = "hello" });
    try trace.expectRegisterChanged(1, TValue{ .string = "world" });
    try trace.expectRegisterChanged(2, TValue{ .string = "helloworld" });

    // Verify no side effects
    try utils.expectRegistersUnchanged(&trace, 3, &[_]u8{ 0, 1, 2 });
}

test "concat: \"hello\" .. \"\" .. \"world\" = \"helloworld\"" {
    const constants = [_]TValue{
        .{ .string = "hello" },
        .{ .string = "" },
        .{ .string = "world" },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = "hello"
        Instruction.initABx(.LOADK, 1, 1), // R1 = ""
        Instruction.initABx(.LOADK, 2, 2), // R2 = "world"
        Instruction.initABC(.CONCAT, 3, 0, 2), // R3 = R0 .. R1 .. R2
        Instruction.initABC(.RETURN, 3, 2, 0), // return R3
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 5, // Extra space to verify no side effects
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Set up registers beyond what we need to verify no side effects
    vm.stack[4] = TValue{ .boolean = true };

    var trace = utils.ExecutionTrace.captureInitial(&vm, 5);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 5);

    try utils.expectResultAndState(result, TValue{ .string = "helloworld" }, &vm, 0, 5);

    // Verify register states
    try utils.expectRegisters(&vm, 0, &[_]TValue{
        .{ .string = "hello" }, // R0
        .{ .string = "" }, // R1
        .{ .string = "world" }, // R2
        .{ .string = "helloworld" }, // R3
    });

    // Verify register 4 is unchanged (side effect check)
    try trace.expectRegisterUnchanged(4);
    try utils.expectRegistersUnchanged(&trace, 5, &[_]u8{ 0, 1, 2, 3 });
}

test "concat: \"number: \" .. 42 = \"number: 42\"" {
    const constants = [_]TValue{
        .{ .string = "number: " },
        .{ .integer = 42 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = "number: "
        Instruction.initABx(.LOADK, 1, 1), // R1 = 42
        Instruction.initABC(.CONCAT, 2, 0, 1), // R2 = R0 .. R1
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var trace = utils.ExecutionTrace.captureInitial(&vm, 3);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 3);

    try expectSingleResult(result, TValue{ .string = "number: 42" });

    // Verify register changes with specific values
    try trace.expectRegisterChanged(0, TValue{ .string = "number: " });
    try trace.expectRegisterChanged(1, TValue{ .integer = 42 });
    try trace.expectRegisterChanged(2, TValue{ .string = "number: 42" });

    // VM state verification
    try utils.expectVMState(&vm, 0, 3);
}

test "concat: 1 .. 2 .. 3 = \"123\"" {
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

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 6, // Extra space for side effect testing
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Initialize extra registers to test side effects
    vm.stack[4] = TValue{ .string = "untouched" };
    vm.stack[5] = TValue{ .number = 9.99 };

    var trace = utils.ExecutionTrace.captureInitial(&vm, 6);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 6);

    try utils.expectResultAndState(result, TValue{ .string = "123" }, &vm, 0, 6);

    // Verify all register states
    try utils.expectRegisters(&vm, 0, &[_]TValue{
        .{ .integer = 1 }, // R0
        .{ .integer = 2 }, // R1
        .{ .integer = 3 }, // R2
        .{ .string = "123" }, // R3
    });

    // Verify no side effects on registers 4 and 5
    try trace.expectRegisterUnchanged(4);
    try trace.expectRegisterUnchanged(5);
    try utils.expectRegistersUnchanged(&trace, 6, &[_]u8{ 0, 1, 2, 3 });
}

test "concat: 3.14 .. \" is pi\" = \"3.14 is pi\"" {
    const constants = [_]TValue{
        .{ .number = 3.14 },
        .{ .string = " is pi" },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 3.14
        Instruction.initABx(.LOADK, 1, 1), // R1 = " is pi"
        Instruction.initABC(.CONCAT, 2, 0, 1), // R2 = R0 .. R1
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var trace = utils.ExecutionTrace.captureInitial(&vm, 3);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 3);

    try expectSingleResult(result, TValue{ .string = "3.14 is pi" });

    // Detailed register verification
    try trace.expectRegisterChanged(0, TValue{ .number = 3.14 });
    try trace.expectRegisterChanged(1, TValue{ .string = " is pi" });
    try trace.expectRegisterChanged(2, TValue{ .string = "3.14 is pi" });

    // Complete state verification
    try utils.expectVMState(&vm, 0, 3);
    try utils.expectRegistersUnchanged(&trace, 3, &[_]u8{ 0, 1, 2 });
}

test "concat: empty concatenation (single string)" {
    const constants = [_]TValue{
        .{ .string = "alone" },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = "alone"
        Instruction.initABC(.CONCAT, 1, 0, 0), // R1 = R0 (single value concat)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var trace = utils.ExecutionTrace.captureInitial(&vm, 2);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 2);

    try utils.expectResultAndState(result, TValue{ .string = "alone" }, &vm, 0, 2);

    // Verify single value concatenation behavior
    try trace.expectRegisterChanged(0, TValue{ .string = "alone" });
    try trace.expectRegisterChanged(1, TValue{ .string = "alone" });

    // Ensure no other registers affected
    try utils.expectRegistersUnchanged(&trace, 2, &[_]u8{ 0, 1 });
}
