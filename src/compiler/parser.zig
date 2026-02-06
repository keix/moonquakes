const std = @import("std");
const lexer = @import("lexer.zig");
const Lexer = lexer.Lexer;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const proto_mod = @import("proto.zig");
const RawProto = proto_mod.RawProto;
const ConstRef = proto_mod.ConstRef;
const Upvaldesc = proto_mod.Upvaldesc;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const opcodes = @import("opcodes.zig");
const Instruction = opcodes.Instruction;

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
    ExpectedCloseBracket,
    ExpectedUntil,
    BreakOutsideLoop,
    ExpectedColon,
};

const StatementError = std.mem.Allocator.Error || ParseError;

/// Free a RawProto and all its owned memory
pub fn freeRawProto(allocator: std.mem.Allocator, proto: *RawProto) void {
    allocator.free(proto.code);
    allocator.free(proto.booleans);
    allocator.free(proto.integers);
    allocator.free(proto.numbers);
    // Free each string's content
    for (proto.strings) |s| {
        allocator.free(s);
    }
    allocator.free(proto.strings);
    allocator.free(proto.native_ids);
    allocator.free(proto.const_refs);
    // Recursively free nested protos
    for (proto.protos) |nested| {
        freeRawProto(allocator, @constCast(nested));
    }
    allocator.free(proto.protos);
    allocator.destroy(proto);
}

