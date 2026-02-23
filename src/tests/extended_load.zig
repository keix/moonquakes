const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");
const Mnemonics = @import("../vm/mnemonics.zig");
const TValue = @import("../runtime/value.zig").TValue;
const opcodes = @import("../compiler/opcodes.zig");
const OpCode = opcodes.OpCode;
const Instruction = opcodes.Instruction;

test "LOADKX with EXTRAARG loads large constant index" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // Create constants array with value at large index
    const constants = [_]TValue{
        .nil, .nil, .nil, .nil, .nil, // Padding to create large index
        .{ .integer = 42 }, // Index 5
    };

    // LOADKX R[0] := K[EXTRAARG], EXTRAARG ax=5, RETURN
    const instructions = [_]Instruction{
        Instruction.initABC(.LOADKX, 0, 0, 0),
        Instruction.initAx(.EXTRAARG, 5), // Large constant index
        Instruction.initABC(.RETURN, 0, 1, 0), // Return with no values
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &instructions, 0, false, 10);

    _ = try Mnemonics.execute(ctx.vm, proto);

    // Verify R[0] contains the constant value from index 5
    try test_utils.expectRegister(ctx.vm, 0, .{ .integer = 42 });

    // Verify other registers remain uninitialized
    try test_utils.expectNilRange(ctx.vm, 1, 5);
}

test "GETI with nil table returns error" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    const constants = [_]TValue{.nil};

    // GETI R[0] := R[0][1] (R[0] is nil, not a table)
    const instructions = [_]Instruction{
        Instruction.initABC(.GETI, 0, 0, 1),
        Instruction.initABC(.RETURN, 0, 1, 0), // Return with no values
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &instructions, 0, false, 10);

    // Should return InvalidTableOperation since R[0] is nil
    const result = Mnemonics.execute(ctx.vm, proto);
    try testing.expect(std.meta.isError(result));
    // Note: We can't test specific error type without proper error handling
}

test "GETFIELD with nil table returns nil (shared metatable support)" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // Allocate string through GC
    const name_str = try ctx.vm.gc().allocString("name");

    // Constants array with string key
    const constants = [_]TValue{
        TValue.fromString(name_str), // Index 0 - field name
    };

    // GETFIELD R[1] := R[0][K[0]] where K[0] = "name", R[0] is nil
    const instructions = [_]Instruction{
        Instruction.initABC(.GETFIELD, 1, 0, 0),
        Instruction.initABC(.RETURN, 1, 2, 0), // Return R[1]
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &instructions, 0, false, 10);

    // Lua 5.4: indexing nil without a metatable should error
    const result = Mnemonics.execute(ctx.vm, proto);
    try testing.expectError(error.LuaException, result);
}

test "Multiple LOADKX operations" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // Allocate string through GC
    const hello_str = try ctx.vm.gc().allocString("hello");

    // Create constants with multiple values
    const constants = [_]TValue{
        TValue.fromString(hello_str), // Index 0
        .{ .number = 3.14 }, // Index 1
        .nil, .nil, .nil, // Padding
        .{ .integer = 100 }, // Index 5
        .{ .boolean = true }, // Index 6
    };

    // Load multiple constants using LOADKX
    const instructions = [_]Instruction{
        // R[0] := K[5] (integer 100)
        Instruction.initABC(.LOADKX, 0, 0, 0),
        Instruction.initAx(.EXTRAARG, 5),

        // R[1] := K[6] (boolean true)
        Instruction.initABC(.LOADKX, 1, 0, 0),
        Instruction.initAx(.EXTRAARG, 6),

        // R[2] := K[0] (string "hello")
        Instruction.initABC(.LOADKX, 2, 0, 0),
        Instruction.initAx(.EXTRAARG, 0),
        Instruction.initABC(.RETURN, 0, 1, 0), // Return with no values
    };

    const proto = try test_utils.createTestProto(ctx.vm, &constants, &instructions, 0, false, 10);

    _ = try Mnemonics.execute(ctx.vm, proto);

    // Verify all loaded values
    try test_utils.expectRegisters(ctx.vm, 0, &[_]TValue{
        .{ .integer = 100 }, // R[0]
        .{ .boolean = true }, // R[1]
        TValue.fromString(hello_str), // R[2]
    });

    // Verify remaining registers are nil
    try test_utils.expectNilRange(ctx.vm, 3, 5);
}
