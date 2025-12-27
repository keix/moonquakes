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

        // Check if offset fits in i25 range (-16,777,216 to 16,777,215)
        const max_i25 = (1 << 24) - 1;
        const min_i25 = -(1 << 24);

        if (offset_i32 < min_i25 or offset_i32 > max_i25) {
            std.debug.panic("Jump offset out of range: {} (from {} to {})\n", .{ offset_i32, addr, target });
        }

        const offset: i25 = @intCast(offset_i32);
        self.code.items[addr] = Instruction.initsJ(.JMP, offset);
    }

    pub fn emitFORPREP(self: *ProtoBuilder, base_reg: u8, jump_target: i17) !void {
        const instr = Instruction.initAsBx(.FORPREP, base_reg, jump_target);
        try self.code.append(instr);
    }

    pub fn emitFORLOOP(self: *ProtoBuilder, base_reg: u8, jump_target: i17) !void {
        const instr = Instruction.initAsBx(.FORLOOP, base_reg, jump_target);
        try self.code.append(instr);
    }

    pub fn emitPatchableFORPREP(self: *ProtoBuilder, base_reg: u8) !u32 {
        const addr = self.code.items.len;
        const instr = Instruction.initAsBx(.FORPREP, base_reg, 0); // placeholder
        try self.code.append(instr);
        return @intCast(addr);
    }

    pub fn emitPatchableFORLOOP(self: *ProtoBuilder, base_reg: u8) !u32 {
        const addr = self.code.items.len;
        const instr = Instruction.initAsBx(.FORLOOP, base_reg, 0); // placeholder
        try self.code.append(instr);
        return @intCast(addr);
    }

    pub fn patchFORInstr(self: *ProtoBuilder, addr: u32, target: u32) void {
        const offset_i32 = @as(i32, @intCast(target)) - @as(i32, @intCast(addr)) - 1;
        const offset: i17 = @intCast(offset_i32);

        // Get the existing instruction to preserve opcode and A field
        const existing = self.code.items[addr];
        const new_instr = Instruction.initAsBx(existing.getOpCode(), existing.getA(), offset);
        self.code.items[addr] = new_instr;
    }

    pub fn emitMOVE(self: *ProtoBuilder, dst: u8, src: u8) !void {
        const instr = Instruction.initABC(.MOVE, dst, src, 0);
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

    pub fn addConstString(self: *ProtoBuilder, lexeme: []const u8) !u32 {
        // Store the actual string value
        const const_value = TValue{ .string = lexeme };
        try self.constants.append(const_value);
        return @intCast(self.constants.items.len - 1);
    }

    pub fn addNativeFunc(self: *ProtoBuilder, func_id: u8) !u32 {
        const const_value = TValue{ .native_func = func_id };
        try self.constants.append(const_value);
        return @intCast(self.constants.items.len - 1);
    }

    pub fn emitCall(self: *ProtoBuilder, func_reg: u8, nargs: u8, nresults: u8) !void {
        const instr = Instruction.initABC(.CALL, func_reg, nargs + 1, nresults + 1);
        try self.code.append(instr);
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
                } else if (std.mem.eql(u8, self.current.lexeme, "for")) {
                    try self.parseFor();
                } else {
                    return error.UnsupportedStatement;
                }
            } else if (self.current.kind == .Identifier) {
                // Handle function calls like print(...)
                if (std.mem.eql(u8, self.current.lexeme, "print")) {
                    try self.parseFunctionCall();
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
        } else if (self.current.kind == .String) {
            const reg = self.proto.allocReg();
            // Remove quotes from string literal
            const str_content = self.current.lexeme[1 .. self.current.lexeme.len - 1];
            const k = try self.proto.addConstString(str_content);
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
        } else if (self.current.kind == .Identifier) {
            // For now, only support loop variable 'i' which is at base+3
            if (std.mem.eql(u8, self.current.lexeme, "i")) {
                const reg = self.proto.allocReg();
                // Loop variable is stored at base+3, copy to new register
                try self.proto.emitMOVE(reg, 3); // base+3 = loop variable
                self.advance();
                return reg;
            } else {
                return error.UnsupportedIdentifier;
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

        // Always emit jump to skip else branch after then branch
        const else_jmp = try self.proto.emitPatchableJMP();

        // Handle elseif/else
        var current_false_jmp = false_jmp;
        var else_jumps = std.ArrayList(u32).init(self.proto.allocator);
        defer else_jumps.deinit();

        // Handle elseif chains
        while (self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "elseif")) {
            self.advance(); // consume 'elseif'

            // Patch previous false jump to here (start of elseif)
            const elseif_start = @as(u32, @intCast(self.proto.code.items.len));
            self.proto.patchJMP(current_false_jmp, elseif_start);

            // Parse elseif condition
            const elseif_condition_reg = try self.parseExpr();

            // Expect 'then'
            if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "then"))) {
                return error.ExpectedThen;
            }
            self.advance(); // consume 'then'

            // TEST elseif condition, skip if false
            try self.proto.emitTEST(elseif_condition_reg, false);
            current_false_jmp = try self.proto.emitPatchableJMP();

            // Parse elseif body
            try self.parseStatements();

            // Jump over remaining elseif/else when this condition was true
            const jump_to_end = try self.proto.emitPatchableJMP();
            try else_jumps.append(jump_to_end);
        }

        // Handle final else if present
        var has_else = false;
        if (self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "else")) {
            self.advance(); // consume 'else'
            has_else = true;

            // Patch false jump to here (start of else branch)
            const else_start = @as(u32, @intCast(self.proto.code.items.len));
            self.proto.patchJMP(current_false_jmp, else_start);

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

        // Patch the jump-to-end from then branch
        self.proto.patchJMP(else_jmp, end_addr);

        // Patch all elseif jumps to end
        for (else_jumps.items) |jump| {
            self.proto.patchJMP(jump, end_addr);
        }

        // If no else branch, patch the false jump to end
        if (!has_else) {
            self.proto.patchJMP(current_false_jmp, end_addr);
        }
    }

    fn parseFor(self: *Parser) !void {
        self.advance(); // consume 'for'

        // Expect variable name (for now, we'll ignore it and use a fixed register)
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        self.advance(); // consume identifier

        // Expect '='
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "="))) {
            return error.ExpectedEquals;
        }
        self.advance(); // consume '='

        // Parse initial value
        const init_reg = try self.parseExpr();

        // Expect ','
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ","))) {
            return error.ExpectedComma;
        }
        self.advance(); // consume ','

        // Parse limit value
        const limit_reg = try self.parseExpr();

        // Check for optional step (for now, default to 1)
        var step_reg: u8 = 0;
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
            self.advance(); // consume ','
            step_reg = try self.parseExpr();
        } else {
            // Default step = 1
            step_reg = self.proto.allocReg();
            const const_idx = try self.proto.addConstNumber("1");
            try self.proto.emitLoadK(step_reg, const_idx);
        }

        // Expect 'do'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "do"))) {
            return error.ExpectedDo;
        }
        self.advance(); // consume 'do'

        // Set up for loop registers: base, base+1=limit, base+2=step
        const base_reg = init_reg;
        // Move limit and step to correct positions if needed
        if (limit_reg != base_reg + 1) {
            try self.proto.emitMOVE(base_reg + 1, limit_reg);
        }
        if (step_reg != base_reg + 2) {
            try self.proto.emitMOVE(base_reg + 2, step_reg);
        }

        // FORPREP: decrement counter by step, then jump to FORLOOP
        const forprep_addr = try self.proto.emitPatchableFORPREP(base_reg);
        const loop_start = @as(u32, @intCast(self.proto.code.items.len));

        // Parse loop body
        try self.parseStatements();

        // Expect 'end'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "end"))) {
            return error.ExpectedEnd;
        }
        self.advance(); // consume 'end'

        // FORLOOP: increment and check, jump back if continuing
        const forloop_addr = try self.proto.emitPatchableFORLOOP(base_reg);

        // Patch FORPREP to jump to FORLOOP if initial condition fails
        self.proto.patchFORInstr(forprep_addr, forloop_addr);

        // Patch FORLOOP to jump back to loop start
        self.proto.patchFORInstr(forloop_addr, loop_start);
    }

    fn parseStatements(self: *Parser) (std.mem.Allocator.Error || error{ ExpectedThen, ExpectedEnd, ExpectedIdentifier, ExpectedEquals, ExpectedComma, ExpectedDo, UnsupportedStatement, ExpectedExpression, UnsupportedOperator, InvalidNumber, UnsupportedIdentifier, ExpectedLeftParen, ExpectedRightParen, UnsupportedFunction })!void {
        // Support return statements and nested if/for inside blocks
        while (self.current.kind != .Eof and
            !(self.current.kind == .Keyword and
                (std.mem.eql(u8, self.current.lexeme, "else") or
                    std.mem.eql(u8, self.current.lexeme, "elseif") or
                    std.mem.eql(u8, self.current.lexeme, "end"))))
        {
            if (self.current.kind == .Keyword) {
                if (std.mem.eql(u8, self.current.lexeme, "return")) {
                    try self.parseReturn();
                    return; // return ends the statement block
                } else if (std.mem.eql(u8, self.current.lexeme, "if")) {
                    try self.parseIf();
                } else if (std.mem.eql(u8, self.current.lexeme, "for")) {
                    try self.parseFor();
                } else {
                    return error.UnsupportedStatement;
                }
            } else if (self.current.kind == .Identifier) {
                // Handle function calls like print(...)
                if (std.mem.eql(u8, self.current.lexeme, "print")) {
                    try self.parseFunctionCall();
                } else {
                    return error.UnsupportedStatement;
                }
            } else {
                return error.UnsupportedStatement;
            }
        }
    }

    fn parseFunctionCall(self: *Parser) !void {
        // Currently only support "print" function
        if (!std.mem.eql(u8, self.current.lexeme, "print")) {
            return error.UnsupportedFunction;
        }

        self.advance(); // consume function name

        // Expect '('
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Load print function constant
        // Skip past potential for loop registers (0-3) to avoid conflicts
        while (self.proto.next_reg <= 4) {
            _ = self.proto.allocReg();
        }
        const func_reg = self.proto.allocReg();
        const print_const_idx = try self.proto.addNativeFunc(0); // print is func_id 0
        try self.proto.emitLoadK(func_reg, print_const_idx);

        // Parse arguments
        var arg_count: u8 = 0;
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            // Parse first argument
            const arg_reg = try self.parseExpr();
            // Move argument to correct position (func_reg + 1)
            if (arg_reg != func_reg + 1) {
                try self.proto.emitMOVE(func_reg + 1, arg_reg);
            }
            arg_count = 1;

            // Parse additional arguments (if needed in future)
            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
                self.advance(); // consume ','
                const next_arg = try self.parseExpr();
                arg_count += 1;
                // Move to correct position
                if (next_arg != func_reg + arg_count) {
                    try self.proto.emitMOVE(func_reg + arg_count, next_arg);
                }
            }
        }

        // Expect ')'
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            return error.ExpectedRightParen;
        }
        self.advance(); // consume ')'

        // Emit CALL instruction (0 results for print)
        try self.proto.emitCall(func_reg, arg_count, 0);
    }

    fn parseExpr(self: *Parser) !u8 {
        return self.parseCompare();
    }
};