// Simple function storage for minimal implementation
const FunctionEntry = struct {
    name: []const u8,
    proto: *RawProto,
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
    // Type-specific constant arrays (unmaterialized)
    booleans: std.ArrayList(bool),
    integers: std.ArrayList(i64),
    numbers: std.ArrayList(f64),
    strings: std.ArrayList([]const u8),
    native_ids: std.ArrayList(NativeFnId),
    // Ordered constant references
    const_refs: std.ArrayList(ConstRef),
    protos: std.ArrayList(*const RawProto), // Nested function prototypes (for CLOSURE)
    maxstacksize: u8,
    next_reg: u8, // Next available register (for temps)
    locals_top: u8, // Register watermark: locals occupy [0, locals_top)
    allocator: std.mem.Allocator,
    functions: std.ArrayList(FunctionEntry),
    variables: std.ArrayList(VariableEntry),
    scope_starts: std.ArrayList(ScopeMark), // Stack of scope boundaries
    upvalues: std.ArrayList(Upvaldesc), // Upvalue descriptors for this function
    parent: ?*ProtoBuilder, // For function scope hierarchy

    pub fn init(allocator: std.mem.Allocator, parent: ?*ProtoBuilder) ProtoBuilder {
        return .{
            .code = std.ArrayList(Instruction).init(allocator),
            .booleans = std.ArrayList(bool).init(allocator),
            .integers = std.ArrayList(i64).init(allocator),
            .numbers = std.ArrayList(f64).init(allocator),
            .strings = std.ArrayList([]const u8).init(allocator),
            .native_ids = std.ArrayList(NativeFnId).init(allocator),
            .const_refs = std.ArrayList(ConstRef).init(allocator),
            .protos = std.ArrayList(*const RawProto).init(allocator),
            .maxstacksize = 0,
            .next_reg = 0,
            .locals_top = 0,
            .allocator = allocator,
            .functions = std.ArrayList(FunctionEntry).init(allocator),
            .variables = std.ArrayList(VariableEntry).init(allocator),
            .scope_starts = std.ArrayList(ScopeMark).init(allocator),
            .upvalues = std.ArrayList(Upvaldesc).init(allocator),
            .parent = parent,
        };
    }

    pub fn deinit(self: *ProtoBuilder) void {
        // Free function protos and their allocated arrays
        // All slices are allocator-owned (even when len=0), so always free
        for (self.functions.items) |entry| {
            freeRawProto(self.allocator, entry.proto);
        }

        // Free duplicated strings
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }

        self.code.deinit();
        self.booleans.deinit();
        self.integers.deinit();
        self.numbers.deinit();
        self.strings.deinit();
        self.native_ids.deinit();
        self.const_refs.deinit();
        self.protos.deinit();
        self.functions.deinit();
        self.variables.deinit();
        self.scope_starts.deinit();
        self.upvalues.deinit();
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

    pub fn emitBAND(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.BAND, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitBOR(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.BOR, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitBXOR(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.BXOR, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitBNOT(self: *ProtoBuilder, dst: u8, src: u8) !void {
        const instr = Instruction.initABC(.BNOT, dst, src, 0);
        try self.code.append(instr);
    }

    pub fn emitSHL(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.SHL, dst, left, right);
        try self.code.append(instr);
    }

    pub fn emitSHR(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.SHR, dst, left, right);
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

    pub fn emitIDIV(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.IDIV, dst, left, right);
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

    /// Emit GETUPVAL instruction: R[A] := UpValue[B]
    pub fn emitGETUPVAL(self: *ProtoBuilder, dst: u8, upval_idx: u8) !void {
        const instr = Instruction.initABC(.GETUPVAL, dst, upval_idx, 0);
        try self.code.append(instr);
        self.updateMaxStack(dst + 1);
    }

    /// Emit SETUPVAL instruction: UpValue[B] := R[A]
    pub fn emitSETUPVAL(self: *ProtoBuilder, src: u8, upval_idx: u8) !void {
        const instr = Instruction.initABC(.SETUPVAL, src, upval_idx, 0);
        try self.code.append(instr);
    }

    /// Emit NOT instruction: R[A] := not R[B]
    pub fn emitNOT(self: *ProtoBuilder, dst: u8, src: u8) !void {
        const instr = Instruction.initABC(.NOT, dst, src, 0);
        try self.code.append(instr);
    }

    /// Emit UNM instruction: R[A] := -R[B]
    pub fn emitUNM(self: *ProtoBuilder, dst: u8, src: u8) !void {
        const instr = Instruction.initABC(.UNM, dst, src, 0);
        try self.code.append(instr);
    }

    /// Emit LEN instruction: R[A] := #R[B]
    pub fn emitLEN(self: *ProtoBuilder, dst: u8, src: u8) !void {
        const instr = Instruction.initABC(.LEN, dst, src, 0);
        try self.code.append(instr);
    }

    /// Emit CONCAT instruction: R[A] := R[B] .. ... .. R[C]
    pub fn emitCONCAT(self: *ProtoBuilder, dst: u8, start: u8, end: u8) !void {
        const instr = Instruction.initABC(.CONCAT, dst, start, end);
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

    /// Emit SETTABLE instruction: R[A][R[B]] := R[C]
    pub fn emitSETTABLE(self: *ProtoBuilder, table: u8, key: u8, src: u8) !void {
        const instr = Instruction.initABC(.SETTABLE, table, key, src);
        try self.code.append(instr);
    }

    /// Emit SETI instruction: R[A][B] := R[C] (B is integer immediate)
    pub fn emitSETI(self: *ProtoBuilder, table: u8, index: u8, src: u8) !void {
        const instr = Instruction.initABC(.SETI, table, index, src);
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

    pub fn emitPOW(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.POW, dst, left, right);
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

    pub fn emitReturn(self: *ProtoBuilder, reg: u8, count: u8) !void {
        // B = count + 1 (B=1 means 0 values, B=2 means 1 value, etc.)
        const instr = Instruction.initABC(.RETURN, reg, count + 1, 0);
        try self.code.append(instr);
    }

    pub fn emitSub(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.SUB, dst, left, right);
        try self.code.append(instr);
    }

    /// Emit TESTSET instruction: if (R[B].toBoolean() == k) R[A] := R[B] else pc++
    pub fn emitTESTSET(self: *ProtoBuilder, dst: u8, src: u8, k: bool) !void {
        const instr = Instruction.initABCk(.TESTSET, dst, src, 0, k);
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
        // Check for hex prefix (0x or 0X)
        if (lexeme.len > 2 and lexeme[0] == '0' and (lexeme[1] == 'x' or lexeme[1] == 'X')) {
            const hex_part = lexeme[2..];

            // Check if it's a hex float (contains '.' or 'p'/'P')
            var is_hex_float = false;
            for (hex_part) |c| {
                if (c == '.' or c == 'p' or c == 'P') {
                    is_hex_float = true;
                    break;
                }
            }

            if (is_hex_float) {
                // Parse as hex float
                const value = parseHexFloat(lexeme) catch return error.InvalidNumber;
                const idx: u16 = @intCast(self.numbers.items.len);
                try self.numbers.append(value);
                try self.const_refs.append(.{ .kind = .number, .index = idx });
                return @intCast(self.const_refs.items.len - 1);
            } else {
                // Parse as hex integer
                const value = std.fmt.parseInt(i64, hex_part, 16) catch return error.InvalidNumber;
                const idx: u16 = @intCast(self.integers.items.len);
                try self.integers.append(value);
                try self.const_refs.append(.{ .kind = .integer, .index = idx });
                return @intCast(self.const_refs.items.len - 1);
            }
        }

        // Try parsing as decimal integer first
        if (std.fmt.parseInt(i64, lexeme, 10)) |value| {
            const idx: u16 = @intCast(self.integers.items.len);
            try self.integers.append(value);
            try self.const_refs.append(.{ .kind = .integer, .index = idx });
            return @intCast(self.const_refs.items.len - 1);
        } else |_| {
            // Try parsing as float
            const value = std.fmt.parseFloat(f64, lexeme) catch return error.InvalidNumber;
            const idx: u16 = @intCast(self.numbers.items.len);
            try self.numbers.append(value);
            try self.const_refs.append(.{ .kind = .number, .index = idx });
            return @intCast(self.const_refs.items.len - 1);
        }
    }

    /// Parse hex float like 0x1.5p10, 0x1p4, 0x1.8p-1
    fn parseHexFloat(lexeme: []const u8) !f64 {
        // Skip 0x prefix
        var i: usize = 2;

        // Parse integer part (hex digits)
        var int_part: f64 = 0;
        while (i < lexeme.len and isHexDigit(lexeme[i])) {
            int_part = int_part * 16 + @as(f64, @floatFromInt(hexDigitValue(lexeme[i])));
            i += 1;
        }

        // Parse fractional part if present
        var frac_part: f64 = 0;
        if (i < lexeme.len and lexeme[i] == '.') {
            i += 1;
            var frac_mult: f64 = 1.0 / 16.0;
            while (i < lexeme.len and isHexDigit(lexeme[i])) {
                frac_part += @as(f64, @floatFromInt(hexDigitValue(lexeme[i]))) * frac_mult;
                frac_mult /= 16.0;
                i += 1;
            }
        }

        var mantissa = int_part + frac_part;

        // Parse binary exponent if present (p or P followed by decimal exponent)
        if (i < lexeme.len and (lexeme[i] == 'p' or lexeme[i] == 'P')) {
            i += 1;

            // Parse exponent sign
            var exp_neg = false;
            if (i < lexeme.len and lexeme[i] == '-') {
                exp_neg = true;
                i += 1;
            } else if (i < lexeme.len and lexeme[i] == '+') {
                i += 1;
            }

            // Parse exponent value (decimal digits)
            var exp: i32 = 0;
            while (i < lexeme.len and lexeme[i] >= '0' and lexeme[i] <= '9') {
                exp = exp * 10 + @as(i32, @intCast(lexeme[i] - '0'));
                i += 1;
            }

            if (exp_neg) exp = -exp;

            // Apply binary exponent: mantissa * 2^exp
            mantissa = mantissa * std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exp)));
        }

        return mantissa;
    }

    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn hexDigitValue(c: u8) u8 {
        if (c >= '0' and c <= '9') return c - '0';
        if (c >= 'a' and c <= 'f') return c - 'a' + 10;
        if (c >= 'A' and c <= 'F') return c - 'A' + 10;
        return 0;
    }

    pub fn addConstString(self: *ProtoBuilder, lexeme: []const u8) !u32 {
        // Store raw string data (no GC allocation)
        // TODO: String deduplication strategy
        // - Currently: Each string is duplicated independently (no dedup within RawProto)
        // - Future consideration: Intern strings at materialize time via GC.allocString?
        //   GC.allocString already interns, so duplicates in RawProto will merge at runtime.
        // - Alternative: Dedup at compile time using a hash map in ProtoBuilder
        // For now, simple duplication is sufficient; GC handles runtime interning.
        const idx: u16 = @intCast(self.strings.items.len);
        const duped = try self.allocator.dupe(u8, lexeme);
        try self.strings.append(duped);
        try self.const_refs.append(.{ .kind = .string, .index = idx });
        return @intCast(self.const_refs.items.len - 1);
    }

    pub fn addNativeFunc(self: *ProtoBuilder, native_id: NativeFnId) !u32 {
        // Store native function ID (no GC allocation)
        const idx: u16 = @intCast(self.native_ids.items.len);
        try self.native_ids.append(native_id);
        try self.const_refs.append(.{ .kind = .native_fn, .index = idx });
        return @intCast(self.const_refs.items.len - 1);
    }

    /// Add a nested function prototype for CLOSURE opcode
    pub fn addProto(self: *ProtoBuilder, proto: *const RawProto) !u32 {
        try self.protos.append(proto);
        return @intCast(self.protos.items.len - 1);
    }

    fn updateMaxStack(self: *ProtoBuilder, stack_size: u8) void {
        if (stack_size > self.maxstacksize) {
            self.maxstacksize = stack_size;
        }
    }

    pub fn addFunction(self: *ProtoBuilder, name: []const u8, proto: *RawProto) !void {
        try self.functions.append(FunctionEntry{
            .name = name,
            .proto = proto,
        });
    }

    pub fn findFunction(self: *ProtoBuilder, name: []const u8) ?*RawProto {
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
        // Search in reverse order so inner scope shadows outer
        var i = self.variables.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.variables.items[i];
            if (std.mem.eql(u8, entry.name, name)) {
                return entry.reg;
            }
        }
        return null;
    }

    /// Result of variable resolution - either local register or upvalue index
    pub const VarLocation = union(enum) {
        local: u8, // register index in current function
        upvalue: u8, // upvalue index
    };

    /// Resolve a variable, searching current scope and parent scopes.
    /// If found in parent scope, creates an upvalue to capture it.
    pub fn resolveVariable(self: *ProtoBuilder, name: []const u8) !?VarLocation {
        // 1. Check local scope first
        if (self.findVariable(name)) |reg| {
            return .{ .local = reg };
        }

        // 2. Check if already captured as upvalue
        for (self.upvalues.items, 0..) |upval, i| {
            // Compare by checking parent's variable at that location
            // For simplicity, we'd need to store name in Upvaldesc or track differently
            // For now, rely on not creating duplicates by searching parent fresh each time
            _ = upval;
            _ = i;
        }

        // 3. If no parent, variable not found
        const parent = self.parent orelse return null;

        // 4. Try to resolve in parent (recursively)
        const parent_loc = try parent.resolveVariable(name) orelse return null;

        // 5. Create upvalue to capture from parent
        const upval_idx: u8 = @intCast(self.upvalues.items.len);
        switch (parent_loc) {
            .local => |reg| {
                // Parent has it as a local - capture from parent's stack
                try self.upvalues.append(.{ .instack = true, .idx = reg });
            },
            .upvalue => |idx| {
                // Parent has it as upvalue - capture from parent's upvalues
                try self.upvalues.append(.{ .instack = false, .idx = idx });
            },
        }

        return .{ .upvalue = upval_idx };
    }

    pub fn toRawProto(self: *ProtoBuilder, allocator: std.mem.Allocator, num_params: u8) !RawProto {
        // Always allocate via allocator (even for len=0) to ensure ownership
        const code_slice = try allocator.dupe(Instruction, self.code.items);
        const booleans_slice = try allocator.dupe(bool, self.booleans.items);
        const integers_slice = try allocator.dupe(i64, self.integers.items);
        const numbers_slice = try allocator.dupe(f64, self.numbers.items);
        const native_ids_slice = try allocator.dupe(NativeFnId, self.native_ids.items);
        const const_refs_slice = try allocator.dupe(ConstRef, self.const_refs.items);
        const protos_slice = try allocator.dupe(*const RawProto, self.protos.items);

        // Deep copy strings (each string's actual data, not just pointers)
        const strings_slice = try allocator.alloc([]const u8, self.strings.items.len);
        for (self.strings.items, 0..) |s, i| {
            strings_slice[i] = try allocator.dupe(u8, s);
        }

        // Duplicate upvalues
        const upvalues_slice = try allocator.dupe(Upvaldesc, self.upvalues.items);

        // Transfer ownership: clear functions list so deinit() won't double-free
        // The output RawProto now owns all nested protos via protos_slice
        self.functions.clearRetainingCapacity();
        self.protos.clearRetainingCapacity();

        return RawProto{
            .code = code_slice,
            .booleans = booleans_slice,
            .integers = integers_slice,
            .numbers = numbers_slice,
            .strings = strings_slice,
            .native_ids = native_ids_slice,
            .const_refs = const_refs_slice,
            .protos = protos_slice,
            .numparams = num_params,
            .is_vararg = false,
            .maxstacksize = self.maxstacksize,
            .nups = @intCast(self.upvalues.items.len),
            .upvalues = upvalues_slice,
        };
    }
};

