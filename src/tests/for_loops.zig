const std = @import("std");
const testing = std.testing;

const TValue = @import("../core/value.zig").TValue;
const Proto = @import("../vm/func.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const OpCode = opcodes.OpCode;

fn expectSingleResult(result: VM.ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

test "FORPREP minimal test" {
    const constants = [_]TValue{
        .{ .integer = 5 }, // init
        .{ .integer = 1 }, // step
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5 (init)
        Instruction.initABx(.LOADK, 2, 1), // R2 = 1 (step)
        Instruction.initAsBx(.FORPREP, 0, 0), // FORPREP A=0, sBx=0 (jump to next = RETURN)
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0 (should be 5-1=4)
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

    try expectSingleResult(result, TValue{ .number = 4.0 }); // init - step = 5 - 1 = 4
}

test "for loop: simple integer loop 1 to 3" {
    const constants = [_]TValue{
        .{ .integer = 1 }, // init (R0)
        .{ .integer = 3 }, // limit (R1)
        .{ .integer = 1 }, // step  (R2)
        .{ .integer = 0 }, // accumulator (R4)
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3
        Instruction.initABx(.LOADK, 2, 2), // R2 = 1
        Instruction.initABx(.LOADK, 4, 3), // R4 = 0
        // ---- FOR structure ----
        // index 4: FORPREP jumps directly to index 6 (FORLOOP)
        Instruction.initAsBx(.FORPREP, 0, 1), // (PC += 1 → FORLOOP)
        // index 5: loop body
        Instruction.initABC(.ADD, 4, 4, 3), // R4 += R3 (control variable)
        // index 6:
        Instruction.initAsBx(.FORLOOP, 0, -2), // if continue: jump back to index 5
        // index 7:
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

    try expectSingleResult(result, TValue{ .integer = 6 }); // 1+2+3 = 6
}
