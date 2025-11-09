const std = @import("std");
const testing = std.testing;

const TValue = @import("../core/value.zig").TValue;
const Proto = @import("../vm/func.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

test "arithmetic: 10 - 3 * 2 = 4" {
    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 3 },
        .{ .integer = 2 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3
        Instruction.initABx(.LOADK, 2, 2), // R2 = 2
        Instruction.initABC(.MUL, 3, 1, 2), // R3 = R1 * R2 = 6
        Instruction.initABC(.SUB, 4, 0, 3), // R4 = R0 - R3 = 4
        Instruction.initABC(.RETURN, 4, 2, 0), // return R4
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 5,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try testing.expect(result != null);
    try testing.expect(result.?.eql(TValue{ .integer = 4 }));
}

test "arithmetic: 10 / 3" {
    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0),
        Instruction.initABx(.LOADK, 1, 1),
        Instruction.initABC(.DIV, 2, 0, 1),
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

    try testing.expect(result != null);
    try testing.expect(result.?.isNumber());
    try testing.expectApproxEqAbs(result.?.number, 3.333333, 0.00001);
}

test "arithmetic: 10 // 3 = 3" {
    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0),
        Instruction.initABx(.LOADK, 1, 1),
        Instruction.initABC(.IDIV, 2, 0, 1),
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

    try testing.expect(result != null);
    try testing.expect(result.?.eql(TValue{ .number = 3 }));
}

test "arithmetic: 10 % 3 = 1" {
    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0),
        Instruction.initABx(.LOADK, 1, 1),
        Instruction.initABC(.MOD, 2, 0, 1),
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

    try testing.expect(result != null);
    try testing.expect(result.?.eql(TValue{ .number = 1 }));
}
