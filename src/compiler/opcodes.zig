const std = @import("std");

pub const OpCode = enum(u7) {
    MOVE = 0,
    LOADI = 1,
    LOADF = 2,
    LOADK = 3,
    LOADKX = 4,
    LOADFALSE = 5,
    LFALSESKIP = 6,
    LOADTRUE = 7,
    LOADNIL = 8,
    GETUPVAL = 9,
    SETUPVAL = 10,
    GETTABUP = 11,
    GETTABLE = 12,
    GETI = 13,
    GETFIELD = 14,
    SETTABUP = 15,
    SETTABLE = 16,
    SETI = 17,
    SETFIELD = 18,
    NEWTABLE = 19,
    SELF = 20,
    ADDI = 21,
    ADDK = 22,
    SUBK = 23,
    MULK = 24,
    MODK = 25,
    POWK = 26,
    DIVK = 27,
    IDIVK = 28,
    BANDK = 29,
    BORK = 30,
    BXORK = 31,
    SHRI = 32,
    SHLI = 33,
    ADD = 34,
    SUB = 35,
    MUL = 36,
    MOD = 37,
    POW = 38,
    DIV = 39,
    IDIV = 40,
    BAND = 41,
    BOR = 42,
    BXOR = 43,
    SHL = 44,
    SHR = 45,
    MMBIN = 46,
    MMBINI = 47,
    MMBINK = 48,
    UNM = 49,
    BNOT = 50,
    NOT = 51,
    LEN = 52,
    CONCAT = 53,
    CLOSE = 54,
    TBC = 55,
    JMP = 56,
    EQ = 57,
    LT = 58,
    LE = 59,
    EQK = 60,
    EQI = 61,
    LTI = 62,
    LEI = 63,
    GTI = 64,
    GEI = 65,
    TEST = 66,
    TESTSET = 67,
    CALL = 68,
    TAILCALL = 69,
    RETURN = 70,
    RETURN0 = 71,
    RETURN1 = 72,
    FORLOOP = 73,
    FORPREP = 74,
    TFORPREP = 75,
    TFORCALL = 76,
    TFORLOOP = 77,
    SETLIST = 78,
    CLOSURE = 79,
    VARARG = 80,
    VARARGPREP = 81,
    EXTRAARG = 82,

    // --- Extended opcodes (100+) ---
    // These opcodes are not part of the original Lua 5.4 instruction set.
    // They encode VM-level control semantics that cannot be expressed
    // as ordinary function calls (e.g. protected execution).
    //
    // Reserved range: 100-127 (to avoid collision with future Lua opcodes)
    // Lua 5.4 uses 0-82, leaving buffer for future standard opcodes.

    /// PCALL A B C - Protected call: R(A), ..., R(A+C-2) := pcall(R(A+1), R(A+2), ..., R(A+B))
    /// On success: R(A) = true, R(A+1...) = return values
    /// On failure: R(A) = false, R(A+1) = error message
    PCALL = 100,
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
    pub const OFFSET_sBx = MAXARG_Bx >> 1;
};

pub const Instruction = packed struct(u32) {
    op: u7,
    a: u8,
    k: bool,
    b: u8,
    c: u8,

    // iABC: [op:7][a:8][k:1][b:8][c:8]
    pub fn initABC(opcode: OpCode, a: u8, b: u8, c: u8) Instruction {
        return .{
            .op = @intFromEnum(opcode),
            .a = a,
            .k = false,
            .b = b,
            .c = c,
        };
    }

    // iABC: [op:7][a:8][k:1][b:8][c:8] with k flag
    pub fn initABCk(opcode: OpCode, a: u8, b: u8, c: u8, k: bool) Instruction {
        return .{
            .op = @intFromEnum(opcode),
            .a = a,
            .k = k,
            .b = b,
            .c = c,
        };
    }

    // iABx: [op:7][a:8][bx:17]
    pub fn initABx(opcode: OpCode, a: u8, bx: u17) Instruction {
        const inst_value = @as(u32, @intFromEnum(opcode)) |
            (@as(u32, a) << InstructionFormat.POS_A) |
            (@as(u32, bx) << InstructionFormat.POS_Bx);
        return @bitCast(inst_value);
    }

    // iAsBx: [op:7][a:8][sbx:17] (17-bit signed)
    pub fn initAsBx(opcode: OpCode, a: u8, sbx: i17) Instruction {
        const offset_val = @as(i32, sbx) + @as(i32, InstructionFormat.OFFSET_sBx);
        const bx = @as(u17, @intCast(offset_val));
        return initABx(opcode, a, bx);
    }

    // iAx: [op:7][ax:25]
    pub fn initAx(opcode: OpCode, ax: u25) Instruction {
        const inst_value = @as(u32, @intFromEnum(opcode)) |
            (@as(u32, ax) << InstructionFormat.POS_Ax);
        return @bitCast(inst_value);
    }

    // isJ: [op:7][sj:25] (25-bit signed jump)
    pub fn initsJ(opcode: OpCode, sj: i25) Instruction {
        const offset_val = @as(i26, sj) + @as(i26, InstructionFormat.OFFSET_sJ);
        const j = @as(u25, @intCast(offset_val));
        const inst_value = @as(u32, @intFromEnum(opcode)) |
            (@as(u32, j) << InstructionFormat.POS_sJ);
        return @bitCast(inst_value);
    }

    pub inline fn getOpCode(self: Instruction) OpCode {
        return @enumFromInt(self.op);
    }

    pub inline fn getA(self: Instruction) u8 {
        return self.a;
    }

    pub inline fn getB(self: Instruction) u8 {
        return self.b;
    }

    pub inline fn getC(self: Instruction) u8 {
        return self.c;
    }

    pub inline fn getk(self: Instruction) bool {
        return self.k;
    }

    pub inline fn getBx(self: Instruction) u17 {
        const raw: u32 = @bitCast(self);
        return @intCast((raw >> InstructionFormat.POS_Bx) & InstructionFormat.MAXARG_Bx);
    }

    pub inline fn getSBx(self: Instruction) i17 {
        const bx_val = @as(i32, self.getBx());
        return @as(i17, @intCast(bx_val - @as(i32, InstructionFormat.OFFSET_sBx)));
    }

    pub inline fn getAx(self: Instruction) u25 {
        const raw: u32 = @bitCast(self);
        return @intCast((raw >> InstructionFormat.POS_Ax) & InstructionFormat.MAXARG_Ax);
    }

    pub inline fn getsJ(self: Instruction) i25 {
        const raw: u32 = @bitCast(self);
        const j = (raw >> InstructionFormat.POS_sJ) & InstructionFormat.MAXARG_sJ;
        return @as(i25, @intCast(@as(i26, @intCast(j)) - @as(i26, InstructionFormat.OFFSET_sJ)));
    }
};
