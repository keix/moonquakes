const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

const test_utils = @import("test_utils.zig");

test "TAILCALL - basic structure" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // This test verifies the TAILCALL opcode structure
    // Full tail call testing requires closures, so we use the parser tests

    // Test that TAILCALL with non-function value raises error
    ctx.vm.stack[0] = .{ .integer = 10 };

    const code = [_]Instruction{
        // TAILCALL R0, 1, 0: return R0() with 0 args
        Instruction.initABC(.TAILCALL, 0, 1, 0),
    };

    const proto = try test_utils.createTestProto(ctx.vm, &.{}, &code, 0, false, 3);

    // Should fail because integer is not a function
    const result = Mnemonics.execute(ctx.vm, proto);
    try testing.expectError(error.LuaException, result);
}
