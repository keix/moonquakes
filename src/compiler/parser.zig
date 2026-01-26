const std = @import("std");
const lexer = @import("lexer.zig");
const Lexer = lexer.Lexer;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("proto.zig").Proto;
const NativeFn = @import("../runtime/native.zig").NativeFn;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const opcodes = @import("opcodes.zig");
const Instruction = opcodes.Instruction;
const GC = @import("../runtime/gc/gc.zig").GC;

/// parser.zig
///
/// This file implements the Lua 5.4 grammar and emits executable Proto objects.
///
/// Design notes:
/// - This parser prioritizes semantic correctness and specification coverage
///   over minimality or elegance.
/// - Some parts may appear imperative or verbose; this is intentional.
///   At this stage, clarity of semantics is more important than structure.
///
/// Important:
/// - The parser is expected to evolve once the full instruction set (mnemonics)
///   and runtime semantics are finalized.
/// - Several dispatch patterns and hard-coded paths are temporary and will be
///   refactored after the grammar is fully implemented and frozen.
///
/// Rationale:
/// - The parser structure cannot be finalized before all statements and expressions
///   are implemented.
/// - Premature refactoring here would obscure semantics and increase churn.
///
/// Once all constructs are in place, this file will be revisited to:
/// - reduce duplication
/// - unify statement and expression dispatch
/// - improve readability without changing semantics
///
/// Until then, correctness comes first.
///
const ParseError = error{
    OutOfMemory,
    InvalidNumber,
    UnsupportedIdentifier,
    ExpectedExpression,
    UnsupportedOperator,
    ExpectedThen,
    ExpectedEnd,
    ExpectedIdentifier,
    ExpectedEquals,
    ExpectedComma,
    ExpectedDo,
    UnsupportedStatement,
    ExpectedLeftParen,
    ExpectedRightParen,
    UnsupportedFunction,
    UnsupportedTableField,
    ExpectedFieldSeparator,
    ExpectedCloseBrace,
};

const StatementError = std.mem.Allocator.Error || ParseError;

// Simple function storage for minimal implementation
const FunctionEntry = struct {
    name: []const u8,
    proto: *Proto,
};

// Variable entry for scope management
const VariableEntry = struct {
    name: []const u8,
    reg: u8,
};

/// Number of registers used by numeric for loop (idx, limit, step, user_var)
pub const NUMERIC_FOR_REGS: u8 = 4;

/// Marker for scope boundaries (used with enterScope/leaveScope)
const ScopeMark = struct {
    var_len: usize, // variables list rollback point
    locals_top: u8, // register watermark for this scope
};