pub const Parser = struct {
    lexer: *Lexer,
    current: Token,
    proto: *ProtoBuilder,
    break_jumps: std.ArrayList(u32),
    loop_depth: usize,

    pub fn init(lx: *Lexer, proto: *ProtoBuilder) Parser {
        var p = Parser{
            .lexer = lx,
            .proto = proto,
            .current = undefined,
            .break_jumps = std.ArrayList(u32).init(proto.allocator),
            .loop_depth = 0,
        };
        p.advance();
        return p;
    }

    pub fn deinit(self: *Parser) void {
        self.break_jumps.deinit();
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
        try self.proto.emitReturn(reg, 1);
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
                } else if (std.mem.eql(u8, self.current.lexeme, "while")) {
                    try self.parseWhile();
                } else if (std.mem.eql(u8, self.current.lexeme, "repeat")) {
                    try self.parseRepeatUntil();
                } else if (std.mem.eql(u8, self.current.lexeme, "function")) {
                    try self.parseFunctionDefinition();
                } else if (std.mem.eql(u8, self.current.lexeme, "local")) {
                    try self.parseLocalDecl();
                } else if (std.mem.eql(u8, self.current.lexeme, "do")) {
                    try self.parseDoEnd();
                } else {
                    return error.UnsupportedStatement;
                }
            } else if (self.current.kind == .Identifier) {
                // Look ahead to see if it's a function call (with parens or no-parens)
                const next = self.peek();
                const is_call_with_parens = next.kind == .Symbol and std.mem.eql(u8, next.lexeme, "(");
                const is_call_no_parens = next.kind == .String or
                    (next.kind == .Symbol and std.mem.eql(u8, next.lexeme, "{"));

                if (is_call_with_parens or is_call_no_parens) {
                    try self.parseGenericFunctionCall();
                } else if (std.mem.eql(u8, self.current.lexeme, "io")) {
                    try self.parseIoCall();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "=")) {
                    // Simple assignment: x = expr
                    try self.parseAssignment();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ".")) {
                    // Check for chained method call: t.a:method() or field assignment
                    try self.parseFieldAccessOrMethodCall();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ":")) {
                    // Method call: t:method()
                    try self.parseMethodCallStatement();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "[")) {
                    // Index assignment: t[key] = expr
                    try self.parseAssignment();
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

        // Check for bare return (no values)
        if (self.current.kind == .Keyword and
            (std.mem.eql(u8, self.current.lexeme, "end") or
                std.mem.eql(u8, self.current.lexeme, "else") or
                std.mem.eql(u8, self.current.lexeme, "elseif") or
                std.mem.eql(u8, self.current.lexeme, "until")))
        {
            try self.proto.emitReturn(0, 0);
            return;
        }
        if (self.current.kind == .Eof) {
            try self.proto.emitReturn(0, 0);
            return;
        }

        // Parse first return value
        const first_reg = try self.parseExpr();
        var count: u8 = 1;

        // Parse additional return values (comma-separated)
        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
            self.advance(); // consume ','
            const expr_reg = try self.parseExpr();

            // Values must be in consecutive registers
            const expected_reg = first_reg + count;
            if (expr_reg != expected_reg) {
                try self.proto.emitMOVE(expected_reg, expr_reg);
            }
            count += 1;
        }

        try self.proto.emitReturn(first_reg, count);
    }

    // do ... end block (creates a new scope)
    fn parseDoEnd(self: *Parser) ParseError!void {
        self.advance(); // consume 'do'

        try self.proto.enterScope();
        try self.parseStatements();
        self.proto.leaveScope();

        // Expect 'end'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "end"))) {
            return error.ExpectedEnd;
        }
        self.advance(); // consume 'end'
    }

    // Assignment: x = expr, t.field = expr, t.a.b = expr, t[key] = expr
    fn parseAssignment(self: *Parser) ParseError!void {
        const name = self.current.lexeme;
        self.advance(); // consume identifier

        // Check for field access: t.field or t.a.b.c
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ".")) {
            // Get the base table
            var table_reg: u8 = undefined;
            if (self.proto.findVariable(name)) |local_reg| {
                table_reg = local_reg;
            } else {
                // Global variable: load from _ENV
                table_reg = self.proto.allocTemp();
                const name_const = try self.proto.addConstString(name);
                try self.proto.emitGETTABUP(table_reg, 0, name_const);
            }

            // Parse field chain: .a.b.c or [key] until we hit '='
            var last_key_reg: ?u8 = null;
            var last_key_const: ?u32 = null;

            while (self.current.kind == .Symbol and
                (std.mem.eql(u8, self.current.lexeme, ".") or std.mem.eql(u8, self.current.lexeme, "[")))
            {
                // If we have a pending key, navigate to it first
                if (last_key_const) |kc| {
                    const next_reg = self.proto.allocTemp();
                    try self.proto.emitGETFIELD(next_reg, table_reg, kc);
                    table_reg = next_reg;
                    last_key_const = null;
                } else if (last_key_reg) |kr| {
                    const next_reg = self.proto.allocTemp();
                    try self.proto.emitGETTABLE(next_reg, table_reg, kr);
                    table_reg = next_reg;
                    last_key_reg = null;
                }

                if (std.mem.eql(u8, self.current.lexeme, ".")) {
                    self.advance(); // consume '.'

                    if (self.current.kind != .Identifier) {
                        return error.ExpectedIdentifier;
                    }
                    const field_name = self.current.lexeme;
                    self.advance(); // consume field name

                    last_key_const = try self.proto.addConstString(field_name);
                } else {
                    // '['
                    self.advance(); // consume '['

                    last_key_reg = try self.parseExpr();

                    if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "]"))) {
                        return error.ExpectedCloseBracket;
                    }
                    self.advance(); // consume ']'
                }
            }

            // Expect '='
            if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "="))) {
                return error.ExpectedEquals;
            }
            self.advance(); // consume '='

            const value_reg = try self.parseExpr();

            // Emit SET instruction for the final key
            if (last_key_const) |kc| {
                try self.proto.emitSETFIELD(table_reg, kc, value_reg);
            } else if (last_key_reg) |kr| {
                try self.proto.emitSETTABLE(table_reg, kr, value_reg);
            }
        } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "[")) {
            // Index assignment: t[key] = expr
            var table_reg: u8 = undefined;
            if (self.proto.findVariable(name)) |local_reg| {
                table_reg = local_reg;
            } else {
                // Global variable: load from _ENV
                table_reg = self.proto.allocTemp();
                const name_const = try self.proto.addConstString(name);
                try self.proto.emitGETTABUP(table_reg, 0, name_const);
            }

            self.advance(); // consume '['

            const key_reg = try self.parseExpr();

            if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "]"))) {
                return error.ExpectedCloseBracket;
            }
            self.advance(); // consume ']'

            // Expect '='
            if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "="))) {
                return error.ExpectedEquals;
            }
            self.advance(); // consume '='

            const value_reg = try self.parseExpr();

            try self.proto.emitSETTABLE(table_reg, key_reg, value_reg);
        } else {
            // Simple assignment: x = expr
            // Expect '='
            if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "="))) {
                return error.ExpectedEquals;
            }
            self.advance(); // consume '='

            const value_reg = try self.parseExpr();

            if (try self.proto.resolveVariable(name)) |loc| {
                switch (loc) {
                    .local => |local_reg| try self.proto.emitMOVE(local_reg, value_reg),
                    .upvalue => |idx| try self.proto.emitSETUPVAL(value_reg, idx),
                }
            } else {
                // Global variable: SETTABUP (_ENV[name] = value)
                const name_const = try self.proto.addConstString(name);
                try self.proto.emitSETTABUP(0, name_const, value_reg);
            }
        }
    }

    // Expression parsing (precedence order: Atom -> Pow -> Primary -> Mul -> Add -> Compare)
    // parseAtom: literals, parentheses, table constructors, identifiers
    fn parseAtom(self: *Parser) ParseError!u8 {
        // Table constructor: { field, field, ... }
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "{")) {
            return try self.parseTableConstructor();
        }

        // Parenthesized expression: (expr)
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "(")) {
            self.advance(); // consume '('
            const result = try self.parseExpr();
            if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
                return error.ExpectedRightParen;
            }
            self.advance(); // consume ')'
            return result;
        }

        if (self.current.kind == .Number) {
            const reg = self.proto.allocTemp();
            const k = try self.proto.addConstNumber(self.current.lexeme);
            try self.proto.emitLoadK(reg, k);
            self.advance();
            return reg;
        } else if (self.current.kind == .String) {
            const reg = self.proto.allocTemp();
            const lexeme = self.current.lexeme;

            // Check for long bracket string: [[...]] or [=[...]=] etc.
            if (lexeme.len >= 2 and lexeme[0] == '[') {
                // Count '=' signs to determine level
                var level: usize = 0;
                var i: usize = 1;
                while (i < lexeme.len and lexeme[i] == '=') {
                    level += 1;
                    i += 1;
                }
                // Extract content between [[ and ]] (or [=[ and ]=] etc.)
                const start = 2 + level; // skip [[ or [=[ etc.
                const end = lexeme.len - 2 - level; // skip ]] or ]=] etc.
                const str_content = lexeme[start..end];
                // Long bracket strings don't process escapes
                const k = try self.proto.addConstString(str_content);
                try self.proto.emitLoadK(reg, k);
            } else {
                // Regular quoted string: remove quotes and process escape sequences
                const str_raw = lexeme[1 .. lexeme.len - 1];
                const str_content = try processEscapes(self.proto.allocator, str_raw);
                defer self.proto.allocator.free(str_content);
                const k = try self.proto.addConstString(str_content);
                try self.proto.emitLoadK(reg, k);
            }
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
            } else if (std.mem.eql(u8, self.current.lexeme, "function")) {
                // Anonymous function: function(params) body end
                return try self.parseAnonymousFunction();
            }
        } else if (self.current.kind == .Identifier) {
            // Check for function calls that return values (with parens or no-parens)
            const next = self.peek();
            const is_call_with_parens = next.kind == .Symbol and std.mem.eql(u8, next.lexeme, "(");
            const is_call_no_parens = next.kind == .String or
                (next.kind == .Symbol and std.mem.eql(u8, next.lexeme, "{"));

            if (is_call_with_parens or is_call_no_parens) {
                return try self.parseFunctionCallExpr();
            }
            // Check if it's a variable/parameter (includes loop variables) or upvalue
            const var_name = self.current.lexeme;
            var base_reg: u8 = undefined;
            if (try self.proto.resolveVariable(var_name)) |loc| {
                base_reg = self.proto.allocTemp();
                switch (loc) {
                    .local => |var_reg| try self.proto.emitMOVE(base_reg, var_reg),
                    .upvalue => |idx| try self.proto.emitGETUPVAL(base_reg, idx),
                }
                self.advance();
            } else {
                return error.UnsupportedIdentifier;
            }

            // Handle field/index access and method calls: t.field, t[key], t:method(), or chained
            while (self.current.kind == .Symbol and
                (std.mem.eql(u8, self.current.lexeme, ".") or
                    std.mem.eql(u8, self.current.lexeme, "[") or
                    std.mem.eql(u8, self.current.lexeme, ":")))
            {
                if (std.mem.eql(u8, self.current.lexeme, ".")) {
                    self.advance(); // consume '.'

                    if (self.current.kind != .Identifier) {
                        return error.ExpectedIdentifier;
                    }

                    const field_name = self.current.lexeme;
                    self.advance(); // consume field name

                    const key_const = try self.proto.addConstString(field_name);
                    const dst_reg = self.proto.allocTemp();
                    try self.proto.emitGETFIELD(dst_reg, base_reg, key_const);
                    base_reg = dst_reg;

                    // Check for function call: t.g()
                    if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "(")) {
                        // The field value is a function, call it
                        const func_reg = base_reg;
                        const arg_count = try self.parseCallArgs(func_reg);
                        try self.proto.emitCall(func_reg, arg_count, 1);
                        base_reg = func_reg; // Result is in func_reg
                    }
                } else if (std.mem.eql(u8, self.current.lexeme, "[")) {
                    self.advance(); // consume '['

                    const key_reg = try self.parseExpr();

                    if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "]"))) {
                        return error.ExpectedCloseBracket;
                    }
                    self.advance(); // consume ']'

                    const dst_reg = self.proto.allocTemp();
                    try self.proto.emitGETTABLE(dst_reg, base_reg, key_reg);
                    base_reg = dst_reg;

                    // Check for function call: t["key"]() or t[k]()
                    if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "(")) {
                        const func_reg = base_reg;
                        const arg_count = try self.parseCallArgs(func_reg);
                        try self.proto.emitCall(func_reg, arg_count, 1);
                        base_reg = func_reg; // Result is in func_reg
                    }
                } else {
                    // Method call: t:method() - returns result
                    self.advance(); // consume ':'

                    if (self.current.kind != .Identifier) {
                        return error.ExpectedIdentifier;
                    }
                    const method_name = self.current.lexeme;
                    self.advance(); // consume method name

                    // Get method from receiver
                    const method_const = try self.proto.addConstString(method_name);
                    const func_reg = self.proto.allocTemp();
                    try self.proto.emitGETFIELD(func_reg, base_reg, method_const);

                    // Reserve slot for receiver and place it there
                    const self_reg = self.proto.allocTemp(); // = func_reg + 1
                    try self.proto.emitMOVE(self_reg, base_reg);

                    // Parse extra arguments starting at func_reg + 2
                    const extra_args = try self.parseMethodArgs(func_reg);

                    // Call with 1 result (expression context)
                    try self.proto.emitCall(func_reg, extra_args + 1, 1);
                    base_reg = func_reg; // Result is in func_reg
                }
            }

            return base_reg;
        }

        return error.ExpectedExpression;
    }

    // parsePow: handles ^ (right-associative, highest precedence binary operator)
    fn parsePow(self: *Parser) ParseError!u8 {
        var left = try self.parseAtom();

        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "^")) {
            self.advance(); // consume '^'
            const right = try self.parsePow(); // right-associative: recursive call

            const dst = self.proto.allocTemp();
            try self.proto.emitPOW(dst, left, right);
            left = dst;
        }

        return left;
    }

    // parsePrimary: handles unary operators (not, -, #)
    fn parsePrimary(self: *Parser) ParseError!u8 {
        // Unary 'not' operator
        if (self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "not")) {
            self.advance(); // consume 'not'
            const operand = try self.parsePrimary(); // recursive for chained: not not x
            const dst = self.proto.allocTemp();
            try self.proto.emitNOT(dst, operand);
            return dst;
        }

        // Unary minus operator
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "-")) {
            self.advance(); // consume '-'
            const operand = try self.parsePrimary(); // recursive for chained: --x
            const dst = self.proto.allocTemp();
            try self.proto.emitUNM(dst, operand);
            return dst;
        }

        // Length operator
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "#")) {
            self.advance(); // consume '#'
            const operand = try self.parsePrimary(); // recursive for chained: ##x
            const dst = self.proto.allocTemp();
            try self.proto.emitLEN(dst, operand);
            return dst;
        }

        // Bitwise NOT operator (unary ~)
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "~")) {
            self.advance(); // consume '~'
            const operand = try self.parsePrimary(); // recursive for chained: ~~x
            const dst = self.proto.allocTemp();
            try self.proto.emitBNOT(dst, operand);
            return dst;
        }

        return try self.parsePow();
    }

    /// Parse table constructor: { [field,]* }
    /// field = Name '=' expr | '[' expr ']' '=' expr | expr
    fn parseTableConstructor(self: *Parser) ParseError!u8 {
        // Consume '{'
        self.advance();

        // Allocate register for table
        const table_reg = self.proto.allocTemp();
        try self.proto.emitNEWTABLE(table_reg);

        // List index counter (Lua arrays start at 1)
        var list_index: u8 = 1;

        // Parse fields until '}'
        while (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "}"))) {
            // Check for indexed field: '[' expr ']' '=' expr
            if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "[")) {
                self.advance(); // consume '['

                const base_reg = self.proto.next_reg;

                // Parse key expression
                const key_reg = try self.parseExpr();

                // Expect ']'
                if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "]"))) {
                    return error.ExpectedCloseBracket;
                }
                self.advance(); // consume ']'

                // Expect '='
                if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "="))) {
                    return error.ExpectedEquals;
                }
                self.advance(); // consume '='

                // Parse value expression
                const value_reg = try self.parseExpr();

                // Emit SETTABLE: table[key] = value
                try self.proto.emitSETTABLE(table_reg, key_reg, value_reg);

                // Free temp registers
                self.proto.next_reg = base_reg;
            } else if (self.current.kind == .Identifier and
                self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "="))
            {
                // Named field: Name '=' expr
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
                // List element: expr (no key, use auto-index)
                const base_reg = self.proto.next_reg;
                const value_reg = try self.parseExpr();

                // Emit SETI: table[index] = value
                try self.proto.emitSETI(table_reg, list_index, value_reg);
                list_index += 1;

                // Free temp registers used by the expression
                self.proto.next_reg = base_reg;
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
                std.mem.eql(u8, self.current.lexeme, "//") or
                std.mem.eql(u8, self.current.lexeme, "%")))
        {
            const op = self.current.lexeme;
            self.advance(); // consume operator
            const right = try self.parsePrimary();

            const dst = self.proto.allocTemp();
            if (std.mem.eql(u8, op, "*")) {
                try self.proto.emitMul(dst, left, right);
            } else if (std.mem.eql(u8, op, "//")) {
                try self.proto.emitIDIV(dst, left, right);
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

    /// Parse bitwise OR: a | b
    fn parseBitOr(self: *Parser) ParseError!u8 {
        var left = try self.parseBitXor();

        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "|")) {
            self.advance(); // consume '|'
            const right = try self.parseBitXor();
            const dst = self.proto.allocTemp();
            try self.proto.emitBOR(dst, left, right);
            left = dst;
        }

        return left;
    }

    /// Parse bitwise XOR: a ~ b (binary)
    fn parseBitXor(self: *Parser) ParseError!u8 {
        var left = try self.parseBitAnd();

        // Note: lexer returns "~" for XOR and "~=" for not-equal as separate tokens
        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "~")) {
            self.advance(); // consume '~'
            const right = try self.parseBitAnd();
            const dst = self.proto.allocTemp();
            try self.proto.emitBXOR(dst, left, right);
            left = dst;
        }

        return left;
    }

    /// Parse bitwise AND: a & b
    fn parseBitAnd(self: *Parser) ParseError!u8 {
        var left = try self.parseShift();

        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "&")) {
            self.advance(); // consume '&'
            const right = try self.parseShift();
            const dst = self.proto.allocTemp();
            try self.proto.emitBAND(dst, left, right);
            left = dst;
        }

        return left;
    }

    /// Parse shift operators: a << b, a >> b
    fn parseShift(self: *Parser) ParseError!u8 {
        var left = try self.parseConcat();

        while (self.current.kind == .Symbol and
            (std.mem.eql(u8, self.current.lexeme, "<<") or
                std.mem.eql(u8, self.current.lexeme, ">>")))
        {
            const op = self.current.lexeme;
            self.advance(); // consume operator
            const right = try self.parseConcat();
            const dst = self.proto.allocTemp();

            if (std.mem.eql(u8, op, "<<")) {
                try self.proto.emitSHL(dst, left, right);
            } else {
                try self.proto.emitSHR(dst, left, right);
            }
            left = dst;
        }

        return left;
    }

    /// Parse string concatenation
    /// Collects all operands first, then emits a single CONCAT instruction
    /// a .. b .. c -> CONCAT(dst, a_reg, c_reg) with operands in consecutive registers
    fn parseConcat(self: *Parser) ParseError!u8 {
        const first = try self.parseAdd();

        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ".."))) {
            return first;
        }

        // Collect all operand registers first
        var operands: [256]u8 = undefined;
        operands[0] = first;
        var count: usize = 1;

        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "..")) {
            self.advance(); // consume '..'
            operands[count] = try self.parseAdd();
            count += 1;
        }

        // Now allocate consecutive registers and copy operands
        const start_reg = self.proto.next_reg;
        for (0..count) |i| {
            const dst = self.proto.allocTemp();
            if (operands[i] != dst) {
                try self.proto.emitMOVE(dst, operands[i]);
            }
        }
        const end_reg = self.proto.next_reg - 1;

        // Emit single CONCAT for all operands
        const result = self.proto.allocTemp();
        try self.proto.emitCONCAT(result, start_reg, end_reg);
        return result;
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
        var left = try self.parseBitOr();

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
            const right = try self.parseBitOr();

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

    /// Parse 'and' expression with short-circuit evaluation
    /// a and b: if a is falsy, return a; otherwise return b
    fn parseAnd(self: *Parser) ParseError!u8 {
        var left = try self.parseCompare();

        while (self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "and")) {
            self.advance(); // consume 'and'

            const dst = self.proto.allocTemp();

            // TESTSET dst, left, false:
            //   if left is falsy (== false): dst := left, continue to JMP -> end
            //   if left is truthy (!= false): skip JMP -> evaluate b
            try self.proto.emitTESTSET(dst, left, false);
            const jmp_addr = try self.proto.emitPatchableJMP();

            // Parse right operand
            const right = try self.parseCompare();
            if (right != dst) {
                try self.proto.emitMOVE(dst, right);
            }

            const end_addr = @as(u32, @intCast(self.proto.code.items.len));
            self.proto.patchJMP(jmp_addr, end_addr);

            left = dst;
        }

        return left;
    }

    /// Parse 'or' expression with short-circuit evaluation
    /// a or b: if a is truthy, return a; otherwise return b
    fn parseOr(self: *Parser) ParseError!u8 {
        var left = try self.parseAnd();

        while (self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "or")) {
            self.advance(); // consume 'or'

            const dst = self.proto.allocTemp();

            // TESTSET dst, left, true:
            //   if left is truthy (== true): dst := left, continue to JMP -> end
            //   if left is falsy (!= true): skip JMP -> evaluate b
            try self.proto.emitTESTSET(dst, left, true);
            const jmp_addr = try self.proto.emitPatchableJMP();

            // Parse right operand
            const right = try self.parseAnd();
            if (right != dst) {
                try self.proto.emitMOVE(dst, right);
            }

            const end_addr = @as(u32, @intCast(self.proto.code.items.len));
            self.proto.patchJMP(jmp_addr, end_addr);

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

        // Track loop for break statements
        self.loop_depth += 1;
        const break_count = self.break_jumps.items.len;

        // Expect variable name
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        const loop_var_name = self.current.lexeme;
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

        // Save locals_top and variables before for loop modifies them
        const saved_locals_top = self.proto.locals_top;
        const saved_var_len = self.proto.variables.items.len;

        // Set next_reg and locals_top past for loop registers (idx, limit, step, user_var)
        // This ensures statements inside the loop don't overwrite loop control registers
        self.proto.next_reg = base_reg + NUMERIC_FOR_REGS;
        self.proto.locals_top = base_reg + NUMERIC_FOR_REGS;

        // Register loop variable (user_var is at base_reg + 3)
        try self.proto.addVariable(loop_var_name, base_reg + 3);

        // Mark for loop body - each iteration resets to this point
        const loop_body_mark = self.proto.markTemps();

        // Parse loop body
        try self.parseStatements();

        // Release loop body temporaries and variables
        self.proto.resetTemps(loop_body_mark);
        self.proto.variables.shrinkRetainingCapacity(saved_var_len);

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

        // Patch all break jumps to after the loop
        const end_addr = @as(u32, @intCast(self.proto.code.items.len));
        for (self.break_jumps.items[break_count..]) |jmp| {
            self.proto.patchJMP(jmp, end_addr);
        }
        self.break_jumps.shrinkRetainingCapacity(break_count);

        self.loop_depth -= 1;
    }

    fn parseWhile(self: *Parser) ParseError!void {
        self.advance(); // consume 'while'

        // Track loop for break statements
        self.loop_depth += 1;
        const break_count = self.break_jumps.items.len;

        // Record loop start address for backward jump
        const loop_start = @as(u32, @intCast(self.proto.code.items.len));

        // Mark registers before condition
        const cond_mark = self.proto.markTemps();

        // Parse condition
        const condition_reg = try self.parseExpr();

        // Expect 'do'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "do"))) {
            return error.ExpectedDo;
        }
        self.advance(); // consume 'do'

        // TEST condition, skip if false
        try self.proto.emitTEST(condition_reg, false);
        const exit_jmp = try self.proto.emitPatchableJMP();

        // Release condition temporaries
        self.proto.resetTemps(cond_mark);

        // Mark for loop body
        const body_mark = self.proto.markTemps();
        try self.proto.enterScope();

        // Parse loop body
        try self.parseStatements();

        // Release loop body scope and temporaries
        self.proto.leaveScope();
        self.proto.resetTemps(body_mark);

        // Expect 'end'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "end"))) {
            return error.ExpectedEnd;
        }
        self.advance(); // consume 'end'

        // Jump back to loop start
        const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(self.proto.code.items.len)) - 1;
        try self.proto.emitJMP(@intCast(back_offset));

        // Patch exit jump and all break jumps to after the loop
        const end_addr = @as(u32, @intCast(self.proto.code.items.len));
        self.proto.patchJMP(exit_jmp, end_addr);

        // Patch all break jumps from this loop
        for (self.break_jumps.items[break_count..]) |jmp| {
            self.proto.patchJMP(jmp, end_addr);
        }
        self.break_jumps.shrinkRetainingCapacity(break_count);

        self.loop_depth -= 1;
    }

    fn parseRepeatUntil(self: *Parser) ParseError!void {
        self.advance(); // consume 'repeat'

        // Track loop for break statements
        self.loop_depth += 1;
        const break_count = self.break_jumps.items.len;

        // Record loop start address
        const loop_start = @as(u32, @intCast(self.proto.code.items.len));

        // Mark for loop body
        const body_mark = self.proto.markTemps();
        try self.proto.enterScope();

        // Parse loop body (stops at 'until')
        try self.parseStatements();

        // Expect 'until'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "until"))) {
            return error.ExpectedUntil;
        }
        self.advance(); // consume 'until'

        // Parse condition (still inside scope so body locals are visible)
        const cond_mark = self.proto.markTemps();
        const condition_reg = try self.parseExpr();

        // TEST: if condition is truthy, skip JMP (exit loop)
        //       if condition is falsy, execute JMP (loop back)
        try self.proto.emitTEST(condition_reg, false);
        const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(self.proto.code.items.len)) - 1;
        try self.proto.emitJMP(@intCast(back_offset));

        // Patch all break jumps to after the loop
        const end_addr = @as(u32, @intCast(self.proto.code.items.len));
        for (self.break_jumps.items[break_count..]) |jmp| {
            self.proto.patchJMP(jmp, end_addr);
        }
        self.break_jumps.shrinkRetainingCapacity(break_count);

        self.loop_depth -= 1;

        // Release condition temporaries and scope
        self.proto.resetTemps(cond_mark);
        self.proto.leaveScope();
        self.proto.resetTemps(body_mark);
    }

    fn parseBreak(self: *Parser) ParseError!void {
        self.advance(); // consume 'break'

        if (self.loop_depth == 0) {
            return error.BreakOutsideLoop;
        }

        // Emit JMP to be patched later at end of loop
        const jmp_addr = try self.proto.emitPatchableJMP();
        try self.break_jumps.append(jmp_addr);
    }

    fn parseStatements(self: *Parser) StatementError!void {
        // Support return statements and nested if/for inside blocks
        while (self.current.kind != .Eof and
            !(self.current.kind == .Keyword and
                (std.mem.eql(u8, self.current.lexeme, "else") or
                    std.mem.eql(u8, self.current.lexeme, "elseif") or
                    std.mem.eql(u8, self.current.lexeme, "end") or
                    std.mem.eql(u8, self.current.lexeme, "until"))))
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
                } else if (std.mem.eql(u8, self.current.lexeme, "while")) {
                    try self.parseWhile();
                } else if (std.mem.eql(u8, self.current.lexeme, "repeat")) {
                    try self.parseRepeatUntil();
                } else if (std.mem.eql(u8, self.current.lexeme, "local")) {
                    try self.parseLocalDecl();
                } else if (std.mem.eql(u8, self.current.lexeme, "do")) {
                    try self.parseDoEnd();
                } else if (std.mem.eql(u8, self.current.lexeme, "break")) {
                    try self.parseBreak();
                } else {
                    return error.UnsupportedStatement;
                }
            } else if (self.current.kind == .Identifier) {
                // Look ahead to see if it's a function call (with parens or no-parens)
                const next = self.peek();
                const is_call_with_parens = next.kind == .Symbol and std.mem.eql(u8, next.lexeme, "(");
                const is_call_no_parens = next.kind == .String or
                    (next.kind == .Symbol and std.mem.eql(u8, next.lexeme, "{"));

                if (is_call_with_parens or is_call_no_parens) {
                    try self.parseGenericFunctionCall();
                } else if (std.mem.eql(u8, self.current.lexeme, "io")) {
                    try self.parseIoCall();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "=")) {
                    // Simple assignment: x = expr
                    try self.parseAssignment();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ".")) {
                    // Check for chained method call: t.a:method() or field assignment
                    try self.parseFieldAccessOrMethodCall();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ":")) {
                    // Method call: t:method()
                    try self.parseMethodCallStatement();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "[")) {
                    // Index assignment: t[key] = expr
                    try self.parseAssignment();
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

        // Check for 'local function' syntax
        if (self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "function")) {
            return self.parseLocalFunction();
        }

        // Parse variable names (comma-separated)
        var var_names: [256][]const u8 = undefined;
        var var_count: u8 = 0;

        // First identifier
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        var_names[var_count] = self.current.lexeme;
        var_count += 1;
        self.advance();

        // Additional identifiers after comma
        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
            self.advance(); // consume ','
            if (self.current.kind != .Identifier) {
                return error.ExpectedIdentifier;
            }
            var_names[var_count] = self.current.lexeme;
            var_count += 1;
            self.advance();
        }

        // Allocate registers for all variables
        const first_reg = self.proto.allocLocalReg();
        var i: u8 = 1;
        while (i < var_count) : (i += 1) {
            _ = self.proto.allocLocalReg();
        }

        // Check for initialization
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "=")) {
            self.advance(); // consume '='

            // Parse initializer expressions (comma-separated)
            var expr_count: u8 = 0;
            var expr_reg = try self.parseExpr();

            // Move first expression to first variable register
            if (expr_reg != first_reg) {
                try self.proto.emitMOVE(first_reg, expr_reg);
            }
            expr_count += 1;

            // Parse remaining expressions
            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
                self.advance(); // consume ','
                expr_reg = try self.parseExpr();

                if (expr_count < var_count) {
                    const target_reg = first_reg + expr_count;
                    if (expr_reg != target_reg) {
                        try self.proto.emitMOVE(target_reg, expr_reg);
                    }
                }
                // If more values than variables, discard extras
                expr_count += 1;
            }

            // Fill remaining variables with nil if fewer values
            if (expr_count < var_count) {
                const nil_start = first_reg + expr_count;
                const nil_count = var_count - expr_count;
                try self.proto.emitLOADNIL(nil_start, nil_count);
            }
        } else {
            // No initializer - initialize all to nil
            try self.proto.emitLOADNIL(first_reg, var_count);
        }

        // Add all variables to scope (visible after initializers)
        i = 0;
        while (i < var_count) : (i += 1) {
            try self.proto.addVariable(var_names[i], first_reg + i);
        }
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

        // Check if it's a local variable (including local functions) or upvalue first
        if (try self.proto.resolveVariable(func_name)) |loc| {
            // Handle local/upvalue function call
            self.advance(); // consume function name

            // Load closure from local register or upvalue
            const func_reg = self.proto.allocTemp();
            switch (loc) {
                .local => |var_reg| try self.proto.emitMOVE(func_reg, var_reg),
                .upvalue => |idx| try self.proto.emitGETUPVAL(func_reg, idx),
            }

            // Parse arguments (handles both parens and no-parens styles)
            const arg_count = try self.parseCallArgs(func_reg);

            // Emit CALL instruction (0 results for statements)
            try self.proto.emitCall(func_reg, arg_count, 0);
            return;
        }

        // Check if it's a global function (defined with 'function name()')
        if (self.proto.findFunction(func_name)) |_| {
            self.advance(); // consume function name

            // Load closure from _ENV[func_name] via GETTABUP
            const func_reg = self.proto.allocTemp();
            const name_const = try self.proto.addConstString(func_name);
            try self.proto.emitGETTABUP(func_reg, 0, name_const);

            // Parse arguments (handles both parens and no-parens styles)
            const arg_count = try self.parseCallArgs(func_reg);

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

        // Load function constant
        const func_reg = self.proto.allocTemp();
        const func_const_idx = try self.proto.addNativeFunc(func_id);
        try self.proto.emitLoadK(func_reg, func_const_idx);

        // Parse arguments (handles both parens and no-parens styles)
        const arg_count = try self.parseCallArgs(func_reg);

        // Emit CALL instruction (0 results for statements)
        try self.proto.emitCall(func_reg, arg_count, 0);
    }

    fn parseFunctionCallExpr(self: *Parser) ParseError!u8 {
        // Parse function call that returns a value
        const func_name = self.current.lexeme;

        // Check if it's a local variable or upvalue (local function, closure)
        if (try self.proto.resolveVariable(func_name)) |loc| {
            return switch (loc) {
                .local => |reg| try self.parseLocalFunctionCall(reg),
                .upvalue => |idx| try self.parseUpvalueFunctionCall(idx),
            };
        }

        // Check if it's a user-defined global function
        if (self.proto.findFunction(func_name)) |_| {
            // Handle user-defined function call with return value
            self.advance(); // consume function name

            // Load closure from _ENV[func_name] via GETTABUP (not creating new closure!)
            const func_reg = self.proto.allocTemp();
            const name_const = try self.proto.addConstString(func_name);
            try self.proto.emitGETTABUP(func_reg, 0, name_const);

            // Parse arguments (handles both parens and no-parens styles)
            const arg_count = try self.parseCallArgs(func_reg);

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

        // Load function constant
        const func_reg = self.proto.allocTemp();
        const func_const_idx = try self.proto.addNativeFunc(func_id);
        try self.proto.emitLoadK(func_reg, func_const_idx);

        // Parse arguments (handles both parens and no-parens styles)
        const arg_count = try self.parseCallArgs(func_reg);

        // Emit CALL instruction (1 result)
        try self.proto.emitCall(func_reg, arg_count, 1);

        // Return the register where the result is stored
        return func_reg;
    }

    /// Parse a function call where the function is stored in a local register
    fn parseLocalFunctionCall(self: *Parser, closure_reg: u8) ParseError!u8 {
        self.advance(); // consume function name

        // Move closure to a temp register for the call
        const func_reg = self.proto.allocTemp();
        try self.proto.emitMOVE(func_reg, closure_reg);

        // Parse arguments (handles both parens and no-parens styles)
        const arg_count = try self.parseCallArgs(func_reg);

        // Emit CALL instruction (1 result)
        try self.proto.emitCall(func_reg, arg_count, 1);

        return func_reg;
    }

    /// Parse a function call where the function is captured as an upvalue
    fn parseUpvalueFunctionCall(self: *Parser, upval_idx: u8) ParseError!u8 {
        self.advance(); // consume function name

        // Load closure from upvalue to a temp register for the call
        const func_reg = self.proto.allocTemp();
        try self.proto.emitGETUPVAL(func_reg, upval_idx);

        // Parse arguments (handles both parens and no-parens styles)
        const arg_count = try self.parseCallArgs(func_reg);

        // Emit CALL instruction (1 result)
        try self.proto.emitCall(func_reg, arg_count, 1);

        return func_reg;
    }

    fn parseExpr(self: *Parser) ParseError!u8 {
        return self.parseOr();
    }

    /// Check if current token starts a no-parens call argument (string or table)
    fn isNoParensArg(self: *Parser) bool {
        return self.current.kind == .String or
            (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "{"));
    }

    /// Parse function call arguments, handling both parenthesized and no-parens styles.
    /// Returns the argument count. func_reg should already be allocated.
    fn parseCallArgs(self: *Parser, func_reg: u8) ParseError!u8 {
        var arg_count: u8 = 0;

        // Check for no-parens call: f "string" or f {table}
        if (self.isNoParensArg()) {
            // Single argument without parentheses
            const arg_reg = try self.parseExpr();
            if (arg_reg != func_reg + 1) {
                try self.proto.emitMOVE(func_reg + 1, arg_reg);
            }
            return 1;
        }

        // Normal call with parentheses
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Parse arguments
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            // Parse first argument
            const arg_reg = try self.parseExpr();
            if (arg_reg != func_reg + 1) {
                try self.proto.emitMOVE(func_reg + 1, arg_reg);
            }
            arg_count = 1;

            // Parse additional arguments
            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
                self.advance(); // consume ','
                const next_arg = try self.parseExpr();
                arg_count += 1;
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

        return arg_count;
    }

    // Special parsing functions

    /// Parse method call statement: t:method(args)
    /// Transforms to: t.method(t, args)
    fn parseMethodCallStatement(self: *Parser) ParseError!void {
        // Load receiver (t) into register
        const receiver_name = self.current.lexeme;
        var receiver_reg: u8 = undefined;

        if (try self.proto.resolveVariable(receiver_name)) |loc| {
            receiver_reg = self.proto.allocTemp();
            switch (loc) {
                .local => |var_reg| try self.proto.emitMOVE(receiver_reg, var_reg),
                .upvalue => |idx| try self.proto.emitGETUPVAL(receiver_reg, idx),
            }
        } else {
            return error.UnsupportedIdentifier;
        }
        self.advance(); // consume receiver name

        // Expect ':'
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ":"))) {
            return error.ExpectedColon;
        }
        self.advance(); // consume ':'

        // Parse method name
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        const method_name = self.current.lexeme;
        self.advance(); // consume method name

        // Get method from receiver: t.method
        const method_const = try self.proto.addConstString(method_name);
        const func_reg = self.proto.allocTemp();
        try self.proto.emitGETFIELD(func_reg, receiver_reg, method_const);

        // Reserve slot for receiver (self) and place it there
        const self_reg = self.proto.allocTemp(); // = func_reg + 1
        try self.proto.emitMOVE(self_reg, receiver_reg);

        // Parse extra arguments starting at func_reg + 2
        const extra_args = try self.parseMethodArgs(func_reg);

        // Total args = receiver + extra args
        try self.proto.emitCall(func_reg, extra_args + 1, 0);
    }

    /// Parse method call arguments (for method calls where receiver is already at func_reg+1)
    /// Places arguments at func_reg+2, func_reg+3, etc. Returns extra argument count.
    fn parseMethodArgs(self: *Parser, func_reg: u8) ParseError!u8 {
        var arg_count: u8 = 0;

        // Check for no-parens call
        if (self.isNoParensArg()) {
            const arg_reg = try self.parseExpr();
            if (arg_reg != func_reg + 2) {
                try self.proto.emitMOVE(func_reg + 2, arg_reg);
            }
            return 1;
        }

        // Expect '('
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Parse arguments
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            const arg_reg = try self.parseExpr();
            // First extra arg goes to func_reg + 2
            if (arg_reg != func_reg + 2) {
                try self.proto.emitMOVE(func_reg + 2, arg_reg);
            }
            arg_count = 1;

            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
                self.advance(); // consume ','
                const next_arg = try self.parseExpr();
                arg_count += 1;
                // Args go to func_reg + 2 + (arg_count - 1) = func_reg + 1 + arg_count
                if (next_arg != func_reg + 1 + arg_count) {
                    try self.proto.emitMOVE(func_reg + 1 + arg_count, next_arg);
                }
            }
        }

        // Expect ')'
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            return error.ExpectedRightParen;
        }
        self.advance(); // consume ')'

        return arg_count;
    }

    /// Parse field access that may end with method call or assignment
    /// Handles: t.a = expr, t.a.b = expr, t.a:method()
    fn parseFieldAccessOrMethodCall(self: *Parser) ParseError!void {
        // Load base table
        const base_name = self.current.lexeme;
        var base_reg: u8 = undefined;

        if (try self.proto.resolveVariable(base_name)) |loc| {
            base_reg = self.proto.allocTemp();
            switch (loc) {
                .local => |var_reg| try self.proto.emitMOVE(base_reg, var_reg),
                .upvalue => |idx| try self.proto.emitGETUPVAL(base_reg, idx),
            }
        } else {
            return error.UnsupportedIdentifier;
        }
        self.advance(); // consume base name

        // Process chain of field accesses
        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ".")) {
            self.advance(); // consume '.'

            if (self.current.kind != .Identifier) {
                return error.ExpectedIdentifier;
            }
            const field_name = self.current.lexeme;
            self.advance(); // consume field name

            // Check what comes next
            if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "=")) {
                // Field assignment: t.field = expr
                self.advance(); // consume '='
                const value_reg = try self.parseExpr();
                const field_const = try self.proto.addConstString(field_name);
                try self.proto.emitSETFIELD(base_reg, field_const, value_reg);
                return;
            } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ":")) {
                // Method call: t.a:method()
                self.advance(); // consume ':'

                // Get the field first (t.a)
                const field_const = try self.proto.addConstString(field_name);
                const receiver_reg = self.proto.allocTemp();
                try self.proto.emitGETFIELD(receiver_reg, base_reg, field_const);

                // Parse method name
                if (self.current.kind != .Identifier) {
                    return error.ExpectedIdentifier;
                }
                const method_name = self.current.lexeme;
                self.advance(); // consume method name

                // Get method from receiver
                const method_const = try self.proto.addConstString(method_name);
                const func_reg = self.proto.allocTemp();
                try self.proto.emitGETFIELD(func_reg, receiver_reg, method_const);

                // Reserve slot for receiver and place it there
                const self_reg = self.proto.allocTemp(); // = func_reg + 1
                try self.proto.emitMOVE(self_reg, receiver_reg);

                // Parse extra arguments
                const extra_args = try self.parseMethodArgs(func_reg);

                try self.proto.emitCall(func_reg, extra_args + 1, 0);
                return;
            } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ".")) {
                // Continue chaining: get this field and continue
                const field_const = try self.proto.addConstString(field_name);
                const next_reg = self.proto.allocTemp();
                try self.proto.emitGETFIELD(next_reg, base_reg, field_const);
                base_reg = next_reg;
                // Loop continues
            } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "[")) {
                // Mixed access: t.field[key] = expr
                // First get the field
                const field_const = try self.proto.addConstString(field_name);
                const table_reg = self.proto.allocTemp();
                try self.proto.emitGETFIELD(table_reg, base_reg, field_const);

                // Parse index
                self.advance(); // consume '['
                const key_reg = try self.parseExpr();

                if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "]"))) {
                    return error.ExpectedCloseBracket;
                }
                self.advance(); // consume ']'

                // Check for more chaining or assignment
                if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "=")) {
                    // Index assignment: t.field[key] = expr
                    self.advance(); // consume '='
                    const value_reg = try self.parseExpr();
                    try self.proto.emitSETTABLE(table_reg, key_reg, value_reg);
                    return;
                } else {
                    // Could support more chaining here, but for now error
                    return error.UnsupportedStatement;
                }
            } else {
                // Unknown pattern after field access
                return error.UnsupportedStatement;
            }
        }

        // If we reach here, it's an error (no = or : found)
        return error.UnsupportedStatement;
    }

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
        var func_builder = ProtoBuilder.init(self.proto.allocator, self.proto);
        defer func_builder.deinit(); // Clean up at end of function

        // Create RawProto container early (address is fixed, content will be filled later)
        const proto_ptr = try self.proto.allocator.create(RawProto);

        // Temporarily add function for recursive calls with unfilled RawProto
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

        // Convert function builder to RawProto with dynamic allocation
        const func_proto_data = try func_builder.toRawProto(self.proto.allocator, param_count);

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

    /// Parse 'local function name(...) ... end'
    /// Equivalent to: local name; name = function(...) ... end
    fn parseLocalFunction(self: *Parser) ParseError!void {
        self.advance(); // consume 'function'

        // Parse function name
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        const func_name = self.current.lexeme;
        self.advance(); // consume function name

        // Allocate local register for this function
        const func_reg = self.proto.allocLocalReg();

        // Parse parameters: (param, ...)
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Create a separate builder for function body with parent reference
        var func_builder = ProtoBuilder.init(self.proto.allocator, self.proto);
        defer func_builder.deinit();

        // Create RawProto container
        const proto_ptr = try self.proto.allocator.create(RawProto);

        // Add function to parent's function list for recursive calls
        try self.proto.addFunction(func_name, proto_ptr);

        // Add function name to local scope NOW (enables recursion via local lookup)
        try self.proto.addVariable(func_name, func_reg);

        // Parse parameters
        var param_count: u8 = 0;
        if (self.current.kind == .Identifier) {
            const param_name = self.current.lexeme;
            self.advance();
            try func_builder.addVariable(param_name, param_count);
            param_count += 1;

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

            func_builder.next_reg = param_count;
            func_builder.locals_top = param_count;
        }

        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            return error.ExpectedRightParen;
        }
        self.advance(); // consume ')'

        // Parse function body
        const old_proto = self.proto;
        self.proto = &func_builder;
        defer self.proto = old_proto;

        try self.parseStatements();

        // Expect 'end'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "end"))) {
            return error.ExpectedEnd;
        }
        self.advance(); // consume 'end'

        // Add implicit RETURN if needed
        if (func_builder.code.items.len == 0 or
            func_builder.code.items[func_builder.code.items.len - 1].getOpCode() != .RETURN)
        {
            try func_builder.emit(.RETURN, 0, 1, 0);
        }

        // Convert to RawProto
        const func_proto_data = try func_builder.toRawProto(self.proto.allocator, param_count);
        proto_ptr.* = func_proto_data;

        // Emit CLOSURE to local register (no SETTABUP - it's local, not global)
        const proto_idx = try old_proto.addProto(proto_ptr);
        try old_proto.emitClosure(func_reg, proto_idx);
    }

    /// Parse anonymous function: function(params) body end
    /// Returns register containing the closure
    fn parseAnonymousFunction(self: *Parser) ParseError!u8 {
        self.advance(); // consume 'function'

        // Allocate register for the closure result
        const func_reg = self.proto.allocTemp();

        // Parse parameters: (param, ...)
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Create a separate builder for function body with parent reference
        var func_builder = ProtoBuilder.init(self.proto.allocator, self.proto);
        defer func_builder.deinit();

        // Create RawProto container
        const proto_ptr = try self.proto.allocator.create(RawProto);

        // Parse parameters
        var param_count: u8 = 0;
        if (self.current.kind == .Identifier) {
            const param_name = self.current.lexeme;
            self.advance();
            try func_builder.addVariable(param_name, param_count);
            param_count += 1;

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

            func_builder.next_reg = param_count;
            func_builder.locals_top = param_count;
        }

        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            return error.ExpectedRightParen;
        }
        self.advance(); // consume ')'

        // Parse function body
        const old_proto = self.proto;
        self.proto = &func_builder;
        defer self.proto = old_proto;

        try self.parseStatements();

        // Expect 'end'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "end"))) {
            return error.ExpectedEnd;
        }
        self.advance(); // consume 'end'

        // Add implicit RETURN if needed
        if (func_builder.code.items.len == 0 or
            func_builder.code.items[func_builder.code.items.len - 1].getOpCode() != .RETURN)
        {
            try func_builder.emit(.RETURN, 0, 1, 0);
        }

        // Convert to RawProto
        const func_proto_data = try func_builder.toRawProto(self.proto.allocator, param_count);
        proto_ptr.* = func_proto_data;

        // Emit CLOSURE instruction
        const proto_idx = try old_proto.addProto(proto_ptr);
        try old_proto.emitClosure(func_reg, proto_idx);

        return func_reg;
    }
};

/// Process escape sequences in a string literal (after quotes are removed).
/// Supports: \n, \t, \r, \\, \", \'
fn processEscapes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    defer result.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => {
                    try result.append('\n');
                    i += 2;
                },
                't' => {
                    try result.append('\t');
                    i += 2;
                },
                'r' => {
                    try result.append('\r');
                    i += 2;
                },
                '\\' => {
                    try result.append('\\');
                    i += 2;
                },
                '"' => {
                    try result.append('"');
                    i += 2;
                },
                '\'' => {
                    try result.append('\'');
                    i += 2;
                },
                else => {
                    // Unknown escape - keep as-is
                    try result.append(input[i]);
                    i += 1;
                },
            }
        } else {
            try result.append(input[i]);
            i += 1;
        }
    }

    return try allocator.dupe(u8, result.items);
}
