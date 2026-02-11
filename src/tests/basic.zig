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

fn expectNoResult(result: ReturnValue) !void {
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

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const proto = try test_utils.createTestProto(&vm, &constants, &code, 0, false, 3);
    const result = try Mnemonics.execute(&vm, proto);

    try expectSingleResult(result, TValue{ .integer = 3 });

    // Optional: print success for debugging
    // std.debug.print("basic: 1 + 2 = 3\n", .{});
}
