const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const ReturnValue = @import("../vm/execution.zig").ReturnValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

const utils = @import("test_utils.zig");

fn expectSingleResult(result: ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

test "comparison: 5 == 5 = true" {
    const constants = [_]TValue{
        .{ .integer = 5 },
        .{ .integer = 5 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    // Using new EQ semantics: EQ A B C means "if (R[B] == R[C]) != A then skip next"
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5
        Instruction.initABx(.LOADK, 1, 1), // R1 = 5
        Instruction.initABC(.EQ, 1, 0, 1), // if (R0 == R1) != 1 then skip next (if NOT equal then skip)
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if equal)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not equal)
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

    // Added: ComparisonTest helper could be used for simpler verification
    // However, this test is complex so we verify manually
    var trace = utils.ExecutionTrace.captureInitial(&vm, 3);

    const result = try vm.execute(&proto);

    trace.updateFinal(&vm, 3);

    // Existing verification
    try expectSingleResult(result, TValue{ .boolean = true });

    // Added: Register and PC behavior verification
    try trace.expectRegisterChanged(0, TValue{ .integer = 5 });
    try trace.expectRegisterChanged(1, TValue{ .integer = 5 });
    try trace.expectRegisterChanged(2, TValue{ .boolean = true }); // EQ didn't skip, so true was set

    // VM final state
    try utils.expectVMState(&vm, 0, 3);
}

test "comparison: 5 == 3 = false" {
    const constants = [_]TValue{
        .{ .integer = 5 },
        .{ .integer = 3 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    // Using new EQ semantics: EQ A B C means "if (R[B] == R[C]) != A then skip next"
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3
        Instruction.initABC(.EQ, 0, 0, 1), // if (R0 == R1) != 0 then skip next (if equal then skip)
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not equal)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if equal)
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
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .boolean = false });
}

test "comparison: 3 < 5 = true" {
    const constants = [_]TValue{
        .{ .integer = 3 },
        .{ .integer = 5 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    // Using new LT semantics: LT A B C means "if (R[B] < R[C]) != A then skip next"
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 3
        Instruction.initABx(.LOADK, 1, 1), // R1 = 5
        Instruction.initABC(.LT, 1, 0, 1), // if (R0 < R1) != 1 then skip next (if NOT less than then skip)
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if less than)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not less than)
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
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .boolean = true });
}

test "comparison: 5 < 3 = false" {
    const constants = [_]TValue{
        .{ .integer = 5 },
        .{ .integer = 3 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3
        Instruction.initABC(.LT, 0, 0, 1), // if (R0 < R1) != 0 then skip next (if less than then skip)
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not less than)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if less than)
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
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .boolean = false });
}

test "comparison: 3 <= 5 = true" {
    const constants = [_]TValue{
        .{ .integer = 3 },
        .{ .integer = 5 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 3
        Instruction.initABx(.LOADK, 1, 1), // R1 = 5
        Instruction.initABC(.LE, 1, 0, 1), // if (R0 <= R1) != 1 then skip next
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if less than or equal)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not less than or equal)
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
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .boolean = true });
}

test "comparison: 5 <= 5 = true" {
    const constants = [_]TValue{
        .{ .integer = 5 },
        .{ .integer = 5 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5
        Instruction.initABx(.LOADK, 1, 1), // R1 = 5
        Instruction.initABC(.LE, 1, 0, 1), // if (R0 <= R1) != 1 then skip next
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if less than or equal)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not less than or equal)
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
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .boolean = true });
}

test "comparison: mixed types 3 < 3.5 = true" {
    const constants = [_]TValue{
        .{ .integer = 3 },
        .{ .number = 3.5 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 3
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3.5
        Instruction.initABC(.LT, 1, 0, 1), // if (R0 < R1) != 1 then skip next (if NOT less than then skip)
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if less than)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not less than)
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
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .boolean = true });
}

test "comparison: different types nil == false = false" {
    const constants = [_]TValue{
        .nil,
        .{ .boolean = false },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = nil
        Instruction.initABx(.LOADK, 1, 1), // R1 = false
        Instruction.initABC(.EQ, 0, 0, 1), // if (R0 == R1) != 0 then skip next (if equal then skip)
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not equal)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if equal)
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
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .boolean = false });
}