pub const ProtoBuilder = struct {
    code: std.ArrayList(Instruction),
    constants: std.ArrayList(TValue),
    protos: std.ArrayList(*const Proto), // Nested function prototypes (for CLOSURE)
    maxstacksize: u8,
    next_reg: u8, // Next available register (for temps)
    locals_top: u8, // Register watermark: locals occupy [0, locals_top)
    allocator: std.mem.Allocator,
    gc: *GC, // For allocating GC-managed objects (strings, etc.)
    functions: std.ArrayList(FunctionEntry),
    variables: std.ArrayList(VariableEntry),
    scope_starts: std.ArrayList(ScopeMark), // Stack of scope boundaries
    parent: ?*ProtoBuilder, // For function scope hierarchy

    pub fn init(allocator: std.mem.Allocator, gc: *GC) ProtoBuilder {
        return .{
            .code = std.ArrayList(Instruction).init(allocator),
            .constants = std.ArrayList(TValue).init(allocator),
            .protos = std.ArrayList(*const Proto).init(allocator),
            .maxstacksize = 0,
            .next_reg = 0,
            .locals_top = 0,
            .allocator = allocator,
            .gc = gc,
            .functions = std.ArrayList(FunctionEntry).init(allocator),
            .variables = std.ArrayList(VariableEntry).init(allocator),
            .scope_starts = std.ArrayList(ScopeMark).init(allocator),
            .parent = null,
        };
    }

    pub fn initWithParent(allocator: std.mem.Allocator, parent: *ProtoBuilder) ProtoBuilder {
        return .{
            .code = std.ArrayList(Instruction).init(allocator),
            .constants = std.ArrayList(TValue).init(allocator),
            .protos = std.ArrayList(*const Proto).init(allocator),
            .maxstacksize = 0,
            .next_reg = 0,
            .locals_top = 0,
            .allocator = allocator,
            .gc = parent.gc, // Inherit GC from parent
            .functions = std.ArrayList(FunctionEntry).init(allocator),
            .variables = std.ArrayList(VariableEntry).init(allocator),
            .scope_starts = std.ArrayList(ScopeMark).init(allocator),
            .parent = parent,
        };
    }

    pub fn deinit(self: *ProtoBuilder) void {
        // Free function protos and their allocated arrays
        // All slices are allocator-owned (even when len=0), so always free
        for (self.functions.items) |entry| {
            self.allocator.free(entry.proto.code);
            self.allocator.free(entry.proto.k);
            self.allocator.free(entry.proto.protos);
            self.allocator.destroy(entry.proto);
        }

        self.code.deinit();
        self.constants.deinit();
        self.protos.deinit();
        self.functions.deinit();
        self.variables.deinit();
        self.scope_starts.deinit();
    }

    /// Allocate a temporary register (for expression evaluation)
    /// Temps are released by resetTemps()
    pub fn allocTemp(self: *ProtoBuilder) u8 {
        const reg = self.next_reg;
        self.next_reg += 1;
        self.updateMaxStack(self.next_reg);
        return reg;
    }

    /// Allocate a register for a local variable (register only, no name binding)
    /// Use addVariable() to bind a name after the initializer is evaluated
    /// Locals persist until leaveScope() is called
    pub fn allocLocalReg(self: *ProtoBuilder) u8 {
        const reg = self.locals_top;
        self.locals_top += 1;
        self.next_reg = @max(self.next_reg, self.locals_top);
        self.updateMaxStack(self.next_reg);
        return reg;
    }

    /// Enter a new scope (for blocks, functions, loops)
    pub fn enterScope(self: *ProtoBuilder) !void {
        try self.scope_starts.append(.{
            .var_len = self.variables.items.len,
            .locals_top = self.locals_top,
        });
    }

    /// Leave current scope, releasing all locals declared within
    pub fn leaveScope(self: *ProtoBuilder) void {
        const mark = self.scope_starts.pop().?;
        self.variables.shrinkRetainingCapacity(mark.var_len);
        self.locals_top = mark.locals_top;
        self.next_reg = self.locals_top;
    }

    /// Marker for temporary register usage
    pub const TempMark = struct {
        saved: u8,
    };

    /// Mark current register position for later reset
    /// Call before compiling expressions that use temporary registers
    pub fn markTemps(self: *ProtoBuilder) TempMark {
        return .{ .saved = self.next_reg };
    }

    /// Reset register allocation to a previously marked position
    /// Releases temporary registers used since the mark
    /// Note: Never resets below locals_top to protect scoped locals
    pub fn resetTemps(self: *ProtoBuilder, mark: TempMark) void {
        self.next_reg = @max(mark.saved, self.locals_top);
    }

    // emit functions grouped together
    pub fn emit(self: *ProtoBuilder, op: opcodes.OpCode, a: u8, b: u8, c: u8) !void {
        const instr = Instruction.initABC(op, a, b, c);
        try self.code.append(instr);
    }

    pub fn emitAdd(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.ADD, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitCall(self: *ProtoBuilder, func_reg: u8, nargs: u8, nresults: u8) !void {
        const instr = Instruction.initABC(.CALL, func_reg, nargs + 1, nresults + 1);
        try self.code.append(instr);
    }

    pub fn emitDiv(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.DIV, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitEQ(self: *ProtoBuilder, left: u8, right: u8, negate: u8) !void {
        const instr = Instruction.initABC(.EQ, negate, left, right);
        try self.code.append(instr);
    }

    pub fn emitLT(self: *ProtoBuilder, left: u8, right: u8, negate: u8) !void {
        const instr = Instruction.initABC(.LT, negate, left, right);
        try self.code.append(instr);
    }

    pub fn emitLE(self: *ProtoBuilder, left: u8, right: u8, negate: u8) !void {
        const instr = Instruction.initABC(.LE, negate, left, right);
        try self.code.append(instr);
    }

    pub fn emitFORLOOP(self: *ProtoBuilder, base_reg: u8, jump_target: i17) !void {
        const instr = Instruction.initAsBx(.FORLOOP, base_reg, jump_target);
        try self.code.append(instr);
    }

    pub fn emitFORPREP(self: *ProtoBuilder, base_reg: u8, jump_target: i17) !void {
        const instr = Instruction.initAsBx(.FORPREP, base_reg, jump_target);
        try self.code.append(instr);
    }

    pub fn emitGETTABLE(self: *ProtoBuilder, dst: u8, table: u8, key: u8) !void {
        const instr = Instruction.initABC(.GETTABLE, dst, table, key);
        try self.code.append(instr);
    }

    pub fn emitGETTABUP(self: *ProtoBuilder, dst: u8, upval: u8, key_const: u32) !void {
        const instr = Instruction.initABC(.GETTABUP, dst, upval, @intCast(key_const));
        try self.code.append(instr);
    }

    /// Emit SETTABUP instruction: UpValue[A][K[B]] := R[C]
    pub fn emitSETTABUP(self: *ProtoBuilder, upval: u8, key_const: u32, src: u8) !void {
        const instr = Instruction.initABC(.SETTABUP, upval, @intCast(key_const), src);
        try self.code.append(instr);
    }

    pub fn emitJMP(self: *ProtoBuilder, offset: i25) !void {
        const instr = Instruction.initsJ(.JMP, offset);
        try self.code.append(instr);
    }

    pub fn emitLoadK(self: *ProtoBuilder, reg: u8, const_idx: u32) !void {
        const instr = Instruction.initABx(.LOADK, reg, @intCast(const_idx));
        try self.code.append(instr);
        self.updateMaxStack(reg + 1);
    }

    /// Emit CLOSURE instruction: R[A] := closure(KPROTO[Bx])
    pub fn emitClosure(self: *ProtoBuilder, reg: u8, proto_idx: u32) !void {
        const instr = Instruction.initABx(.CLOSURE, reg, @intCast(proto_idx));
        try self.code.append(instr);
        self.updateMaxStack(reg + 1);
    }

    pub fn emitLOADBOOL(self: *ProtoBuilder, dst: u8, value: bool, skip: bool) !void {
        // Use Lua 5.4 standard opcodes instead of LOADBOOL
        if (value and !skip) {
            const instr = Instruction.initABC(.LOADTRUE, dst, 0, 0);
            try self.code.append(instr);
        } else if (!value and !skip) {
            const instr = Instruction.initABC(.LOADFALSE, dst, 0, 0);
            try self.code.append(instr);
        } else if (!value and skip) {
            const instr = Instruction.initABC(.LFALSESKIP, dst, 0, 0);
            try self.code.append(instr);
        } else {
            // value=true, skip=true: Load true and skip next instruction
            const instr = Instruction.initABC(.LOADTRUE, dst, 0, 0);
            try self.code.append(instr);
            const skip_instr = Instruction.initsJ(.JMP, 1); // Skip exactly 1 instruction
            try self.code.append(skip_instr);
        }
    }

    pub fn emitLOADNIL(self: *ProtoBuilder, dst: u8, count: u8) !void {
        const instr = Instruction.initABC(.LOADNIL, dst, count - 1, 0);
        try self.code.append(instr);
        self.updateMaxStack(dst + count);
    }

    pub fn emitMod(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.MOD, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitMOVE(self: *ProtoBuilder, dst: u8, src: u8) !void {
        const instr = Instruction.initABC(.MOVE, dst, src, 0);
        try self.code.append(instr);
    }

    /// Emit NEWTABLE instruction: R[A] := {}
    pub fn emitNEWTABLE(self: *ProtoBuilder, dst: u8) !void {
        const instr = Instruction.initABC(.NEWTABLE, dst, 0, 0);
        try self.code.append(instr);
        self.updateMaxStack(dst + 1);
    }

    /// Emit SETFIELD instruction: R[A][K[B]] := R[C]
    pub fn emitSETFIELD(self: *ProtoBuilder, table: u8, key_const: u32, src: u8) !void {
        const instr = Instruction.initABC(.SETFIELD, table, @intCast(key_const), src);
        try self.code.append(instr);
    }

    /// Emit GETFIELD instruction: R[A] := R[B][K[C]]
    pub fn emitGETFIELD(self: *ProtoBuilder, dst: u8, table: u8, key_const: u32) !void {
        const instr = Instruction.initABC(.GETFIELD, dst, table, @intCast(key_const));
        try self.code.append(instr);
        self.updateMaxStack(dst + 1);
    }

    pub fn emitMul(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.MUL, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitPatchableFORLOOP(self: *ProtoBuilder, base_reg: u8) !u32 {
        const addr = self.code.items.len;
        const instr = Instruction.initAsBx(.FORLOOP, base_reg, 0); // placeholder
        try self.code.append(instr);
        return @intCast(addr);
    }

    pub fn emitPatchableFORPREP(self: *ProtoBuilder, base_reg: u8) !u32 {
        const addr = self.code.items.len;
        const instr = Instruction.initAsBx(.FORPREP, base_reg, 0); // placeholder
        try self.code.append(instr);
        return @intCast(addr);
    }

    pub fn emitPatchableJMP(self: *ProtoBuilder) !u32 {
        const addr = self.code.items.len;
        const instr = Instruction.initsJ(.JMP, 0); // placeholder
        try self.code.append(instr);
        return @intCast(addr);
    }

    pub fn emitReturn(self: *ProtoBuilder, reg: u8) !void {
        const instr = Instruction.initABC(.RETURN, reg, 2, 0);
        try self.code.append(instr);
    }

    pub fn emitSub(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.SUB, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitTEST(self: *ProtoBuilder, reg: u8, condition: bool) !void {
        const k: u8 = if (condition) 1 else 0;
        const instr = Instruction.initABC(.TEST, reg, 0, k);
        try self.code.append(instr);
    }

    pub fn patchFORInstr(self: *ProtoBuilder, addr: u32, target: u32) void {
        const offset_i32 = @as(i32, @intCast(target)) - @as(i32, @intCast(addr)) - 1;
        const offset: i17 = @intCast(offset_i32);

        // Get the existing instruction to preserve opcode and A field
        const existing = self.code.items[addr];
        const new_instr = Instruction.initAsBx(existing.getOpCode(), existing.getA(), offset);
        self.code.items[addr] = new_instr;
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

    // add functions grouped together
    pub fn addConstNumber(self: *ProtoBuilder, lexeme: []const u8) !u32 {
        const value = std.fmt.parseInt(i64, lexeme, 10) catch return error.InvalidNumber;
        const const_value = TValue{ .integer = value };
        try self.constants.append(const_value);
        return @intCast(self.constants.items.len - 1);
    }

    pub fn addConstString(self: *ProtoBuilder, lexeme: []const u8) !u32 {
        // Allocate string through GC
        const str_obj = try self.gc.allocString(lexeme);
        const const_value = TValue{ .string = str_obj };
        try self.constants.append(const_value);
        return @intCast(self.constants.items.len - 1);
    }

    pub fn addNativeFunc(self: *ProtoBuilder, native_id: NativeFnId) !u32 {
        const native_fn = NativeFn.init(native_id);
        const nc = try self.gc.allocNativeClosure(native_fn);
        const const_value = TValue.fromNativeClosure(nc);
        try self.constants.append(const_value);
        return @intCast(self.constants.items.len - 1);
    }

    /// Add a nested function prototype for CLOSURE opcode
    pub fn addProto(self: *ProtoBuilder, proto: *const Proto) !u32 {
        try self.protos.append(proto);
        return @intCast(self.protos.items.len - 1);
    }

    fn updateMaxStack(self: *ProtoBuilder, stack_size: u8) void {
        if (stack_size > self.maxstacksize) {
            self.maxstacksize = stack_size;
        }
    }

    pub fn addFunction(self: *ProtoBuilder, name: []const u8, proto: *Proto) !void {
        try self.functions.append(FunctionEntry{
            .name = name,
            .proto = proto,
        });
    }

    pub fn findFunction(self: *ProtoBuilder, name: []const u8) ?*Proto {
        for (self.functions.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry.proto;
            }
        }
        // Search in parent scope if not found locally
        if (self.parent) |parent| {
            return parent.findFunction(name);
        }
        return null;
    }

    // Variable management methods
    pub fn addVariable(self: *ProtoBuilder, name: []const u8, reg: u8) !void {
        try self.variables.append(.{ .name = name, .reg = reg });
    }

    pub fn findVariable(self: *ProtoBuilder, name: []const u8) ?u8 {
        for (self.variables.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry.reg;
            }
        }
        return null;
    }

    pub fn toProto(self: *ProtoBuilder, allocator: std.mem.Allocator) !Proto {
        // Always allocate via allocator (even for len=0) to ensure ownership
        const code_slice = try allocator.dupe(Instruction, self.code.items);
        const constants_slice = try allocator.dupe(TValue, self.constants.items);
        const protos_slice = try allocator.dupe(*const Proto, self.protos.items);

        return Proto{
            .code = code_slice,
            .k = constants_slice,
            .protos = protos_slice,
            .numparams = 0,
            .is_vararg = false,
            .maxstacksize = self.maxstacksize,
        };
    }

    pub fn toProtoWithParams(self: *ProtoBuilder, allocator: std.mem.Allocator, num_params: u8) !Proto {
        // Always allocate via allocator (even for len=0) to ensure ownership
        const code_slice = try allocator.dupe(Instruction, self.code.items);
        const constants_slice = try allocator.dupe(TValue, self.constants.items);
        const protos_slice = try allocator.dupe(*const Proto, self.protos.items);

        return Proto{
            .code = code_slice,
            .k = constants_slice,
            .protos = protos_slice,
            .numparams = num_params,
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

    fn peek(self: *Parser) Token {
        // Save current state
        const saved_pos = self.lexer.pos;
        const saved_line = self.lexer.line;

        // Get next token
        const next_token = self.lexer.nextToken();

        // Restore state
        self.lexer.pos = saved_pos;
        self.lexer.line = saved_line;

        return next_token;
    }

    fn autoReturnNil(self: *Parser) ParseError!void {
        // Add nil constant and emit return nil
        const reg = self.proto.allocTemp();
        try self.proto.emitLOADNIL(reg, 1);
        try self.proto.emitReturn(reg);
    }

    // Parse functions grouped together
    pub fn parseChunk(self: *Parser) ParseError!void {
        while (self.current.kind != .Eof) {
            // Mark registers before each statement
            const stmt_mark = self.proto.markTemps();

            if (self.current.kind == .Keyword) {
                if (std.mem.eql(u8, self.current.lexeme, "return")) {
                    try self.parseReturn();
                    return; // return ends the chunk
                } else if (std.mem.eql(u8, self.current.lexeme, "if")) {
                    try self.parseIf();
                } else if (std.mem.eql(u8, self.current.lexeme, "for")) {
                    try self.parseFor();
                } else if (std.mem.eql(u8, self.current.lexeme, "function")) {
                    try self.parseFunctionDefinition();
                } else {
                    return error.UnsupportedStatement;
                }
            } else if (self.current.kind == .Identifier) {
                // Look ahead to see if it's a function call
                if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "(")) {
                    try self.parseGenericFunctionCall();
                } else if (std.mem.eql(u8, self.current.lexeme, "io")) {
                    try self.parseIoCall();
                } else {
                    return error.UnsupportedStatement;
                }
            } else {
                return error.UnsupportedStatement;
            }

            // Release statement temporaries - allows register reuse
            self.proto.resetTemps(stmt_mark);
        }

        // Auto-append return nil if no explicit return was encountered
        try self.autoReturnNil();
    }

    // Statement parsing
    fn parseReturn(self: *Parser) ParseError!void {
        self.advance(); // consume 'return'
        const reg = try self.parseExpr();
        try self.proto.emitReturn(reg);
    }

    // Expression parsing (precedence order: Primary -> Mul -> Add -> Compare)
    fn parsePrimary(self: *Parser) ParseError!u8 {
        // Table constructor: { field, field, ... }
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "{")) {
            return try self.parseTableConstructor();
        }

        if (self.current.kind == .Number) {
            const reg = self.proto.allocTemp();
            const k = try self.proto.addConstNumber(self.current.lexeme);
            try self.proto.emitLoadK(reg, k);
            self.advance();
            return reg;
        } else if (self.current.kind == .String) {
            const reg = self.proto.allocTemp();
            // Remove quotes from string literal
            const str_content = self.current.lexeme[1 .. self.current.lexeme.len - 1];
            const k = try self.proto.addConstString(str_content);
            try self.proto.emitLoadK(reg, k);
            self.advance();
            return reg;
        } else if (self.current.kind == .Keyword) {
            if (std.mem.eql(u8, self.current.lexeme, "nil")) {
                const reg = self.proto.allocTemp();
                try self.proto.emitLOADNIL(reg, 1);
                self.advance();
                return reg;
            } else if (std.mem.eql(u8, self.current.lexeme, "true") or
                std.mem.eql(u8, self.current.lexeme, "false"))
            {
                const is_true = std.mem.eql(u8, self.current.lexeme, "true");
                const reg = self.proto.allocTemp();
                try self.proto.emitLOADBOOL(reg, is_true, false);
                self.advance();
                return reg;
            }
        } else if (self.current.kind == .Identifier) {
            // Check for function calls that return values
            if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "(")) {
                return try self.parseFunctionCallExpr();
            }
            // For now, only support loop variable 'i' which is at base+3
            var base_reg: u8 = undefined;
            if (std.mem.eql(u8, self.current.lexeme, "i")) {
                base_reg = self.proto.allocTemp();
                // Loop variable is stored at base+3, copy to new register
                try self.proto.emitMOVE(base_reg, 3); // base+3 = loop variable
                self.advance();
            } else {
                // Check if it's a variable/parameter
                const var_name = self.current.lexeme;
                if (self.proto.findVariable(var_name)) |var_reg| {
                    base_reg = self.proto.allocTemp();
                    try self.proto.emitMOVE(base_reg, var_reg);
                    self.advance();
                } else {
                    return error.UnsupportedIdentifier;
                }
            }

            // Handle field access: t.field or t.a.b.c
            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ".")) {
                self.advance(); // consume '.'

                if (self.current.kind != .Identifier) {
                    return error.ExpectedIdentifier;
                }

                const field_name = self.current.lexeme;
                self.advance(); // consume field name

                // Add field name to constants
                const key_const = try self.proto.addConstString(field_name);

                // Emit GETFIELD: dst = base[key]
                const dst_reg = self.proto.allocTemp();
                try self.proto.emitGETFIELD(dst_reg, base_reg, key_const);

                // The result becomes the new base for chained access
                base_reg = dst_reg;
            }

            return base_reg;
        }

        return error.ExpectedExpression;
    }

    /// Parse table constructor: { [field,]* }
    /// field = Name '=' expr | '[' expr ']' '=' expr | expr
    fn parseTableConstructor(self: *Parser) ParseError!u8 {
        // Consume '{'
        self.advance();

        // Allocate register for table
        const table_reg = self.proto.allocTemp();
        try self.proto.emitNEWTABLE(table_reg);

        // Parse fields until '}'
        while (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "}"))) {
            // Check for named field: Name '=' expr
            if (self.current.kind == .Identifier and
                self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "="))
            {
                // Named field
                const field_name = self.current.lexeme;
                self.advance(); // consume name
                self.advance(); // consume '='

                // Parse value expression (allocates temp register)
                const base_reg = self.proto.next_reg;
                const value_reg = try self.parseExpr();

                // Add field name to constants
                const key_const = try self.proto.addConstString(field_name);

                // Emit SETFIELD: table[key] = value
                try self.proto.emitSETFIELD(table_reg, key_const, value_reg);

                // Free temp registers used by the expression
                self.proto.next_reg = base_reg;
            } else {
                // For now, only support named fields
                return error.UnsupportedTableField;
            }

            // Check for field separator (',' or ';') or end
            if (self.current.kind == .Symbol) {
                if (std.mem.eql(u8, self.current.lexeme, ",") or
                    std.mem.eql(u8, self.current.lexeme, ";"))
                {
                    self.advance(); // consume separator
                } else if (std.mem.eql(u8, self.current.lexeme, "}")) {
                    break;
                } else {
                    return error.ExpectedFieldSeparator;
                }
            }
        }

        // Consume '}'
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "}"))) {
            return error.ExpectedCloseBrace;
        }
        self.advance();

        return table_reg;
    }

    fn parseMul(self: *Parser) ParseError!u8 {
        var left = try self.parsePrimary();

        while (self.current.kind == .Symbol and
            (std.mem.eql(u8, self.current.lexeme, "*") or
                std.mem.eql(u8, self.current.lexeme, "/") or
                std.mem.eql(u8, self.current.lexeme, "%")))
        {
            const op = self.current.lexeme;
            self.advance(); // consume operator
            const right = try self.parsePrimary();

            const dst = self.proto.allocTemp();
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

    fn parseAdd(self: *Parser) ParseError!u8 {
        var left = try self.parseMul();

        while (self.current.kind == .Symbol and
            (std.mem.eql(u8, self.current.lexeme, "+") or
                std.mem.eql(u8, self.current.lexeme, "-")))
        {
            const op = self.current.lexeme;
            self.advance(); // consume operator
            const right = try self.parseMul();

            const dst = self.proto.allocTemp();
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

    // Comparison operators are lowered into conditional jumps + LOADBOOL.
    // This mirrors Lua VM semantics:
    //   - comparison emits a test instruction (EQ/LT/LE)
    //   - followed by two LOADBOOL instructions to materialize a boolean value
    //
    // The exact opcode sequence is intentionally explicit here.
    // Once CALL / RETURN and boolean handling are fully stabilized,
    // this block may be refactored into a more compact form.

    fn parseCompare(self: *Parser) ParseError!u8 {
        var left = try self.parseAdd();

        while (self.current.kind == .Symbol and
            (std.mem.eql(u8, self.current.lexeme, "==") or
                std.mem.eql(u8, self.current.lexeme, "!=") or
                std.mem.eql(u8, self.current.lexeme, "<") or
                std.mem.eql(u8, self.current.lexeme, "<=") or
                std.mem.eql(u8, self.current.lexeme, ">") or
                std.mem.eql(u8, self.current.lexeme, ">=")))
        {
            const op = self.current.lexeme;
            self.advance(); // consume operator
            const right = try self.parseAdd();

            const dst = self.proto.allocTemp();
            if (std.mem.eql(u8, op, "==")) {
                // For ==: if equal then set true, else set false
                try self.proto.emitEQ(left, right, 0); // skip if equal (negate=0)
                try self.proto.emitLOADBOOL(dst, false, true); // not equal: false, skip next
                try self.proto.emitLOADBOOL(dst, true, false); // equal: true
            } else if (std.mem.eql(u8, op, "!=")) {
                // For !=: if not equal then set true, else set false
                try self.proto.emitEQ(left, right, 1); // skip if NOT equal (negate=1)
                try self.proto.emitLOADBOOL(dst, false, true); // equal: false, skip next
                try self.proto.emitLOADBOOL(dst, true, false); // not equal: true
            } else if (std.mem.eql(u8, op, "<")) {
                // For <: if left < right then set true, else set false
                try self.proto.emitLT(left, right, 0); // skip if left < right (negate=0)
                try self.proto.emitLOADBOOL(dst, false, true); // not less than: false, skip next
                try self.proto.emitLOADBOOL(dst, true, false); // less than: true
            } else if (std.mem.eql(u8, op, "<=")) {
                // For <=: if left <= right then set true, else set false
                try self.proto.emitLE(left, right, 0); // skip if left <= right (negate=0)
                try self.proto.emitLOADBOOL(dst, false, true); // not less than or equal: false, skip next
                try self.proto.emitLOADBOOL(dst, true, false); // less than or equal: true
            } else if (std.mem.eql(u8, op, ">")) {
                // For >: if left > right then set true, else set false
                // Use LT with swapped operands: right < left
                try self.proto.emitLT(right, left, 0); // skip if right < left (negate=0)
                try self.proto.emitLOADBOOL(dst, false, true); // not greater than: false, skip next
                try self.proto.emitLOADBOOL(dst, true, false); // greater than: true
            } else if (std.mem.eql(u8, op, ">=")) {
                // For >=: if left >= right then set true, else set false
                // Use LE with swapped operands: right <= left
                try self.proto.emitLE(right, left, 0); // skip if right <= left (negate=0)
                try self.proto.emitLOADBOOL(dst, false, true); // not greater than or equal: false, skip next
                try self.proto.emitLOADBOOL(dst, true, false); // greater than or equal: true
            } else {
                return error.UnsupportedOperator;
            }
            left = dst;
        }

        return left;
    }

    // Control flow parsing
    fn parseIf(self: *Parser) ParseError!void {
        self.advance(); // consume 'if'

        // Mark registers before condition - will reset after TEST
        const cond_mark = self.proto.markTemps();

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

        // Release condition temporaries
        self.proto.resetTemps(cond_mark);

        // Mark for then branch
        const then_mark = self.proto.markTemps();
        try self.proto.enterScope();

        // Parse then branch
        try self.parseStatements();

        // Release then branch scope and temporaries
        self.proto.leaveScope();
        self.proto.resetTemps(then_mark);

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

            // Mark for elseif condition
            const elseif_cond_mark = self.proto.markTemps();

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

            // Release elseif condition temporaries
            self.proto.resetTemps(elseif_cond_mark);

            // Mark for elseif body
            const elseif_body_mark = self.proto.markTemps();
            try self.proto.enterScope();

            // Parse elseif body
            try self.parseStatements();

            // Release elseif body scope and temporaries
            self.proto.leaveScope();
            self.proto.resetTemps(elseif_body_mark);

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

            // Mark for else body
            const else_body_mark = self.proto.markTemps();
            try self.proto.enterScope();

            // Parse else branch
            try self.parseStatements();

            // Release else body scope and temporaries
            self.proto.leaveScope();
            self.proto.resetTemps(else_body_mark);
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

    fn parseFor(self: *Parser) ParseError!void {
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
            step_reg = self.proto.allocTemp();
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

        // Save locals_top before for loop modifies it (for restoration after loop)
        const saved_locals_top = self.proto.locals_top;

        // Set next_reg and locals_top past for loop registers (idx, limit, step, user_var)
        // This ensures statements inside the loop don't overwrite loop control registers
        self.proto.next_reg = base_reg + NUMERIC_FOR_REGS;
        self.proto.locals_top = base_reg + NUMERIC_FOR_REGS;

        // Mark for loop body - each iteration resets to this point
        const loop_body_mark = self.proto.markTemps();

        // Parse loop body
        try self.parseStatements();

        // Release loop body temporaries
        self.proto.resetTemps(loop_body_mark);

        // Restore locals_top after for loop (loop control vars are no longer live)
        self.proto.locals_top = saved_locals_top;
        self.proto.next_reg = saved_locals_top;

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

    fn parseStatements(self: *Parser) StatementError!void {
        // Support return statements and nested if/for inside blocks
        while (self.current.kind != .Eof and
            !(self.current.kind == .Keyword and
                (std.mem.eql(u8, self.current.lexeme, "else") or
                    std.mem.eql(u8, self.current.lexeme, "elseif") or
                    std.mem.eql(u8, self.current.lexeme, "end"))))
        {
            // Mark registers before each statement
            const stmt_mark = self.proto.markTemps();

            if (self.current.kind == .Keyword) {
                if (std.mem.eql(u8, self.current.lexeme, "return")) {
                    try self.parseReturn();
                    return; // return ends the statement block
                } else if (std.mem.eql(u8, self.current.lexeme, "if")) {
                    try self.parseIf();
                } else if (std.mem.eql(u8, self.current.lexeme, "for")) {
                    try self.parseFor();
                } else if (std.mem.eql(u8, self.current.lexeme, "local")) {
                    try self.parseLocalDecl();
                } else {
                    return error.UnsupportedStatement;
                }
            } else if (self.current.kind == .Identifier) {
                // Handle function calls like print(...) or tostring(...)
                if (std.mem.eql(u8, self.current.lexeme, "print") or
                    std.mem.eql(u8, self.current.lexeme, "tostring"))
                {
                    try self.parseFunctionCall();
                } else if (std.mem.eql(u8, self.current.lexeme, "io")) {
                    try self.parseIoCall();
                } else {
                    return error.UnsupportedStatement;
                }
            } else {
                return error.UnsupportedStatement;
            }

            // Release statement temporaries
            self.proto.resetTemps(stmt_mark);
        }
    }

    /// Parse local variable declaration: local name = expr
    /// Variable is only visible AFTER its initializer (so `local a = a` refers to outer a)
    fn parseLocalDecl(self: *Parser) ParseError!void {
        self.advance(); // consume 'local'

        // Expect identifier
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        const var_name = self.current.lexeme;
        self.advance(); // consume identifier

        // Allocate register from locals_top (not temps) - reserves the slot
        const var_reg = self.proto.allocLocalReg();

        // Check for initialization
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "=")) {
            self.advance(); // consume '='

            // Parse initializer expression (temps start after var_reg)
            const expr_reg = try self.parseExpr();

            // Move expression result to variable register if needed
            if (expr_reg != var_reg) {
                try self.proto.emitMOVE(var_reg, expr_reg);
            }
        } else {
            // No initializer - initialize to nil
            try self.proto.emitLOADNIL(var_reg, 1);
        }

        // NOW add to scope (variable visible after its initializer)
        try self.proto.addVariable(var_name, var_reg);
    }

    // Function call parsing
    fn parseFunctionCall(self: *Parser) ParseError!void {
        // Support "print" and "tostring" functions
        const func_name = self.current.lexeme;
        if (!std.mem.eql(u8, func_name, "print") and
            !std.mem.eql(u8, func_name, "tostring"))
        {
            return error.UnsupportedFunction;
        }

        self.advance(); // consume function name

        // Expect '('
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Load function constant
        const func_reg = self.proto.allocTemp();
        const func_id = if (std.mem.eql(u8, func_name, "print"))
            NativeFnId.print
        else
            NativeFnId.tostring;
        const func_const_idx = try self.proto.addNativeFunc(func_id);
        try self.proto.emitLoadK(func_reg, func_const_idx);

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

        // Emit CALL instruction
        const nresults = if (std.mem.eql(u8, func_name, "print")) @as(u8, 0) else @as(u8, 1);
        try self.proto.emitCall(func_reg, arg_count, nresults);
    }

    fn parseGenericFunctionCall(self: *Parser) ParseError!void {
        // Parse function call - support native and user-defined functions
        const func_name = self.current.lexeme;

        // Check if it's a user-defined function first
        if (self.proto.findFunction(func_name)) |_| {
            // Handle user-defined function call
            self.advance(); // consume function name

            // Expect '('
            if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
                return error.ExpectedLeftParen;
            }
            self.advance(); // consume '('

            // Load closure from _ENV[func_name] via GETTABUP (not creating new closure!)
            const func_reg = self.proto.allocTemp();
            const name_const = try self.proto.addConstString(func_name);
            try self.proto.emitGETTABUP(func_reg, 0, name_const);

            // Parse arguments with expression evaluation
            var arg_count: u8 = 0;
            if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
                // Parse first argument
                const arg_reg = try self.parseExpr();
                // Move argument to correct position (func_reg + 1)
                if (arg_reg != func_reg + 1) {
                    try self.proto.emitMOVE(func_reg + 1, arg_reg);
                }
                arg_count = 1;

                // Parse additional arguments
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

            // Emit CALL instruction (0 results for statements)
            try self.proto.emitCall(func_reg, arg_count, 0);
            return;
        }

        // Map function name to native function ID
        const func_id = if (std.mem.eql(u8, func_name, "print"))
            NativeFnId.print
        else if (std.mem.eql(u8, func_name, "tostring"))
            NativeFnId.tostring
        else
            return error.UnsupportedFunction;

        self.advance(); // consume function name

        // Expect '('
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Load function constant
        const func_reg = self.proto.allocTemp();
        const func_const_idx = try self.proto.addNativeFunc(func_id);
        try self.proto.emitLoadK(func_reg, func_const_idx);

        // Parse arguments
        var arg_count: u8 = 0;
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            // Parse first argument
            const arg_reg = try self.parseExpr();
            if (arg_reg != func_reg + 1) {
                try self.proto.emitMOVE(func_reg + 1, arg_reg);
            }
            arg_count = 1;
        }

        // Expect ')'
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            return error.ExpectedRightParen;
        }
        self.advance(); // consume ')'

        // Emit CALL instruction (0 results for statements)
        try self.proto.emitCall(func_reg, arg_count, 0);
    }

    fn parseFunctionCallExpr(self: *Parser) ParseError!u8 {
        // Parse function call that returns a value
        const func_name = self.current.lexeme;

        // Check if it's a user-defined function first
        if (self.proto.findFunction(func_name)) |_| {
            // Handle user-defined function call with return value
            self.advance(); // consume function name

            // Expect '('
            if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
                return error.ExpectedLeftParen;
            }
            self.advance(); // consume '('

            // Load closure from _ENV[func_name] via GETTABUP (not creating new closure!)
            const func_reg = self.proto.allocTemp();
            const name_const = try self.proto.addConstString(func_name);
            try self.proto.emitGETTABUP(func_reg, 0, name_const);

            // Parse arguments with expression evaluation
            var arg_count: u8 = 0;
            if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
                // Parse first argument
                const arg_reg = try self.parseExpr();
                // Move argument to correct position (func_reg + 1)
                if (arg_reg != func_reg + 1) {
                    try self.proto.emitMOVE(func_reg + 1, arg_reg);
                }
                arg_count = 1;

                // Parse additional arguments
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

            // Emit CALL instruction (1 result)
            try self.proto.emitCall(func_reg, arg_count, 1);

            // Return the register where the result is stored
            return func_reg;
        }

        // Map function name to native function ID
        const func_id = if (std.mem.eql(u8, func_name, "tostring"))
            NativeFnId.tostring
        else if (std.mem.eql(u8, func_name, "print"))
            NativeFnId.print
        else
            return error.UnsupportedFunction;

        self.advance(); // consume function name

        // Expect '('
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Load function constant
        const func_reg = self.proto.allocTemp();
        const func_const_idx = try self.proto.addNativeFunc(func_id);
        try self.proto.emitLoadK(func_reg, func_const_idx);

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
        }

        // Expect ')'
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            return error.ExpectedRightParen;
        }
        self.advance(); // consume ')'

        // Emit CALL instruction (1 result)
        try self.proto.emitCall(func_reg, arg_count, 1);

        // Return the register where the result is stored
        return func_reg;
    }

    fn parseExpr(self: *Parser) ParseError!u8 {
        return self.parseCompare();
    }

    // Special parsing functions
    fn parseIoCall(self: *Parser) ParseError!void {
        // Parse "io.write(...)" calls
        // Current token should be "io"
        if (!std.mem.eql(u8, self.current.lexeme, "io")) {
            return error.UnsupportedStatement;
        }
        self.advance(); // consume "io"

        // Expect '.'
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "."))) {
            return error.UnsupportedStatement;
        }
        self.advance(); // consume '.'

        // Expect method name (currently only support "write")
        if (!(self.current.kind == .Identifier and std.mem.eql(u8, self.current.lexeme, "write"))) {
            return error.UnsupportedStatement;
        }
        self.advance(); // consume "write"

        // Expect '('
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Generate bytecode for io.write call
        // Get io table from global
        const io_reg = self.proto.allocTemp();
        const io_key_const = try self.proto.addConstString("io");
        try self.proto.emitGETTABUP(io_reg, 0, io_key_const);

        // Get write method from io table
        const write_reg = self.proto.allocTemp();
        const write_key_const = try self.proto.addConstString("write");
        try self.proto.emitLoadK(write_reg, write_key_const);

        // Get io.write function
        const func_reg = self.proto.allocTemp();
        try self.proto.emitGETTABLE(func_reg, io_reg, write_reg);

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
        }

        // Expect ')'
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            return error.ExpectedRightParen;
        }
        self.advance(); // consume ')'

        // Emit CALL instruction (0 results for io.write)
        try self.proto.emitCall(func_reg, arg_count, 0);
    }

    fn parseFunctionDefinition(self: *Parser) ParseError!void {
        // function name(param) return param end
        self.advance(); // consume 'function'

        // Parse function name
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        const func_name = self.current.lexeme;
        // Add function name to constants NOW, before lexer advances through body
        // (func_name slice becomes invalid after advance)
        const name_const = try self.proto.addConstString(func_name);
        self.advance(); // consume function name

        // Parse parameters: (param)
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Create a separate builder for function body with parent reference
        var func_builder = ProtoBuilder.initWithParent(self.proto.allocator, self.proto);
        defer func_builder.deinit(); // Clean up at end of function

        // Create Proto container early (address is fixed, content will be filled later)
        const proto_ptr = try self.proto.allocator.create(Proto);

        // Temporarily add function for recursive calls with unfilled Proto
        try self.proto.addFunction(func_name, proto_ptr);

        // Parse parameters and assign to registers
        var param_count: u8 = 0;
        if (self.current.kind == .Identifier) {
            // Parse first parameter
            const param_name = self.current.lexeme;
            self.advance();

            // Parameters start at register 0 in function scope
            try func_builder.addVariable(param_name, param_count);
            param_count += 1;

            // Parse additional parameters
            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
                self.advance(); // consume ','
                if (self.current.kind != .Identifier) {
                    return error.ExpectedIdentifier;
                }
                const next_param = self.current.lexeme;
                self.advance();

                try func_builder.addVariable(next_param, param_count);
                param_count += 1;
            }

            // Parameters occupy registers 0..param_count-1
            func_builder.next_reg = param_count;
            func_builder.locals_top = param_count;
        }

        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            return error.ExpectedRightParen;
        }
        self.advance(); // consume ')'

        // Parse function body dynamically
        const old_proto = self.proto;
        self.proto = &func_builder; // Switch to function's ProtoBuilder
        defer self.proto = old_proto; // Restore original ProtoBuilder

        try self.parseStatements(); // Parse function body statements

        // Expect 'end'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "end"))) {
            return error.ExpectedEnd;
        }
        self.advance(); // consume 'end'

        // Add implicit RETURN if no explicit return was added
        if (func_builder.code.items.len == 0 or
            func_builder.code.items[func_builder.code.items.len - 1].getOpCode() != .RETURN)
        {
            try func_builder.emit(.RETURN, 0, 1, 0);
        }

        // Convert function builder to Proto with dynamic allocation
        const func_proto_data = try func_builder.toProtoWithParams(self.proto.allocator, param_count);

        // Fill the Proto container with actual content (late binding)
        proto_ptr.* = func_proto_data;

        // Proto is already registered in old_proto.functions for recursive lookup
        // Now emit CLOSURE + SETTABUP to store in _ENV (globals)
        const closure_reg = old_proto.allocTemp();
        const proto_idx = try old_proto.addProto(proto_ptr);
        try old_proto.emitClosure(closure_reg, proto_idx);

        // Store closure in _ENV[func_name] using pre-computed constant index
        try old_proto.emitSETTABUP(0, name_const, closure_reg);
    }
};
