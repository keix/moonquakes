const std = @import("std");
const lexer = @import("lexer.zig");
const Lexer = lexer.Lexer;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const TValue = @import("../core/value.zig").TValue;
const Proto = @import("../vm/func.zig").Proto;
const opcodes = @import("opcodes.zig");
const Instruction = opcodes.Instruction;

pub const ProtoBuilder = struct {
    code: std.ArrayList(Instruction),
    constants: std.ArrayList(TValue),
    maxstacksize: u8,
    next_reg: u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ProtoBuilder {
        return .{
            .code = std.ArrayList(Instruction).init(allocator),
            .constants = std.ArrayList(TValue).init(allocator),
            .maxstacksize = 0,
            .next_reg = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProtoBuilder) void {
        self.code.deinit();
        self.constants.deinit();
    }

    pub fn emit(self: *ProtoBuilder, op: opcodes.OpCode, a: u8, b: u8, c: u8) !void {
        const instr = Instruction.initABC(op, a, b, c);
        try self.code.append(instr);
    }

    pub fn emitLoadK(self: *ProtoBuilder, reg: u8, const_idx: u32) !void {
        const instr = Instruction.initABx(.LOADK, reg, @intCast(const_idx));
        try self.code.append(instr);
        self.updateMaxStack(reg + 1);
    }

    pub fn allocReg(self: *ProtoBuilder) u8 {
        const reg = self.next_reg;
        self.next_reg += 1;
        self.updateMaxStack(self.next_reg);
        return reg;
    }

    pub fn emitAdd(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.ADD, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitMul(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.MUL, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitSub(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.SUB, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitDiv(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.DIV, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitMod(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.MOD, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitEQ(self: *ProtoBuilder, left: u8, right: u8, negate: u8) !void {
        const instr = Instruction.initABC(.EQ, negate, left, right);
        try self.code.append(instr);
    }

    pub fn emitLOADBOOL(self: *ProtoBuilder, dst: u8, value: bool, skip: bool) !void {
        const b: u8 = if (value) 1 else 0;
        const c: u8 = if (skip) 1 else 0;
        const instr = Instruction.initABC(.LOADBOOL, dst, b, c);
        try self.code.append(instr);
    }

    pub fn emitTEST(self: *ProtoBuilder, reg: u8, condition: bool) !void {
        const k: u8 = if (condition) 1 else 0;
        const instr = Instruction.initABC(.TEST, reg, 0, k);
        try self.code.append(instr);
    }

    pub fn emitJMP(self: *ProtoBuilder, offset: i25) !void {
        const instr = Instruction.initsJ(.JMP, offset);
        try self.code.append(instr);
    }

    pub fn emitPatchableJMP(self: *ProtoBuilder) !u32 {
        const addr = self.code.items.len;
        const instr = Instruction.initsJ(.JMP, 0); // placeholder
        try self.code.append(instr);
        return @intCast(addr);
    }

    pub fn patchJMP(self: *ProtoBuilder, addr: u32, target: u32) void {
        const offset_i32 = @as(i32, @intCast(target)) - @as(i32, @intCast(addr)) - 1;
        const offset: i25 = @intCast(offset_i32); // truncate to i25
        self.code.items[addr] = Instruction.initsJ(.JMP, offset);
    }

    pub fn emitReturn(self: *ProtoBuilder, reg: u8) !void {
        const instr = Instruction.initABC(.RETURN, reg, 2, 0);
        try self.code.append(instr);
    }

    pub fn addConstNumber(self: *ProtoBuilder, lexeme: []const u8) !u32 {
        const value = std.fmt.parseInt(i64, lexeme, 10) catch return error.InvalidNumber;
        const const_value = TValue{ .integer = value };
        try self.constants.append(const_value);
        return @intCast(self.constants.items.len - 1);
    }

    fn updateMaxStack(self: *ProtoBuilder, stack_size: u8) void {
        if (stack_size > self.maxstacksize) {
            self.maxstacksize = stack_size;
        }
    }

    pub fn toProto(self: *ProtoBuilder, allocator: std.mem.Allocator) !Proto {
        const code_slice = try allocator.dupe(Instruction, self.code.items);
        const constants_slice = try allocator.dupe(TValue, self.constants.items);

        return Proto{
            .code = code_slice,
            .k = constants_slice,
            .numparams = 0,
            .is_vararg = false,
            .maxstacksize = self.maxstacksize,
        };
    }
};

pub const Parser = struct {
    lexer: *Lexer,
    current: Token,
    proto: *ProtoBuilder,

    pub fn init(lx: *Lexer, proto: *ProtoBuilder) Parser {
        var p = Parser{
            .lexer = lx,
            .proto = proto,
            .current = undefined,
        };
        p.advance();
        return p;
    }

    fn advance(self: *Parser) void {
        self.current = self.lexer.nextToken();
    }

    pub fn parseChunk(self: *Parser) !void {
        while (self.current.kind != .Eof) {
            if (self.current.kind == .Keyword) {
                if (std.mem.eql(u8, self.current.lexeme, "return")) {
                    try self.parseReturn();
                    return; // return ends the chunk
                } else if (std.mem.eql(u8, self.current.lexeme, "if")) {
                    try self.parseIf();
                } else {
                    return error.UnsupportedStatement;
                }
            } else {
                return error.UnsupportedStatement;
            }
        }
    }

    fn parseReturn(self: *Parser) !void {
        self.advance(); // consume 'return'
        const reg = try self.parseExpr();
        try self.proto.emitReturn(reg);
    }

    fn parsePrimary(self: *Parser) !u8 {
        if (self.current.kind == .Number) {
            const reg = self.proto.allocReg();
            const k = try self.proto.addConstNumber(self.current.lexeme);
            try self.proto.emitLoadK(reg, k);
            self.advance();
            return reg;
        } else if (self.current.kind == .Keyword) {
            if (std.mem.eql(u8, self.current.lexeme, "true") or
                std.mem.eql(u8, self.current.lexeme, "false"))
            {
                const is_true = std.mem.eql(u8, self.current.lexeme, "true");
                const reg = self.proto.allocReg();
                try self.proto.emitLOADBOOL(reg, is_true, false);
                self.advance();
                return reg;
            }
        }

        return error.ExpectedExpression;
    }

    fn parseMul(self: *Parser) !u8 {
        var left = try self.parsePrimary();

        while (self.current.kind == .Symbol and
            (std.mem.eql(u8, self.current.lexeme, "*") or
                std.mem.eql(u8, self.current.lexeme, "/") or
                std.mem.eql(u8, self.current.lexeme, "%")))
        {
            const op = self.current.lexeme;
            self.advance(); // consume operator
            const right = try self.parsePrimary();

            const dst = self.proto.allocReg();
            if (std.mem.eql(u8, op, "*")) {
                try self.proto.emitMul(dst, left, right);
            } else if (std.mem.eql(u8, op, "/")) {
                try self.proto.emitDiv(dst, left, right);
            } else if (std.mem.eql(u8, op, "%")) {
                try self.proto.emitMod(dst, left, right);
            } else {
                return error.UnsupportedOperator;
            }
            left = dst;
        }

        return left;
    }

    fn parseAdd(self: *Parser) !u8 {
        var left = try self.parseMul();

        while (self.current.kind == .Symbol and
            (std.mem.eql(u8, self.current.lexeme, "+") or
                std.mem.eql(u8, self.current.lexeme, "-")))
        {
            const op = self.current.lexeme;
            self.advance(); // consume operator
            const right = try self.parseMul();

            const dst = self.proto.allocReg();
            if (std.mem.eql(u8, op, "+")) {
                try self.proto.emitAdd(dst, left, right);
            } else if (std.mem.eql(u8, op, "-")) {
                try self.proto.emitSub(dst, left, right);
            } else {
                return error.UnsupportedOperator;
            }
            left = dst;
        }

        return left;
    }

    fn parseCompare(self: *Parser) !u8 {
        var left = try self.parseAdd();

        while (self.current.kind == .Symbol and
            (std.mem.eql(u8, self.current.lexeme, "==") or
                std.mem.eql(u8, self.current.lexeme, "!=")))
        {
            const op = self.current.lexeme;
            self.advance(); // consume operator
            const right = try self.parseAdd();

            const dst = self.proto.allocReg();
            if (std.mem.eql(u8, op, "==")) {
                // For ==: if equal then set true, else set false
                try self.proto.emitEQ(left, right, 1); // skip if NOT equal (negate=1)
                try self.proto.emitLOADBOOL(dst, true, true); // equal: true, skip next
                try self.proto.emitLOADBOOL(dst, false, false); // not equal: false
            } else if (std.mem.eql(u8, op, "!=")) {
                // For !=: if not equal then set true, else set false
                try self.proto.emitEQ(left, right, 0); // skip if equal (negate=0)
                try self.proto.emitLOADBOOL(dst, true, true); // not equal: true, skip next
                try self.proto.emitLOADBOOL(dst, false, false); // equal: false
            } else {
                return error.UnsupportedOperator;
            }
            left = dst;
        }

        return left;
    }

    fn parseIf(self: *Parser) !void {
        self.advance(); // consume 'if'

        // Parse condition
        const condition_reg = try self.parseExpr();

        // Expect 'then'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "then"))) {
            return error.ExpectedThen;
        }
        self.advance(); // consume 'then'

        // TEST condition, skip if false
        try self.proto.emitTEST(condition_reg, false);
        const false_jmp = try self.proto.emitPatchableJMP();

        // Parse then branch
        try self.parseStatements();

        // Check for else
        var else_jmp: ?u32 = null;
        if (self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "else")) {
            self.advance(); // consume 'else'
            // Jump over else branch when then branch executes
            else_jmp = try self.proto.emitPatchableJMP();

            // Patch false jump to here (start of else branch)
            const else_start = @as(u32, @intCast(self.proto.code.items.len));
            self.proto.patchJMP(false_jmp, else_start);

            // Parse else branch
            try self.parseStatements();
        }

        // Expect 'end'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "end"))) {
            return error.ExpectedEnd;
        }
        self.advance(); // consume 'end'

        // Patch jumps
        const end_addr = @as(u32, @intCast(self.proto.code.items.len));
        if (else_jmp) |jmp| {
            self.proto.patchJMP(jmp, end_addr);
        } else {
            self.proto.patchJMP(false_jmp, end_addr);
        }
    }

    fn parseStatements(self: *Parser) !void {
        // For now, only support return statements inside if
        while (self.current.kind != .Eof and
            !(self.current.kind == .Keyword and
                (std.mem.eql(u8, self.current.lexeme, "else") or
                    std.mem.eql(u8, self.current.lexeme, "end"))))
        {
            if (self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "return")) {
                try self.parseReturn();
                return; // return ends the statement block
            } else {
                return error.UnsupportedStatement;
            }
        }
    }

    fn parseExpr(self: *Parser) !u8 {
        return self.parseCompare();
    }
};
