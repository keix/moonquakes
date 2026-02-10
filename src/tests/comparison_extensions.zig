const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");
const Mnemonics = @import("../vm/mnemonics.zig");
const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const opcodes = @import("../compiler/opcodes.zig");
const OpCode = opcodes.OpCode;
const Instruction = opcodes.Instruction;

test "EQK: equality with constant - skip on match" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Test R[1] == K[0] where R[1] = 42 and K[0] = 42 (should skip)
    const constants = [_]TValue{
        .{ .integer = 42 }, // Index 0
    };

    const instructions = [_]Instruction{
        Instruction.initABC(.EQK, 0, 1, 0), // if R[1] == K[0] then skip (A=0: normal)
        Instruction.initABC(.LOADTRUE, 0, 0, 0), // should be skipped
        Instruction.initABC(.LOADFALSE, 0, 0, 0), // should execute
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    var proto = Proto{
        .code = &instructions,
        .k = &constants,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 10,
    };

    // Set R[1] = 42
    vm.stack[vm.base + 1] = .{ .integer = 42 };

    const result = try Mnemonics.execute(&vm, &proto);

    // Should skip LOADTRUE R[0], execute LOADFALSE R[0]
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(TValue{ .boolean = false }));
}

test "EQK: equality with constant - no skip on mismatch" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Test R[1] == K[0] where R[1] = 42 and K[0] = 100 (should not skip)
    const constants = [_]TValue{
        .{ .integer = 100 }, // Index 0
    };

    const instructions = [_]Instruction{
        Instruction.initABC(.EQK, 0, 1, 0), // if R[1] == K[0] then skip (A=0: normal)
        Instruction.initABC(.LOADTRUE, 0, 0, 0), // should execute
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    var proto = Proto{
        .code = &instructions,
        .k = &constants,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 10,
    };

    // Set R[1] = 42
    vm.stack[vm.base + 1] = .{ .integer = 42 };

    const result = try Mnemonics.execute(&vm, &proto);

    // Should execute LOADTRUE R[0]
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(TValue{ .boolean = true }));
}

test "EQI: equality with immediate integer" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Test R[1] == 42 where R[1] = 42 (should skip)
    const instructions = [_]Instruction{
        Instruction.initABC(.EQI, 0, 1, 42), // if R[1] == 42 then skip
        Instruction.initABC(.LOADTRUE, 0, 0, 0), // should be skipped
        Instruction.initABC(.LOADFALSE, 0, 0, 0), // should execute
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    var proto = Proto{
        .code = &instructions,
        .k = &.{},
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 10,
    };

    // Set R[1] = 42
    vm.stack[vm.base + 1] = .{ .integer = 42 };

    const result = try Mnemonics.execute(&vm, &proto);

    // Should skip, so R[0] should be false
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(TValue{ .boolean = false }));
}

test "LTI: less than immediate integer" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Test R[1] < 50 where R[1] = 42 (should skip)
    const instructions = [_]Instruction{
        Instruction.initABC(.LTI, 0, 1, 50), // if R[1] < 50 then skip
        Instruction.initABC(.LOADTRUE, 0, 0, 0), // should be skipped
        Instruction.initABC(.LOADFALSE, 0, 0, 0), // should execute
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    var proto = Proto{
        .code = &instructions,
        .k = &.{},
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 10,
    };

    // Set R[1] = 42
    vm.stack[vm.base + 1] = .{ .integer = 42 };

    const result = try Mnemonics.execute(&vm, &proto);

    // Should skip, so R[0] should be false
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(TValue{ .boolean = false }));
}

test "LEI: less than or equal immediate integer" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Test R[1] <= 42 where R[1] = 42 (should skip)
    const instructions = [_]Instruction{
        Instruction.initABC(.LEI, 0, 1, 42), // if R[1] <= 42 then skip
        Instruction.initABC(.LOADTRUE, 0, 0, 0), // should be skipped
        Instruction.initABC(.LOADFALSE, 0, 0, 0), // should execute
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    var proto = Proto{
        .code = &instructions,
        .k = &.{},
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 10,
    };

    // Set R[1] = 42
    vm.stack[vm.base + 1] = .{ .integer = 42 };

    const result = try Mnemonics.execute(&vm, &proto);

    // Should skip, so R[0] should be false
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(TValue{ .boolean = false }));
}

test "GTI: greater than immediate integer" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Test R[1] > 30 where R[1] = 42 (should skip)
    const instructions = [_]Instruction{
        Instruction.initABC(.GTI, 0, 1, 30), // if R[1] > 30 then skip
        Instruction.initABC(.LOADFALSE, 0, 1, 0), // should be skipped
        Instruction.initABC(.LOADFALSE, 0, 0, 0), // should execute
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    var proto = Proto{
        .code = &instructions,
        .k = &.{},
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 10,
    };

    // Set R[1] = 42
    vm.stack[vm.base + 1] = .{ .integer = 42 };

    const result = try Mnemonics.execute(&vm, &proto);

    // Should skip, so R[0] should be false
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(TValue{ .boolean = false }));
}

test "GEI: greater than or equal immediate integer" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Test R[1] >= 42 where R[1] = 42 (should skip)
    const instructions = [_]Instruction{
        Instruction.initABC(.GEI, 0, 1, 42), // if R[1] >= 42 then skip
        Instruction.initABC(.LOADFALSE, 0, 1, 0), // should be skipped
        Instruction.initABC(.LOADFALSE, 0, 0, 0), // should execute
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    var proto = Proto{
        .code = &instructions,
        .k = &.{},
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 10,
    };

    // Set R[1] = 42
    vm.stack[vm.base + 1] = .{ .integer = 42 };

    const result = try Mnemonics.execute(&vm, &proto);

    // Should skip, so R[0] should be false
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(TValue{ .boolean = false }));
}

test "Comparison extensions: negative immediate values" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Test R[1] > -10 where R[1] = 5 (should skip)
    // Using signed immediate -10 (encoded as 256-10=246 in unsigned byte)
    const neg_10: u8 = @bitCast(@as(i8, -10));

    const instructions = [_]Instruction{
        Instruction.initABC(.GTI, 0, 1, neg_10), // if R[1] > -10 then skip
        Instruction.initABC(.LOADFALSE, 0, 1, 0), // should be skipped
        Instruction.initABC(.LOADFALSE, 0, 0, 0), // should execute
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    var proto = Proto{
        .code = &instructions,
        .k = &.{},
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 10,
    };

    // Set R[1] = 5
    vm.stack[vm.base + 1] = .{ .integer = 5 };

    const result = try Mnemonics.execute(&vm, &proto);

    // Should skip, so R[0] should be false
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(TValue{ .boolean = false }));
}

test "Comparison extensions: floating point values" {
    var vm = try test_utils.createTestVM();
    defer vm.deinit();

    // Test R[1] < 100 where R[1] = 3.14 (should skip)
    const instructions = [_]Instruction{
        Instruction.initABC(.LTI, 0, 1, 100), // if R[1] < 100 then skip
        Instruction.initABC(.LOADFALSE, 0, 1, 0), // should be skipped
        Instruction.initABC(.LOADFALSE, 0, 0, 0), // should execute
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    var proto = Proto{
        .code = &instructions,
        .k = &.{},
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 10,
    };

    // Set R[1] = 3.14
    vm.stack[vm.base + 1] = .{ .number = 3.14 };

    const result = try Mnemonics.execute(&vm, &proto);

    // Should skip, so R[0] should be false
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(TValue{ .boolean = false }));
}
