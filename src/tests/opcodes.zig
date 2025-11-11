const std = @import("std");
const testing = std.testing;

const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const OpCode = opcodes.OpCode;

test "Instruction packed struct size" {
    try testing.expectEqual(@sizeOf(u32), @sizeOf(Instruction));
}

test "Instruction ABC format" {
    const inst = Instruction.initABC(.ADD, 1, 2, 3);
    try testing.expectEqual(OpCode.ADD, inst.getOpCode());
    try testing.expectEqual(@as(u8, 1), inst.getA());
    try testing.expectEqual(@as(u8, 2), inst.getB());
    try testing.expectEqual(@as(u8, 3), inst.getC());
    try testing.expectEqual(false, inst.getk());
}

test "Instruction ABx format" {
    const inst = Instruction.initABx(.LOADK, 5, 12345);
    try testing.expectEqual(OpCode.LOADK, inst.getOpCode());
    try testing.expectEqual(@as(u8, 5), inst.getA());
    try testing.expectEqual(@as(u17, 12345), inst.getBx());
}

test "Instruction AsBx format" {
    // Test positive signed value
    const inst1 = Instruction.initAsBx(.FORPREP, 3, 100);
    try testing.expectEqual(OpCode.FORPREP, inst1.getOpCode());
    try testing.expectEqual(@as(u8, 3), inst1.getA());
    try testing.expectEqual(@as(i17, 100), inst1.getSBx());

    // Test negative signed value
    const inst2 = Instruction.initAsBx(.FORLOOP, 4, -50);
    try testing.expectEqual(OpCode.FORLOOP, inst2.getOpCode());
    try testing.expectEqual(@as(u8, 4), inst2.getA());
    try testing.expectEqual(@as(i17, -50), inst2.getSBx());
}

test "Instruction sJ format" {
    // Test positive jump
    const inst1 = Instruction.initsJ(.JMP, 1000);
    try testing.expectEqual(OpCode.JMP, inst1.getOpCode());
    try testing.expectEqual(@as(i25, 1000), inst1.getsJ());

    // Test negative jump
    const inst2 = Instruction.initsJ(.JMP, -500);
    try testing.expectEqual(OpCode.JMP, inst2.getOpCode());
    try testing.expectEqual(@as(i25, -500), inst2.getsJ());
}

test "Instruction ABCk format" {
    const inst = Instruction.initABCk(.TEST, 1, 2, 3, true);
    try testing.expectEqual(OpCode.TEST, inst.getOpCode());
    try testing.expectEqual(@as(u8, 1), inst.getA());
    try testing.expectEqual(@as(u8, 2), inst.getB());
    try testing.expectEqual(@as(u8, 3), inst.getC());
    try testing.expectEqual(true, inst.getk());
}

test "Instruction Ax format" {
    const inst = Instruction.initAx(.EXTRAARG, 0x1FFFFFF); // max 25-bit value
    try testing.expectEqual(OpCode.EXTRAARG, inst.getOpCode());
    try testing.expectEqual(@as(u25, 0x1FFFFFF), inst.getAx());
}
