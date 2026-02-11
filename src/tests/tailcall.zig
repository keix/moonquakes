const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

test "TAILCALL - basic structure" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // This test verifies the TAILCALL opcode structure
    // Full tail call testing requires closures, so we use the parser tests

    // Test that TAILCALL with non-function value raises error
    vm.stack[0] = .{ .integer = 10 };

    const code = [_]Instruction{
        // TAILCALL R0, 1, 0: return R0() with 0 args
        Instruction.initABC(.TAILCALL, 0, 1, 0),
    };

    const proto = Proto{
        .k = &.{},
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    // Should fail because integer is not a function
    const result = Mnemonics.execute(&vm, &proto);
    try testing.expectError(error.NotAFunction, result);
}
