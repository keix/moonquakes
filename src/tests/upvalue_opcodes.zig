const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const Proto = @import("../compiler/proto.zig").Proto;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const test_utils = @import("test_utils.zig");

test "CLOSE opcode - no-op behavior" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Initialize some registers
    vm.stack[0] = .{ .integer = 42 };
    vm.stack[1] = .{ .number = 3.14 };
    vm.stack[2] = .{ .boolean = true };

    const inst = Instruction.initABC(.CLOSE, 1, 0, 0); // close from R[1] upward

    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = Proto{
        .k = &[_]TValue{},
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    const initial_trace = test_utils.ExecutionTrace.captureInitial(&vm, 3);

    const result = try vm.execute(&proto);
    try test_utils.ReturnTest.expectNone(result);

    var final_trace = initial_trace;
    final_trace.updateFinal(&vm, 3);

    // CLOSE should be a no-op for now - all registers should be unchanged
    try final_trace.expectRegisterUnchanged(0);
    try final_trace.expectRegisterUnchanged(1);
    try final_trace.expectRegisterUnchanged(2);
}

test "TBC opcode - no-op behavior" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Allocate string through GC
    const test_str = try vm.gc.allocString("test");

    // Initialize some registers
    vm.stack[0] = .{ .string = test_str };
    vm.stack[1] = .{ .integer = 100 };

    const inst = Instruction.initABC(.TBC, 1, 0, 0); // mark R[1] as to-be-closed

    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = Proto{
        .k = &[_]TValue{},
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    const initial_trace = test_utils.ExecutionTrace.captureInitial(&vm, 3);

    const result = try vm.execute(&proto);
    try test_utils.ReturnTest.expectNone(result);

    var final_trace = initial_trace;
    final_trace.updateFinal(&vm, 3);

    // TBC should be a no-op for now - all registers should be unchanged
    try final_trace.expectRegisterUnchanged(0);
    try final_trace.expectRegisterUnchanged(1);
    try final_trace.expectRegisterUnchanged(2);
}

test "SETUPVAL opcode - no-op behavior" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Initialize some registers
    vm.stack[0] = .{ .integer = 123 };
    vm.stack[1] = .{ .boolean = false };

    const inst = Instruction.initABC(.SETUPVAL, 0, 1, 0); // UpValue[1] := R[0]

    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = Proto{
        .k = &[_]TValue{},
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    const initial_trace = test_utils.ExecutionTrace.captureInitial(&vm, 3);

    const result = try vm.execute(&proto);
    try test_utils.ReturnTest.expectNone(result);

    var final_trace = initial_trace;
    final_trace.updateFinal(&vm, 3);

    // SETUPVAL should be a no-op for now - all registers should be unchanged
    try final_trace.expectRegisterUnchanged(0);
    try final_trace.expectRegisterUnchanged(1);
    try final_trace.expectRegisterUnchanged(2);
}

test "SETTABUP opcode - global variable assignment" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Allocate string through GC
    const myvar_str = try vm.gc.allocString("myvar");

    // Create constant for variable name
    const constants = [_]TValue{
        .{ .string = myvar_str }, // K[0]
    };

    // Initialize register with value to set
    vm.stack[1] = .{ .integer = 42 };

    const inst = Instruction.initABC(.SETTABUP, 0, 0, 1); // _ENV[K[0]] := R[1]

    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    const result = try vm.execute(&proto);
    try test_utils.ReturnTest.expectNone(result);

    // Verify the global variable was set
    const global_val = vm.globals.get("myvar").?;
    try testing.expect(global_val.eql(.{ .integer = 42 }));
}

test "SETTABUP opcode - multiple global assignments" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Allocate strings through GC
    const var1_str = try vm.gc.allocString("var1");
    const var2_str = try vm.gc.allocString("var2");
    const var3_str = try vm.gc.allocString("var3");

    // Create constants for variable names
    const constants = [_]TValue{
        .{ .string = var1_str }, // K[0]
        .{ .string = var2_str }, // K[1]
        .{ .string = var3_str }, // K[2]
    };

    // Initialize registers with values to set
    vm.stack[0] = .{ .integer = 10 };
    vm.stack[1] = .{ .number = 3.14 };
    vm.stack[2] = .{ .boolean = true };

    const code = [_]Instruction{
        Instruction.initABC(.SETTABUP, 0, 0, 0), // _ENV[K[0]] := R[0]
        Instruction.initABC(.SETTABUP, 0, 1, 1), // _ENV[K[1]] := R[1]
        Instruction.initABC(.SETTABUP, 0, 2, 2), // _ENV[K[2]] := R[2]
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    const result = try vm.execute(&proto);
    try test_utils.ReturnTest.expectNone(result);

    // Verify all global variables were set correctly
    const var1 = vm.globals.get("var1").?;
    const var2 = vm.globals.get("var2").?;
    const var3 = vm.globals.get("var3").?;

    try testing.expect(var1.eql(.{ .integer = 10 }));
    try testing.expect(var2.eql(.{ .number = 3.14 }));
    try testing.expect(var3.eql(.{ .boolean = true }));
}

test "SETTABUP opcode - invalid key type" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Create constant with non-string key
    const constants = [_]TValue{
        .{ .integer = 123 }, // K[0] - invalid key type
    };

    vm.stack[1] = .{ .integer = 42 };

    const inst = Instruction.initABC(.SETTABUP, 0, 0, 1); // _ENV[K[0]] := R[1]

    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, 0, 1, 0),
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    // Should fail with InvalidTableKey error
    const result = vm.execute(&proto);
    try testing.expectError(error.InvalidTableKey, result);
}

test "All new opcodes - integration test" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Allocate string through GC
    const result_str = try vm.gc.allocString("result");

    const constants = [_]TValue{
        .{ .string = result_str }, // K[0]
    };

    // Initialize registers
    vm.stack[0] = .{ .integer = 999 };
    vm.stack[1] = .{ .number = 2.71 };

    const code = [_]Instruction{
        // Test all four new opcodes in sequence
        Instruction.initABC(.CLOSE, 1, 0, 0), // close from R[1] upward (no-op)
        Instruction.initABC(.TBC, 0, 0, 0), // mark R[0] as to-be-closed (no-op)
        Instruction.initABC(.SETUPVAL, 1, 0, 0), // UpValue[0] := R[1] (no-op)
        Instruction.initABC(.SETTABUP, 0, 0, 0), // _ENV[K[0]] := R[0] (sets global)
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    const result = try vm.execute(&proto);
    try test_utils.ReturnTest.expectNone(result);

    // Only SETTABUP should have side effects
    const global_val = vm.globals.get("result").?;
    try testing.expect(global_val.eql(.{ .integer = 999 }));
}
