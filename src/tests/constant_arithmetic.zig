const std = @import("std");
const testing = std.testing;

const TValue = @import("../core/value.zig").TValue;
const Proto = @import("../core/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const OpCode = opcodes.OpCode;

fn expectSingleResult(result: VM.ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

test "ADDK: integer + integer constant" {
    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 25 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10
        Instruction.initABC(.ADDK, 1, 0, 1), // R1 = R0 + K[1] (10 + 25)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .integer = 35 });
}

test "ADDK: number + number constant" {
    const constants = [_]TValue{
        .{ .number = 10.5 },
        .{ .number = 2.25 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10.5
        Instruction.initABC(.ADDK, 1, 0, 1), // R1 = R0 + K[1] (10.5 + 2.25)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .number = 12.75 });
}

test "SUBK: integer - integer constant" {
    const constants = [_]TValue{
        .{ .integer = 50 },
        .{ .integer = 15 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 50
        Instruction.initABC(.SUBK, 1, 0, 1), // R1 = R0 - K[1] (50 - 15)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .integer = 35 });
}

test "MULK: integer * integer constant" {
    const constants = [_]TValue{
        .{ .integer = 7 },
        .{ .integer = 6 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 7
        Instruction.initABC(.MULK, 1, 0, 1), // R1 = R0 * K[1] (7 * 6)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .integer = 42 });
}

test "DIVK: number / number constant" {
    const constants = [_]TValue{
        .{ .number = 100.0 },
        .{ .number = 4.0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 100.0
        Instruction.initABC(.DIVK, 1, 0, 1), // R1 = R0 / K[1] (100.0 / 4.0)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .number = 25.0 });
}

test "IDIVK: integer // constant" {
    const constants = [_]TValue{
        .{ .integer = 17 },
        .{ .integer = 5 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 17
        Instruction.initABC(.IDIVK, 1, 0, 1), // R1 = R0 // K[1] (17 // 5)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .number = 3.0 });
}

test "MODK: integer % constant" {
    const constants = [_]TValue{
        .{ .integer = 17 },
        .{ .integer = 5 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 17
        Instruction.initABC(.MODK, 1, 0, 1), // R1 = R0 % K[1] (17 % 5)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .number = 2.0 });
}

test "Constant arithmetic: mixed types" {
    const constants = [_]TValue{
        .{ .integer = 10 },
        .{ .number = 2.5 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 10 (integer)
        Instruction.initABC(.MULK, 1, 0, 1), // R1 = R0 * K[1] (10 * 2.5)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .number = 25.0 });
}

test "Constant arithmetic: chain operations" {
    const constants = [_]TValue{
        .{ .integer = 100 },
        .{ .integer = 10 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 100
        Instruction.initABC(.SUBK, 0, 0, 1), // R0 = R0 - K[1] (100 - 10 = 90)
        Instruction.initABC(.DIVK, 0, 0, 2), // R0 = R0 / K[2] (90 / 3 = 30)
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .number = 30.0 });
}

test "MODK: Lua-style negative modulo" {
    const constants = [_]TValue{
        .{ .number = -7.0 },
        .{ .number = 5.0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = -7.0
        Instruction.initABC(.MODK, 1, 0, 1), // R1 = R0 % K[1] (-7 % 5 = 3 in Lua)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .number = 3.0 });
}

test "IDIVK: Lua-style floor division with negative" {
    const constants = [_]TValue{
        .{ .number = -7.0 },
        .{ .number = 5.0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = -7.0
        Instruction.initABC(.IDIVK, 1, 0, 1), // R1 = R0 // K[1] (-7 // 5 = -2 in Lua)
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .number = -2.0 });
}
