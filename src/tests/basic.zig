const std = @import("std");
const testing = std.testing;

const TValue = @import("../core/value.zig").TValue;
const Proto = @import("../core/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

fn expectSingleResult(result: VM.ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

fn expectNoResult(result: VM.ReturnValue) !void {
    try testing.expect(result == .none);
}

test "basic: 1 + 2 = 3" {
    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0),
        Instruction.initABx(.LOADK, 1, 1),
        Instruction.initABC(.ADD, 2, 0, 1),
        Instruction.initABC(.RETURN, 2, 2, 0),
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .integer = 3 });

    // Optional: print success for debugging
    // std.debug.print("✓ basic: 1 + 2 = 3\n", .{});
}
