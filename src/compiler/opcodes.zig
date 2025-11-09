const std = @import("std");

pub const OpCode = enum(u7) {
    MOVE = 0,
    LOADK = 1,
    LOADKX = 2,
    LOADBOOL = 3,
    LOADNIL = 4,
    GETUPVAL = 5,
    SETUPVAL = 6,
    GETTABUP = 7,
    GETTABLE = 8,
    GETI = 9,
    GETFIELD = 10,
    SETTABUP = 11,
    SETTABLE = 12,
    SETI = 13,
    SETFIELD = 14,
    NEWTABLE = 15,
    SELF = 16,
    ADDI = 17,
    ADDK = 18,
    SUBK = 19,
    MULK = 20,
    MODK = 21,
    POWK = 22,
    DIVK = 23,
    IDIVK = 24,
    BANDK = 25,
    BORK = 26,
    BXORK = 27,
    SHRI = 28,
    SHLI = 29,
    ADD = 30,
    SUB = 31,
    MUL = 32,
    MOD = 33,
    POW = 34,
    DIV = 35,
    IDIV = 36,
    BAND = 37,
    BOR = 38,
    BXOR = 39,
    SHL = 40,
    SHR = 41,
    MMBIN = 42,
    MMBINI = 43,
    MMBINK = 44,
    UNM = 45,
    BNOT = 46,
    NOT = 47,
    LEN = 48,
    CONCAT = 49,
    CLOSE = 50,
    TBC = 51,
    JMP = 52,
    EQ = 53,
    LT = 54,
    LE = 55,
    EQK = 56,
    EQI = 57,
    LTI = 58,
    LEI = 59,
    GTI = 60,
    GEI = 61,
    TEST = 62,
    TESTSET = 63,
    CALL = 64,
    TAILCALL = 65,
    RETURN = 66,
    RETURN0 = 67,
    RETURN1 = 68,
    FORLOOP = 69,
    FORPREP = 70,
    TFORPREP = 71,
    TFORCALL = 72,
    TFORLOOP = 73,
    SETLIST = 74,
    CLOSURE = 75,
    VARARG = 76,
    VARARGPREP = 77,
    EXTRAARG = 78,
};

pub const OpMode = enum {
    iABC,
    iABx,
    iAsBx,
    iAx,
    isJ,
};

pub const InstructionFormat = struct {
    pub const SIZE_OP = 7;
    pub const SIZE_A = 8;
    pub const SIZE_B = 8;
    pub const SIZE_C = 8;
    pub const SIZE_k = 1;
    pub const SIZE_Bx = SIZE_B + SIZE_C + SIZE_k;
    pub const SIZE_Ax = SIZE_A + SIZE_B + SIZE_C + SIZE_k;
    pub const SIZE_sJ = SIZE_A + SIZE_B + SIZE_C + SIZE_k;

    pub const POS_OP = 0;
    pub const POS_A = POS_OP + SIZE_OP;
    pub const POS_k = POS_A + SIZE_A;
    pub const POS_B = POS_k + SIZE_k;
    pub const POS_C = POS_B + SIZE_B;
    pub const POS_Bx = POS_k;
    pub const POS_Ax = POS_A;
    pub const POS_sJ = POS_A;

    pub const MAXARG_A = (1 << SIZE_A) - 1;
    pub const MAXARG_B = (1 << SIZE_B) - 1;
    pub const MAXARG_C = (1 << SIZE_C) - 1;
    pub const MAXARG_Bx = (1 << SIZE_Bx) - 1;
    pub const MAXARG_Ax = (1 << SIZE_Ax) - 1;
    pub const MAXARG_sJ = (1 << SIZE_sJ) - 1;
    pub const OFFSET_sJ = MAXARG_sJ >> 1;
};

pub const Instruction = packed struct(u32) {
    op: u7,
    a: u8,
    k: bool,
    b: u8,
    c: u8,

    pub fn initABC(opcode: OpCode, a: u8, b: u8, c: u8) Instruction {
        return .{
            .op = @intFromEnum(opcode),
            .a = a,
            .k = false,
            .b = b,
            .c = c,
        };
    }

    pub fn initABCk(opcode: OpCode, a: u8, b: u8, c: u8, k: bool) Instruction {
        return .{
            .op = @intFromEnum(opcode),
            .a = a,
            .k = k,
            .b = b,
            .c = c,
        };
    }

    pub fn initABx(opcode: OpCode, a: u8, bx: u17) Instruction {
        const inst_value = @as(u32, @intFromEnum(opcode)) |
            (@as(u32, a) << InstructionFormat.POS_A) |
            (@as(u32, bx) << InstructionFormat.POS_Bx);
        return @bitCast(inst_value);
    }

    pub fn initAsBx(opcode: OpCode, a: u8, sbx: i17) Instruction {
        const bx = @as(u17, @bitCast(@as(u17, @intCast(sbx + InstructionFormat.OFFSET_sJ))));
        return initABx(opcode, a, bx);
    }

    pub fn initAx(opcode: OpCode, ax: u25) Instruction {
        const inst_value = @as(u32, @intFromEnum(opcode)) |
            (@as(u32, ax) << InstructionFormat.POS_Ax);
        return @bitCast(inst_value);
    }

    pub fn initsJ(opcode: OpCode, sj: i25) Instruction {
        const j = @as(u25, @intCast(sj + InstructionFormat.OFFSET_sJ));
        const inst_value = @as(u32, @intFromEnum(opcode)) |
            (@as(u32, j) << InstructionFormat.POS_sJ);
        return @bitCast(inst_value);
    }

    pub fn getOpCode(self: Instruction) OpCode {
        return @enumFromInt(self.op);
    }

    pub fn getA(self: Instruction) u8 {
        return self.a;
    }

    pub fn getB(self: Instruction) u8 {
        return self.b;
    }

    pub fn getC(self: Instruction) u8 {
        return self.c;
    }

    pub fn getk(self: Instruction) bool {
        return self.k;
    }

    pub fn getBx(self: Instruction) u17 {
        const raw: u32 = @bitCast(self);
        return @intCast((raw >> InstructionFormat.POS_Bx) & InstructionFormat.MAXARG_Bx);
    }

    pub fn getsBx(self: Instruction) i17 {
        return @as(i17, @bitCast(self.getBx())) - InstructionFormat.OFFSET_sJ;
    }

    pub fn getAx(self: Instruction) u25 {
        const raw: u32 = @bitCast(self);
        return @intCast((raw >> InstructionFormat.POS_Ax) & InstructionFormat.MAXARG_Ax);
    }

    pub fn getsJ(self: Instruction) i25 {
        const raw: u32 = @bitCast(self);
        const j = (raw >> InstructionFormat.POS_sJ) & InstructionFormat.MAXARG_sJ;
        return @as(i25, @intCast(j)) - InstructionFormat.OFFSET_sJ;
    }
};

const testing = std.testing;

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