test "EQ instruction: Lua 5.3+ integer == float (1 == 1.0)" {
    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .number = 1.0 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1 (integer)
        Instruction.initABx(.LOADK, 1, 1), // R1 = 1.0 (float)
        Instruction.initABC(.EQ, 1, 0, 1), // if (R0 == R1) != 1 then skip next (if NOT equal then skip)
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if equal)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not equal)
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
    const result = try vm.execute(&proto);

    // In Lua 5.3+, 1 == 1.0 is true
    try expectSingleResult(result, TValue{ .boolean = true });
}

test "EQ instruction: integer != non-integer float (42 != 42.5)" {
    const constants = [_]TValue{
        .{ .integer = 42 },
        .{ .number = 42.5 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 42 (integer)
        Instruction.initABx(.LOADK, 1, 1), // R1 = 42.5 (float)
        Instruction.initABC(.EQ, 0, 0, 1), // if (R0 == R1) != 0 then skip next (if equal then skip)
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not equal)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if equal)
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
    const result = try vm.execute(&proto);

    // 42 != 42.5, so should return false
    try expectSingleResult(result, TValue{ .boolean = false });
}

test "EQ instruction: negative integer == float (-100 == -100.0)" {
    const constants = [_]TValue{
        .{ .integer = -100 },
        .{ .number = -100.0 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = -100 (integer)
        Instruction.initABx(.LOADK, 1, 1), // R1 = -100.0 (float)
        Instruction.initABC(.EQ, 1, 0, 1), // if (R0 == R1) != 1 then skip next (if NOT equal then skip)
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if equal)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not equal)
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
    const result = try vm.execute(&proto);

    // -100 == -100.0 should be true in Lua 5.3+
    try expectSingleResult(result, TValue{ .boolean = true });
}

// Added: Concise test using ComparisonTest helper
test "comparison: EQ with skip behavior verification" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Test 1: Equal values with A=0 (should skip)
    try utils.ComparisonTest.expectSkip(&vm, Instruction.initABC(.EQ, 0, 0, 1), // if (R0 == R1) == 0 then skip
        TValue{ .integer = 42 }, TValue{ .integer = 42 }, &[_]TValue{});

    // Test 2: Different values with A=0 (should not skip)
    vm.deinit();
    vm = try VM.init(testing.allocator);
    try utils.ComparisonTest.expectNoSkip(&vm, Instruction.initABC(.EQ, 0, 0, 1), TValue{ .integer = 42 }, TValue{ .integer = 24 }, &[_]TValue{});
}

test "comparison: LT with side effect verification" {
    // Verify that comparison instruction itself doesn't modify values
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10
        Instruction.initABx(.LOADK, 1, 1), // R1 = 20
        Instruction.initABC(.LT, 0, 0, 1), // if (R0 < R1) == 0 then skip (true, so skip)
        Instruction.initABx(.LOADK, 2, 2), // R2 = 100 (skipped)
        Instruction.initABx(.LOADK, 3, 3), // R3 = 200 (executed)
        Instruction.initABC(.RETURN, 0, 5, 0), // return R0..R3
    };

    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 20 },
        .{ .integer = 100 },
        .{ .integer = 200 },
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 4,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Initialize R2, R3 to track changes
    vm.stack[2] = .nil;
    vm.stack[3] = .nil;

    var trace = utils.ExecutionTrace.captureInitial(&vm, 4);
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 4);

    // Verify registers
    try trace.expectRegisterChanged(0, TValue{ .integer = 10 });
    try trace.expectRegisterChanged(1, TValue{ .integer = 20 });
    try trace.expectRegisterUnchanged(2); // R2 was skipped so remains nil
    try trace.expectRegisterChanged(3, TValue{ .integer = 200 }); // R3 was executed

    // Verify result
    try testing.expect(result == .multiple);
    try testing.expectEqual(@as(usize, 4), result.multiple.len);
}
