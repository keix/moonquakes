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
        if (self.current.kind == .Keyword and
            std.mem.eql(u8, self.current.lexeme, "return"))
        {
            try self.parseReturn();
            return;
        }

        // Explicitly reject unsupported statements
        if (self.current.kind == .Eof) {
            return; // Empty chunk is OK
        }

        return error.UnsupportedStatement;
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
        }

        return error.ExpectedExpression;
    }

    fn parseMul(self: *Parser) !u8 {
        var left = try self.parsePrimary();

        while (self.current.kind == .Symbol and
            (std.mem.eql(u8, self.current.lexeme, "*") or
                std.mem.eql(u8, self.current.lexeme, "/")))
        {
            const op = self.current.lexeme;
            self.advance(); // consume operator
            const right = try self.parsePrimary();

            const dst = self.proto.allocReg();
            if (std.mem.eql(u8, op, "*")) {
                try self.proto.emitMul(dst, left, right);
            } else {
                // TODO: implement division
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
            } else {
                // TODO: implement subtraction
                return error.UnsupportedOperator;
            }
            left = dst;
        }

        return left;
    }

    fn parseExpr(self: *Parser) !u8 {
        return self.parseAdd();
    }
};
