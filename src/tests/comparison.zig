const std = @import("std");
const testing = std.testing;

const TValue = @import("../core/value.zig").TValue;
const Proto = @import("../vm/func.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

fn expectSingleResult(result: VM.ReturnValue, expected: TValue) !void {
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

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .boolean = true });
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

    var vm = VM.init();
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

    var vm = VM.init();
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

    var vm = VM.init();
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

    var vm = VM.init();
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

    var vm = VM.init();
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

    var vm = VM.init();
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

    var vm = VM.init();
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

    var vm = VM.init();
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

    var vm = VM.init();
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

    var vm = VM.init();
    const result = try vm.execute(&proto);

    // -100 == -100.0 should be true in Lua 5.3+
    try expectSingleResult(result, TValue{ .boolean = true });
}
