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
    ExpectedIn,
    TooManyLoopVariables,
    VarargOutsideVarargFunction,
    InvalidAttribute,
    ExpectedLabel,
    UndefinedLabel,
    AssignToConst,
};

const StatementError = std.mem.Allocator.Error || ParseError;

/// Free a RawProto and all its owned memory
pub fn freeRawProto(allocator: std.mem.Allocator, proto: *RawProto) void {
    allocator.free(proto.code);
    allocator.free(proto.lineinfo);
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
    if (proto.source.len > 0) {
        allocator.free(proto.source);
    }
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
    is_const: bool = false,
};

/// Number of registers used by numeric for loop (idx, limit, step, user_var)
pub const NUMERIC_FOR_REGS: u8 = 4;

/// Marker for scope boundaries (used with enterScope/leaveScope)
const ScopeMark = struct {
    var_len: usize, // variables list rollback point
    locals_top: u8, // register watermark for this scope
};

/// Pending goto that needs to be patched when the label is defined
const PendingGoto = struct {
    name: []const u8, // label name
    code_pos: usize, // position of the JMP instruction to patch
};

pub const ProtoBuilder = struct {
    code: std.ArrayList(Instruction),
    lineinfo: std.ArrayList(u32), // Line number for each instruction
    current_line: u32 = 1, // Current source line being compiled
    source: []const u8 = "", // Source name (e.g., "@file.lua")
    // Type-specific constant arrays (unmaterialized)
    booleans: std.ArrayList(bool),
    integers: std.ArrayList(i64),
    numbers: std.ArrayList(f64),
    strings: std.ArrayList([]const u8),
    native_ids: std.ArrayList(NativeFnId),
    // Ordered constant references
    const_refs: std.ArrayList(ConstRef),
    protos: std.ArrayList(*const RawProto), // Nested function prototypes (for CLOSURE)
    is_vararg: bool = false, // True if function accepts varargs (...)
    maxstacksize: u8,
    next_reg: u8, // Next available register (for temps)
    locals_top: u8, // Register watermark: locals occupy [0, locals_top)
    allocator: std.mem.Allocator,
    functions: std.ArrayList(FunctionEntry),
    variables: std.ArrayList(VariableEntry),
    scope_starts: std.ArrayList(ScopeMark), // Stack of scope boundaries
    upvalues: std.ArrayList(Upvaldesc), // Upvalue descriptors for this function
    parent: ?*ProtoBuilder, // For function scope hierarchy
    // Constant deduplication maps (string content -> const_refs index)
    string_constants: std.StringHashMap(u32),
    // Label tracking for goto support
    labels: std.StringHashMap(usize), // label name -> code position
    pending_gotos: std.ArrayList(PendingGoto), // gotos that need patching

    pub fn init(allocator: std.mem.Allocator, parent: ?*ProtoBuilder) std.mem.Allocator.Error!ProtoBuilder {
        var builder = ProtoBuilder{
            .code = .{},
            .lineinfo = .{},
            .booleans = .{},
            .integers = .{},
            .numbers = .{},
            .strings = .{},
            .native_ids = .{},
            .const_refs = .{},
            .protos = .{},
            .maxstacksize = 0,
            .next_reg = 0,
            .locals_top = 0,
            .allocator = allocator,
            .functions = .{},
            .variables = .{},
            .scope_starts = .{},
            .upvalues = .{},
            .parent = parent,
            .string_constants = std.StringHashMap(u32).init(allocator),
            .labels = std.StringHashMap(usize).init(allocator),
            .pending_gotos = .{},
        };

        // All functions have _ENV as upvalue[0]
        // This ensures GETTABUP with B=0 always accesses _ENV
        if (parent != null) {
            // Nested function: _ENV comes from parent's upvalue[0]
            try builder.upvalues.append(allocator, .{ .instack = false, .idx = 0, .name = "_ENV" });
        } else {
            // Main chunk: _ENV comes from loader (instack=true, idx=0)
            try builder.upvalues.append(allocator, .{ .instack = true, .idx = 0, .name = "_ENV" });
        }

        return builder;
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

        self.code.deinit(self.allocator);
        self.lineinfo.deinit(self.allocator);
        self.booleans.deinit(self.allocator);
        self.integers.deinit(self.allocator);
        self.numbers.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.native_ids.deinit(self.allocator);
        self.const_refs.deinit(self.allocator);
        self.protos.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.variables.deinit(self.allocator);
        self.scope_starts.deinit(self.allocator);
        self.upvalues.deinit(self.allocator);
        self.string_constants.deinit();
        self.labels.deinit();
        self.pending_gotos.deinit(self.allocator);
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
        try self.scope_starts.append(self.allocator, .{
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
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitWithK(self: *ProtoBuilder, op: opcodes.OpCode, a: u8, b: u8, c: u8, k: bool) !void {
        const instr = Instruction.initABCk(op, a, b, c, k);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitExtraArg(self: *ProtoBuilder, ax: u25) !void {
        const instr = Instruction.initAx(.EXTRAARG, ax);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitAdd(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.ADD, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitBAND(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.BAND, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitBOR(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.BOR, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitBXOR(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.BXOR, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitBNOT(self: *ProtoBuilder, dst: u8, src: u8) !void {
        const instr = Instruction.initABC(.BNOT, dst, src, 0);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitSHL(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.SHL, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitSHR(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.SHR, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// Emit CALL instruction. B = nargs + 1, C = nresults + 1
    pub fn emitCall(self: *ProtoBuilder, func_reg: u8, nargs: u8, nresults: u8) !void {
        const instr = Instruction.initABC(.CALL, func_reg, nargs + 1, nresults + 1);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// Emit TAILCALL instruction for tail call optimization
    /// TAILCALL A B C k: return R[A](R[A+1], ..., R[A+B-1])
    pub fn emitTailCall(self: *ProtoBuilder, func_reg: u8, nargs: u8) !void {
        // B = nargs + 1, C = 0 (return all), k = 0 (no TBC close needed here)
        const b: u8 = if (nargs == VARARG_SENTINEL) 0 else nargs + 1;
        const instr = Instruction.initABC(.TAILCALL, func_reg, b, 0);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// Emit CALL with variable args (B=0) or variable results (C=0)
    /// Use VARARG_SENTINEL (255) for nargs or nresults to indicate variable
    pub fn emitCallVararg(self: *ProtoBuilder, func_reg: u8, nargs: u8, nresults: u8) !void {
        const b: u8 = if (nargs == VARARG_SENTINEL) 0 else nargs + 1;
        const c: u8 = if (nresults == VARARG_SENTINEL) 0 else nresults + 1;
        const instr = Instruction.initABC(.CALL, func_reg, b, c);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub const VARARG_SENTINEL: u8 = 255;

    /// Emit PCALL instruction for protected calls.
    /// PCALL A B C: R(A)..R(A+C-2) := pcall(R(A+1), R(A+2)..R(A+B))
    /// On success: R(A) = true, R(A+1...) = return values
    /// On failure: R(A) = false, R(A+1) = error message
    /// result_reg is where the status boolean goes; the function is at result_reg+1
    pub fn emitPcall(self: *ProtoBuilder, result_reg: u8, total_args: u8, total_results: u8) !void {
        // NOTE: PCALL uses direct total counts (function+args, status+values);
        // CALL uses +1 encoding.
        const b: u8 = if (total_args == VARARG_SENTINEL) 0 else total_args;
        const c: u8 = if (total_results == VARARG_SENTINEL) 0 else total_results;
        const instr = Instruction.initABC(.PCALL, result_reg, b, c);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitDiv(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.DIV, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitIDIV(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.IDIV, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitEQ(self: *ProtoBuilder, left: u8, right: u8, negate: u8) !void {
        const instr = Instruction.initABC(.EQ, negate, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitLT(self: *ProtoBuilder, left: u8, right: u8, negate: u8) !void {
        const instr = Instruction.initABC(.LT, negate, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitLE(self: *ProtoBuilder, left: u8, right: u8, negate: u8) !void {
        const instr = Instruction.initABC(.LE, negate, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitFORLOOP(self: *ProtoBuilder, base_reg: u8, jump_target: i17) !void {
        const instr = Instruction.initAsBx(.FORLOOP, base_reg, jump_target);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitFORPREP(self: *ProtoBuilder, base_reg: u8, jump_target: i17) !void {
        const instr = Instruction.initAsBx(.FORPREP, base_reg, jump_target);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitGETTABLE(self: *ProtoBuilder, dst: u8, table: u8, key: u8) !void {
        const instr = Instruction.initABC(.GETTABLE, dst, table, key);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// For large constant indices (>255), loads upvalue to temp and uses LOADK + GETTABLE
    pub fn emitGETTABUP(self: *ProtoBuilder, dst: u8, upval: u8, key_const: u32) !void {
        if (key_const <= 255) {
            const instr = Instruction.initABC(.GETTABUP, dst, upval, @intCast(key_const));
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        } else {
            // Load upvalue to temp, load key to another temp, then GETTABLE
            const upval_temp = self.allocTemp();
            try self.emitGETUPVAL(upval_temp, upval);
            const key_temp = self.allocTemp();
            try self.emitLoadK(key_temp, key_const);
            const instr = Instruction.initABC(.GETTABLE, dst, upval_temp, key_temp);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        }
    }

    /// Emit SETTABUP instruction: UpValue[A][K[B]] := R[C]
    /// For large constant indices (>255), loads upvalue to temp and uses LOADK + SETTABLE
    pub fn emitSETTABUP(self: *ProtoBuilder, upval: u8, key_const: u32, src: u8) !void {
        if (key_const <= 255) {
            const instr = Instruction.initABC(.SETTABUP, upval, @intCast(key_const), src);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        } else {
            // Load upvalue to temp, load key to another temp, then SETTABLE
            const upval_temp = self.allocTemp();
            try self.emitGETUPVAL(upval_temp, upval);
            const key_temp = self.allocTemp();
            try self.emitLoadK(key_temp, key_const);
            const instr = Instruction.initABC(.SETTABLE, upval_temp, key_temp, src);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        }
    }

    pub fn emitJMP(self: *ProtoBuilder, offset: i25) !void {
        const instr = Instruction.initsJ(.JMP, offset);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitLoadK(self: *ProtoBuilder, reg: u8, const_idx: u32) !void {
        const instr = Instruction.initABx(.LOADK, reg, @intCast(const_idx));
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
        self.updateMaxStack(reg + 1);
    }

    /// Emit CLOSURE instruction: R[A] := closure(KPROTO[Bx])
    pub fn emitClosure(self: *ProtoBuilder, reg: u8, proto_idx: u32) !void {
        const instr = Instruction.initABx(.CLOSURE, reg, @intCast(proto_idx));
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
        self.updateMaxStack(reg + 1);
    }

    pub fn emitLOADBOOL(self: *ProtoBuilder, dst: u8, value: bool, skip: bool) !void {
        // Use Lua 5.4 standard opcodes instead of LOADBOOL
        if (value and !skip) {
            const instr = Instruction.initABC(.LOADTRUE, dst, 0, 0);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        } else if (!value and !skip) {
            const instr = Instruction.initABC(.LOADFALSE, dst, 0, 0);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        } else if (!value and skip) {
            const instr = Instruction.initABC(.LFALSESKIP, dst, 0, 0);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        } else {
            // value=true, skip=true: Load true and skip next instruction
            const instr = Instruction.initABC(.LOADTRUE, dst, 0, 0);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
            const skip_instr = Instruction.initsJ(.JMP, 1); // Skip exactly 1 instruction
            try self.code.append(self.allocator, skip_instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        }
    }

    pub fn emitLOADNIL(self: *ProtoBuilder, dst: u8, count: u8) !void {
        const instr = Instruction.initABC(.LOADNIL, dst, count - 1, 0);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
        self.updateMaxStack(dst + count);
    }

    pub fn emitMod(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.MOD, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitMOVE(self: *ProtoBuilder, dst: u8, src: u8) !void {
        const instr = Instruction.initABC(.MOVE, dst, src, 0);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// Emit GETUPVAL instruction: R[A] := UpValue[B]
    pub fn emitGETUPVAL(self: *ProtoBuilder, dst: u8, upval_idx: u8) !void {
        const instr = Instruction.initABC(.GETUPVAL, dst, upval_idx, 0);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
        self.updateMaxStack(dst + 1);
    }

    /// Emit SETUPVAL instruction: UpValue[B] := R[A]
    pub fn emitSETUPVAL(self: *ProtoBuilder, src: u8, upval_idx: u8) !void {
        const instr = Instruction.initABC(.SETUPVAL, src, upval_idx, 0);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// Emit NOT instruction: R[A] := not R[B]
    pub fn emitNOT(self: *ProtoBuilder, dst: u8, src: u8) !void {
        const instr = Instruction.initABC(.NOT, dst, src, 0);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// Emit UNM instruction: R[A] := -R[B]
    pub fn emitUNM(self: *ProtoBuilder, dst: u8, src: u8) !void {
        const instr = Instruction.initABC(.UNM, dst, src, 0);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// Emit LEN instruction: R[A] := #R[B]
    pub fn emitLEN(self: *ProtoBuilder, dst: u8, src: u8) !void {
        const instr = Instruction.initABC(.LEN, dst, src, 0);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// Emit CONCAT instruction: R[A] := R[B] .. ... .. R[C]
    pub fn emitCONCAT(self: *ProtoBuilder, dst: u8, start: u8, end: u8) !void {
        const instr = Instruction.initABC(.CONCAT, dst, start, end);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// Emit NEWTABLE instruction: R[A] := {}
    pub fn emitNEWTABLE(self: *ProtoBuilder, dst: u8) !void {
        const instr = Instruction.initABC(.NEWTABLE, dst, 0, 0);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
        self.updateMaxStack(dst + 1);
    }

    /// Emit SETFIELD instruction: R[A][K[B]] := R[C]
    /// For large constant indices (>255), uses LOADK + SETTABLE instead
    pub fn emitSETFIELD(self: *ProtoBuilder, table: u8, key_const: u32, src: u8) !void {
        if (key_const <= 255) {
            const instr = Instruction.initABC(.SETFIELD, table, @intCast(key_const), src);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        } else {
            // For large constant index, load key into temp register and use SETTABLE
            const temp = self.allocTemp();
            try self.emitLoadK(temp, key_const);
            const instr = Instruction.initABC(.SETTABLE, table, temp, src);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        }
        // Update maxstacksize to include all referenced registers
        self.updateMaxStack(table + 1);
        self.updateMaxStack(src + 1);
    }

    /// Emit SETTABLE instruction: R[A][R[B]] := R[C]
    pub fn emitSETTABLE(self: *ProtoBuilder, table: u8, key: u8, src: u8) !void {
        const instr = Instruction.initABC(.SETTABLE, table, key, src);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
        // Update maxstacksize to include all referenced registers
        self.updateMaxStack(table + 1);
        self.updateMaxStack(key + 1);
        self.updateMaxStack(src + 1);
    }

    /// Emit SETI instruction: R[A][B] := R[C] (B is integer immediate)
    /// For indices > 255, uses LOADI + SETTABLE instead
    pub fn emitSETI(self: *ProtoBuilder, table: u8, index: u32, src: u8) !void {
        if (index <= 255) {
            const instr = Instruction.initABC(.SETI, table, @intCast(index), src);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        } else {
            // For large index, load it into a temp register and use SETTABLE
            const temp = self.allocTemp();
            const index_i17: i17 = @intCast(index);
            const loadi = Instruction.initAsBx(.LOADI, temp, index_i17);
            try self.code.append(self.allocator, loadi);
            try self.lineinfo.append(self.allocator, self.current_line);
            const settable = Instruction.initABC(.SETTABLE, table, temp, src);
            try self.code.append(self.allocator, settable);
            try self.lineinfo.append(self.allocator, self.current_line);
        }
        // Update maxstacksize to include all referenced registers
        self.updateMaxStack(table + 1);
        self.updateMaxStack(src + 1);
    }

    /// Emit GETFIELD instruction: R[A] := R[B][K[C]]
    /// For large constant indices (>255), uses LOADK + GETTABLE instead
    pub fn emitGETFIELD(self: *ProtoBuilder, dst: u8, table: u8, key_const: u32) !void {
        if (key_const <= 255) {
            const instr = Instruction.initABC(.GETFIELD, dst, table, @intCast(key_const));
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        } else {
            // For large constant index, load key into temp register and use GETTABLE
            const temp = self.allocTemp();
            try self.emitLoadK(temp, key_const);
            const instr = Instruction.initABC(.GETTABLE, dst, table, temp);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        }
        self.updateMaxStack(dst + 1);
    }

    /// Emit SELF instruction: R[A+1] := R[B]; R[A] := R[B][K[C]]
    /// Prepares for method call: method goes to R[A], object goes to R[A+1]
    /// For large constant indices (>255), uses MOVE + LOADK + GETTABLE instead
    pub fn emitSELF(self: *ProtoBuilder, dst: u8, obj: u8, method_const: u32) !void {
        if (method_const <= 255) {
            const instr = Instruction.initABC(.SELF, dst, obj, @intCast(method_const));
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        } else {
            // SELF puts obj in R[A+1] and method in R[A]
            // Emulate with: MOVE R[A+1], R[B]; LOADK temp, K[C]; GETTABLE R[A], R[B], temp
            try self.emitMOVE(dst + 1, obj);
            const temp = self.allocTemp();
            try self.emitLoadK(temp, method_const);
            const instr = Instruction.initABC(.GETTABLE, dst, obj, temp);
            try self.code.append(self.allocator, instr);
            try self.lineinfo.append(self.allocator, self.current_line);
        }
        self.updateMaxStack(dst + 2); // SELF uses two registers: dst and dst+1
    }

    pub fn emitMul(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.MUL, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitPOW(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.POW, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitPatchableFORLOOP(self: *ProtoBuilder, base_reg: u8) !u32 {
        const addr = self.code.items.len;
        const instr = Instruction.initAsBx(.FORLOOP, base_reg, 0); // placeholder
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
        return @intCast(addr);
    }

    pub fn emitPatchableFORPREP(self: *ProtoBuilder, base_reg: u8) !u32 {
        const addr = self.code.items.len;
        const instr = Instruction.initAsBx(.FORPREP, base_reg, 0); // placeholder
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
        return @intCast(addr);
    }

    /// Generic for loop: TFORPREP A sBx - jump to TFORCALL
    pub fn emitPatchableTFORPREP(self: *ProtoBuilder, base_reg: u8) !u32 {
        const addr = self.code.items.len;
        const instr = Instruction.initAsBx(.TFORPREP, base_reg, 0); // placeholder
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
        return @intCast(addr);
    }

    /// Generic for loop: TFORCALL A C - call iterator, C = number of loop variables
    pub fn emitTFORCALL(self: *ProtoBuilder, base_reg: u8, nvars: u8) !void {
        const instr = Instruction.initABC(.TFORCALL, base_reg, 0, nvars);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// Generic for loop: TFORLOOP A sBx - check and loop
    pub fn emitPatchableTFORLOOP(self: *ProtoBuilder, base_reg: u8) !u32 {
        const addr = self.code.items.len;
        const instr = Instruction.initAsBx(.TFORLOOP, base_reg, 0); // placeholder
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
        return @intCast(addr);
    }

    pub fn emitPatchableJMP(self: *ProtoBuilder) !u32 {
        const addr = self.code.items.len;
        const instr = Instruction.initsJ(.JMP, 0); // placeholder
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
        return @intCast(addr);
    }

    pub fn emitReturn(self: *ProtoBuilder, reg: u8, count: u8) !void {
        // B = count + 1 (B=1 means 0 values, B=2 means 1 value, etc.)
        const instr = Instruction.initABC(.RETURN, reg, count + 1, 0);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitSub(self: *ProtoBuilder, dst: u8, left: u8, right: u8) !void {
        const instr = Instruction.initABC(.SUB, dst, left, right);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    /// Emit TESTSET instruction: if (R[B].toBoolean() == k) R[A] := R[B] else pc++
    pub fn emitTESTSET(self: *ProtoBuilder, dst: u8, src: u8, k: bool) !void {
        const instr = Instruction.initABCk(.TESTSET, dst, src, 0, k);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
    }

    pub fn emitTEST(self: *ProtoBuilder, reg: u8, condition: bool) !void {
        const k: u8 = if (condition) 1 else 0;
        const instr = Instruction.initABC(.TEST, reg, 0, k);
        try self.code.append(self.allocator, instr);
        try self.lineinfo.append(self.allocator, self.current_line);
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

    /// Patch the C field (number of results) of a CALL instruction
    /// C=0 means variable results, C=n+1 means n results
    pub fn patchCallResults(self: *ProtoBuilder, addr: u32, nresults: u8) void {
        const existing = self.code.items[addr];
        // Recreate instruction with new C value
        const new_c: u8 = nresults + 1; // C encoding: 0 = vararg, n+1 = n results
        const new_instr = Instruction.initABC(existing.getOpCode(), existing.getA(), existing.getB(), new_c);
        self.code.items[addr] = new_instr;
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
                try self.numbers.append(self.allocator, value);
                try self.const_refs.append(self.allocator, .{ .kind = .number, .index = idx });
                return @intCast(self.const_refs.items.len - 1);
            } else {
                // Parse as hex integer with Lua 5.4 wrap semantics (mod 2^64)
                if (std.fmt.parseInt(i64, hex_part, 16)) |value| {
                    const idx: u16 = @intCast(self.integers.items.len);
                    try self.integers.append(self.allocator, value);
                    try self.const_refs.append(self.allocator, .{ .kind = .integer, .index = idx });
                    return @intCast(self.const_refs.items.len - 1);
                } else |_| {
                    if (parseHexIntegerWrap(lexeme)) |value| {
                        const idx: u16 = @intCast(self.integers.items.len);
                        try self.integers.append(self.allocator, value);
                        try self.const_refs.append(self.allocator, .{ .kind = .integer, .index = idx });
                        return @intCast(self.const_refs.items.len - 1);
                    }
                    return error.InvalidNumber;
                }
            }
        }

        // Try parsing as decimal integer first, fall back to float on overflow
        if (std.fmt.parseInt(i64, lexeme, 10)) |value| {
            const idx: u16 = @intCast(self.integers.items.len);
            try self.integers.append(self.allocator, value);
            try self.const_refs.append(self.allocator, .{ .kind = .integer, .index = idx });
            return @intCast(self.const_refs.items.len - 1);
        } else |_| {
            // Try parsing as float (handles both floats and overflowed integers)
            const value = std.fmt.parseFloat(f64, lexeme) catch return error.InvalidNumber;
            const idx: u16 = @intCast(self.numbers.items.len);
            try self.numbers.append(self.allocator, value);
            try self.const_refs.append(self.allocator, .{ .kind = .number, .index = idx });
            return @intCast(self.const_refs.items.len - 1);
        }
    }

    fn parseHexIntegerWrap(lexeme: []const u8) ?i64 {
        if (lexeme.len < 3) return null;
        var idx: usize = 0;
        var neg = false;
        if (lexeme[idx] == '+' or lexeme[idx] == '-') {
            neg = lexeme[idx] == '-';
            idx += 1;
            if (idx >= lexeme.len) return null;
        }
        if (idx + 1 >= lexeme.len) return null;
        if (lexeme[idx] != '0' or (lexeme[idx + 1] != 'x' and lexeme[idx + 1] != 'X')) return null;
        idx += 2;
        if (idx >= lexeme.len) return null;

        var value: u64 = 0;
        while (idx < lexeme.len) : (idx += 1) {
            const c = lexeme[idx];
            const digit: u64 = switch (c) {
                '0'...'9' => @intCast(c - '0'),
                'a'...'f' => @intCast(c - 'a' + 10),
                'A'...'F' => @intCast(c - 'A' + 10),
                else => return null,
            };
            value = (value << 4) | digit;
        }
        if (neg) value = 0 -% value;
        return @bitCast(value);
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
        // Check for existing constant (compile-time deduplication)
        if (self.string_constants.get(lexeme)) |existing_idx| {
            return existing_idx;
        }

        // Add new constant
        const str_idx: u16 = @intCast(self.strings.items.len);
        const duped = try self.allocator.dupe(u8, lexeme);
        try self.strings.append(self.allocator, duped);
        try self.const_refs.append(self.allocator, .{ .kind = .string, .index = str_idx });
        const const_idx: u32 = @intCast(self.const_refs.items.len - 1);

        // Cache for future lookups (use duped string as key for stable reference)
        try self.string_constants.put(duped, const_idx);
        return const_idx;
    }

    pub fn addNativeFunc(self: *ProtoBuilder, native_id: NativeFnId) !u32 {
        // Store native function ID (no GC allocation)
        const idx: u16 = @intCast(self.native_ids.items.len);
        try self.native_ids.append(self.allocator, native_id);
        try self.const_refs.append(self.allocator, .{ .kind = .native_fn, .index = idx });
        return @intCast(self.const_refs.items.len - 1);
    }

    /// Add a nested function prototype for CLOSURE opcode
    pub fn addProto(self: *ProtoBuilder, proto: *const RawProto) !u32 {
        try self.protos.append(self.allocator, proto);
        return @intCast(self.protos.items.len - 1);
    }

    fn updateMaxStack(self: *ProtoBuilder, stack_size: u8) void {
        if (stack_size > self.maxstacksize) {
            self.maxstacksize = stack_size;
        }
    }

    pub fn addFunction(self: *ProtoBuilder, name: []const u8, proto: *RawProto) !void {
        try self.functions.append(self.allocator, FunctionEntry{
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
        try self.variables.append(self.allocator, .{ .name = name, .reg = reg });
    }

    pub fn addConstVariable(self: *ProtoBuilder, name: []const u8, reg: u8) !void {
        try self.variables.append(self.allocator, .{ .name = name, .reg = reg, .is_const = true });
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

    pub fn isVariableConst(self: *ProtoBuilder, name: []const u8) bool {
        // Search in reverse order so inner scope shadows outer
        var i = self.variables.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.variables.items[i];
            if (std.mem.eql(u8, entry.name, name)) {
                return entry.is_const;
            }
        }
        // Check parent scopes for upvalues
        if (self.parent) |parent| {
            return parent.isVariableConst(name);
        }
        return false;
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
                try self.upvalues.append(self.allocator, .{ .instack = true, .idx = reg });
            },
            .upvalue => |idx| {
                // Parent has it as upvalue - capture from parent's upvalues
                try self.upvalues.append(self.allocator, .{ .instack = false, .idx = idx });
            },
        }

        return .{ .upvalue = upval_idx };
    }

    pub fn toRawProto(self: *ProtoBuilder, allocator: std.mem.Allocator, num_params: u8) !RawProto {
        // Always allocate via allocator (even for len=0) to ensure ownership
        const code_slice = try allocator.dupe(Instruction, self.code.items);
        const lineinfo_slice = try allocator.dupe(u32, self.lineinfo.items);
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

        // Duplicate source name
        const source_slice = try allocator.dupe(u8, self.source);

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
            .is_vararg = self.is_vararg,
            .maxstacksize = self.maxstacksize,
            .nups = @intCast(self.upvalues.items.len),
            .upvalues = upvalues_slice,
            .source = source_slice,
            .lineinfo = lineinfo_slice,
        };
    }
};

pub const Parser = struct {
    lexer: *Lexer,
    current: Token,
    proto: *ProtoBuilder,
    break_jumps: std.ArrayList(u32),
    loop_depth: usize,
    /// Error message buffer for detailed parse error reporting
    error_msg: [256]u8 = undefined,
    error_len: usize = 0,

    pub fn init(lx: *Lexer, proto: *ProtoBuilder) Parser {
        var p = Parser{
            .lexer = lx,
            .proto = proto,
            .current = undefined,
            .break_jumps = .{},
            .loop_depth = 0,
        };
        p.advance();
        return p;
    }

    /// Get the error message as a slice (empty if no error)
    pub fn getErrorMsg(self: *const Parser) []const u8 {
        return self.error_msg[0..self.error_len];
    }

    /// Get the current line number (from current token)
    pub fn getCurrentLine(self: *const Parser) u32 {
        return @intCast(self.current.line);
    }

    /// Set error message with format string
    fn setError(self: *Parser, comptime fmt: []const u8, args: anytype) void {
        self.error_len = (std.fmt.bufPrint(&self.error_msg, fmt, args) catch &self.error_msg).len;
    }

    pub fn deinit(self: *Parser) void {
        self.break_jumps.deinit(self.proto.allocator);
    }

    fn advance(self: *Parser) void {
        self.current = self.lexer.nextToken();
        // Update current_line for code emission
        self.proto.current_line = @intCast(self.current.line);
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
            // Skip empty statements (semicolons)
            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ";")) {
                self.advance();
            }
            if (self.current.kind == .Eof) break;

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
                } else if (std.mem.eql(u8, self.current.lexeme, "goto")) {
                    try self.parseGoto();
                } else {
                    return error.UnsupportedStatement;
                }
            } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ":")) {
                // Check for label: ::name::
                if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ":")) {
                    try self.parseLabel();
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
                    _ = try self.parseExpr();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "=")) {
                    // Simple assignment: x = expr
                    try self.parseAssignment();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ",")) {
                    // Multiple assignment: a, b, c = expr, expr, ...
                    try self.parseMultipleAssignment();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ".")) {
                    // Check for chained method call: t.a:method() or field assignment
                    try self.parseFieldAccessOrMethodCall();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ":")) {
                    // Method call: t:method()
                    _ = try self.parseExpr();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "[")) {
                    // Index assignment: t[key] = expr
                    try self.parseAssignment();
                } else {
                    return error.UnsupportedStatement;
                }
            } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "(")) {
                // Lua allows function-call statements whose prefixexp starts with parentheses,
                // e.g. (Message or print)("...")
                _ = try self.parseExpr();
            } else {
                return error.UnsupportedStatement;
            }

            // Release statement temporaries - allows register reuse
            self.proto.resetTemps(stmt_mark);
        }

        // Check for unresolved gotos
        if (self.proto.pending_gotos.items.len > 0) {
            return error.UndefinedLabel;
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
        // Check for return followed by semicolon (bare return)
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ";")) {
            try self.proto.emitReturn(0, 0);
            return;
        }

        // Check for 'return ...' (return all varargs)
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
            if (!self.proto.is_vararg) {
                return error.VarargOutsideVarargFunction;
            }
            self.advance(); // consume '...'
            const reg = self.proto.allocTemp();
            // VARARG with C=0 loads all varargs and sets top
            try self.proto.emit(.VARARG, reg, 0, 0);
            // RETURN with B=0 returns values from reg to top
            try self.proto.emit(.RETURN, reg, 0, 0);
            return;
        }

        // Parse first return value
        const first_reg = try self.parseExpr();
        var count: u8 = 1;

        // Check for tail call optimization: return f(...)
        // If the return is a single function call, convert CALL to TAILCALL
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ","))) {
            // Single return value - check if it was a function call
            if (self.proto.code.items.len > 0) {
                const last_idx = self.proto.code.items.len - 1;
                const last_inst = self.proto.code.items[last_idx];
                if (last_inst.getOpCode() == .CALL) {
                    // Convert CALL to TAILCALL
                    // CALL A B C -> TAILCALL A B 0
                    const a = last_inst.getA();
                    const b = last_inst.getB();
                    self.proto.code.items[last_idx] = Instruction.initABC(.TAILCALL, a, b, 0);
                    return; // TAILCALL handles the return
                }
            }
        }

        // Parse additional return values (comma-separated)
        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
            self.advance(); // consume ','

            // Check for '...' as last return value
            if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
                if (!self.proto.is_vararg) {
                    return error.VarargOutsideVarargFunction;
                }
                self.advance(); // consume '...'
                // Load varargs starting at next register
                const vararg_reg = first_reg + count;
                try self.proto.emit(.VARARG, vararg_reg, 0, 0);
                // RETURN with B=0 returns from first_reg to top
                try self.proto.emit(.RETURN, first_reg, 0, 0);
                return;
            }

            const expr_reg = try self.parseExpr();

            // Values must be in consecutive registers
            const expected_reg = first_reg + count;
            if (expr_reg != expected_reg) {
                try self.proto.emitMOVE(expected_reg, expr_reg);
            }
            count += 1;

            // Check if this is the last expression and it's a function call
            // If so, we need to expand its return values
            if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ","))) {
                // This is the last expression
                if (self.proto.code.items.len > 0) {
                    const last_idx = self.proto.code.items.len - 1;
                    const last_inst = self.proto.code.items[last_idx];
                    if (last_inst.getOpCode() == .CALL) {
                        // Patch CALL to return variable results (C=0)
                        const a = last_inst.getA();
                        const b = last_inst.getB();
                        self.proto.code.items[last_idx] = Instruction.initABC(.CALL, a, b, 0);
                        // RETURN with B=0 returns from first_reg to top
                        try self.proto.emit(.RETURN, first_reg, 0, 0);
                        return;
                    }
                }
            }
        }

        try self.proto.emitReturn(first_reg, count);
    }

    // do ... end block (creates a new scope)
    fn parseDoEnd(self: *Parser) ParseError!void {
        self.advance(); // consume 'do'

        try self.proto.enterScope();
        const scope_base = self.proto.locals_top; // First local of this scope
        try self.parseStatements();

        // Emit CLOSE to close upvalues and TBC variables from this scope
        if (self.proto.locals_top > scope_base) {
            try self.proto.emit(.CLOSE, scope_base, 0, 0);
        }
        self.proto.leaveScope();

        // Expect 'end'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "end"))) {
            return error.ExpectedEnd;
        }
        self.advance(); // consume 'end'
    }

    // Assignment: x = expr, t.field = expr, t.a.b = expr, t[key] = expr, t[1][2] = expr
    fn parseAssignment(self: *Parser) ParseError!void {
        const name = self.current.lexeme;
        self.advance(); // consume identifier

        // Check for field/index access: t.field, t.a.b.c, t[key], t[1][2], t.a[1].b, etc.
        if (self.current.kind == .Symbol and
            (std.mem.eql(u8, self.current.lexeme, ".") or std.mem.eql(u8, self.current.lexeme, "[")))
        {
            // Get the base table
            var table_reg: u8 = undefined;
            if (try self.proto.resolveVariable(name)) |loc| {
                switch (loc) {
                    .local => |reg| table_reg = reg,
                    .upvalue => |idx| {
                        // Upvalue: load table into temp register first
                        table_reg = self.proto.allocTemp();
                        try self.proto.emitGETUPVAL(table_reg, idx);
                    },
                }
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

            // Check for ',' (multiple assignment), '=' (single assignment), or '(' (function call)
            if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
                // Multiple assignment with indexed first target: t[1], a[1] = ...
                // Build the first target and delegate to multiple assignment handler
                const first_target: AssignTarget = if (last_key_const) |kc|
                    .{ .field = .{ .table_reg = table_reg, .field_const = kc } }
                else if (last_key_reg) |kr|
                    .{ .index = .{ .table_reg = table_reg, .key_reg = kr } }
                else
                    return error.ExpectedEquals;

                return self.parseMultipleAssignmentWithFirstTarget(first_target);
            } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "=")) {
                self.advance(); // consume '='

                const value_reg = try self.parseExpr();

                // Emit SET instruction for the final key
                if (last_key_const) |kc| {
                    try self.proto.emitSETFIELD(table_reg, kc, value_reg);
                } else if (last_key_reg) |kr| {
                    try self.proto.emitSETTABLE(table_reg, kr, value_reg);
                }
            } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "(")) {
                // Function call: t[key]() or t.field[key]() etc.
                // First, get the function from the table
                const func_reg = self.proto.allocTemp();
                if (last_key_const) |kc| {
                    try self.proto.emitGETFIELD(func_reg, table_reg, kc);
                } else if (last_key_reg) |kr| {
                    try self.proto.emitGETTABLE(func_reg, table_reg, kr);
                } else {
                    return error.ExpectedEquals;
                }

                // Parse arguments and emit call
                const arg_count = try self.parseCallArgs(func_reg);
                try self.proto.emitCallVararg(func_reg, arg_count, 0);
            } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ":")) {
                // Method call on indexed value: t[key]:method()
                // First, get the receiver from the table
                const receiver_reg = self.proto.allocTemp();
                if (last_key_const) |kc| {
                    try self.proto.emitGETFIELD(receiver_reg, table_reg, kc);
                } else if (last_key_reg) |kr| {
                    try self.proto.emitGETTABLE(receiver_reg, table_reg, kr);
                } else {
                    return error.ExpectedEquals;
                }

                self.advance(); // consume ':'

                // Parse method name
                if (self.current.kind != .Identifier) {
                    return error.ExpectedIdentifier;
                }
                const method_name = self.current.lexeme;
                self.advance(); // consume method name

                // Use SELF: R[func_reg] := R[receiver_reg][K[method_const]]
                //           R[func_reg+1] := R[receiver_reg]
                const method_const = try self.proto.addConstString(method_name);
                const func_reg = self.proto.allocTemp();
                _ = self.proto.allocTemp(); // Reserve for self (SELF writes to A+1)
                try self.proto.emitSELF(func_reg, receiver_reg, method_const);

                // Parse extra arguments
                const extra_args = try self.parseMethodArgs(func_reg);

                try self.proto.emitCall(func_reg, extra_args + 1, 0);
            } else {
                return error.ExpectedEquals;
            }
        } else {
            // Simple assignment: x = expr
            // Expect '='
            if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "="))) {
                return error.ExpectedEquals;
            }
            self.advance(); // consume '='

            // Check for const variable assignment
            if (self.proto.isVariableConst(name)) {
                self.setError("attempt to assign to const variable '{s}'", .{name});
                return error.AssignToConst;
            }

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

    /// Target type for multiple assignment
    const AssignTarget = union(enum) {
        /// Simple variable (local, upvalue, or global)
        variable: []const u8,
        /// Field access: table.field (table_reg, field_const)
        field: struct { table_reg: u8, field_const: u32 },
        /// Index access: table[key] (table_reg, key_reg)
        index: struct { table_reg: u8, key_reg: u8 },
    };

    /// Parse multiple assignment: a, b, c = expr, expr, ...
    /// Also handles indexed targets: t[1], a.x = expr, expr
    fn parseMultipleAssignment(self: *Parser) ParseError!void {
        // Collect all targets
        var targets: [256]AssignTarget = undefined;
        var target_count: u8 = 0;

        // Parse first target (already at current token which is an identifier)
        targets[target_count] = try self.parseAssignTarget();
        target_count += 1;

        // Parse remaining targets after commas
        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
            self.advance(); // consume ','
            if (self.current.kind != .Identifier) {
                return error.ExpectedIdentifier;
            }
            targets[target_count] = try self.parseAssignTarget();
            target_count += 1;
        }

        // Check for const variable assignments
        for (targets[0..target_count]) |target| {
            if (target == .variable) {
                const var_name = target.variable;
                if (self.proto.isVariableConst(var_name)) {
                    self.setError("attempt to assign to const variable '{s}'", .{var_name});
                    return error.AssignToConst;
                }
            }
        }

        // Expect '='
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "="))) {
            return error.ExpectedEquals;
        }
        self.advance(); // consume '='

        // Allocate temp registers for all values
        const first_temp = self.proto.allocTemp();
        var i: u8 = 1;
        while (i < target_count) : (i += 1) {
            _ = self.proto.allocTemp();
        }

        // Parse expressions
        var expr_count: u8 = 0;
        var expr_reg = try self.parseExpr();

        // Move first expression to first temp
        if (expr_reg != first_temp) {
            try self.proto.emitMOVE(first_temp, expr_reg);
        }
        expr_count += 1;

        // Parse remaining expressions
        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
            self.advance(); // consume ','
            expr_reg = try self.parseExpr();

            if (expr_count < target_count) {
                const target_reg = first_temp + expr_count;
                if (expr_reg != target_reg) {
                    try self.proto.emitMOVE(target_reg, expr_reg);
                }
            }
            expr_count += 1;
        }

        // Handle multiple return values from single function call
        var handled_multi_return = false;
        if (expr_count == 1 and target_count > 1) {
            if (self.proto.code.items.len > 0) {
                var call_idx: ?usize = null;
                var call_func_reg: u8 = 0;
                const last_idx = self.proto.code.items.len - 1;
                const last_inst = self.proto.code.items[last_idx];

                if (last_inst.getOpCode() == .CALL) {
                    call_idx = last_idx;
                    call_func_reg = last_inst.a;
                } else {
                    var scan = last_idx;
                    var removed_trailing_move = false;
                    while (true) {
                        const inst = self.proto.code.items[scan];
                        if (inst.getOpCode() == .CALL) {
                            call_idx = scan;
                            call_func_reg = inst.a;
                            if (removed_trailing_move) _ = self.proto.code.pop();
                            break;
                        }
                        if (inst.getOpCode() != .MOVE) break;
                        if (!removed_trailing_move and scan == last_idx) removed_trailing_move = true;
                        if (scan == 0) break;
                        scan -= 1;
                    }
                }

                if (call_idx) |idx| {
                    // Adjust CALL to return target_count results
                    self.proto.code.items[idx].c = target_count + 1;

                    // Move results from call_func_reg to first_temp...
                    var vi: u8 = 0;
                    while (vi < target_count) : (vi += 1) {
                        const src = call_func_reg + vi;
                        const dst = first_temp + vi;
                        if (src != dst) {
                            try self.proto.emitMOVE(dst, src);
                        }
                    }
                    handled_multi_return = true;
                }
            }
        }

        // Fill remaining temps with nil if fewer values
        if (expr_count < target_count and !handled_multi_return) {
            const nil_start = first_temp + expr_count;
            const nil_count = target_count - expr_count;
            try self.proto.emitLOADNIL(nil_start, nil_count);
        }

        // Now assign from temps to actual targets
        i = 0;
        while (i < target_count) : (i += 1) {
            const target = targets[i];
            const value_reg = first_temp + i;

            switch (target) {
                .variable => |var_name| {
                    if (try self.proto.resolveVariable(var_name)) |loc| {
                        switch (loc) {
                            .local => |local_reg| {
                                if (local_reg != value_reg) {
                                    try self.proto.emitMOVE(local_reg, value_reg);
                                }
                            },
                            .upvalue => |idx| try self.proto.emitSETUPVAL(value_reg, idx),
                        }
                    } else {
                        // Global variable
                        const name_const = try self.proto.addConstString(var_name);
                        try self.proto.emitSETTABUP(0, name_const, value_reg);
                    }
                },
                .field => |f| {
                    try self.proto.emitSETFIELD(f.table_reg, f.field_const, value_reg);
                },
                .index => |idx| {
                    try self.proto.emitSETTABLE(idx.table_reg, idx.key_reg, value_reg);
                },
            }
        }
    }

    /// Parse a single assignment target (variable, field, or index)
    fn parseAssignTarget(self: *Parser) ParseError!AssignTarget {
        const base_name = self.current.lexeme;
        self.advance(); // consume identifier

        // Check for field or index access
        if (self.current.kind == .Symbol and
            (std.mem.eql(u8, self.current.lexeme, ".") or std.mem.eql(u8, self.current.lexeme, "[")))
        {
            // Load base table
            var table_reg: u8 = undefined;
            if (try self.proto.resolveVariable(base_name)) |loc| {
                switch (loc) {
                    .local => |reg| table_reg = reg,
                    .upvalue => |idx| {
                        table_reg = self.proto.allocTemp();
                        try self.proto.emitGETUPVAL(table_reg, idx);
                    },
                }
            } else {
                table_reg = self.proto.allocTemp();
                const name_const = try self.proto.addConstString(base_name);
                try self.proto.emitGETTABUP(table_reg, 0, name_const);
            }

            // Parse field chain until we hit ',' or '='
            var last_is_field = false;
            var last_field_const: u32 = 0;
            var last_key_reg: u8 = 0;

            while (self.current.kind == .Symbol) {
                if (std.mem.eql(u8, self.current.lexeme, ".")) {
                    // Navigate to field first if we have a pending access
                    if (last_is_field) {
                        const next_reg = self.proto.allocTemp();
                        try self.proto.emitGETFIELD(next_reg, table_reg, last_field_const);
                        table_reg = next_reg;
                    } else if (last_key_reg != 0) {
                        const next_reg = self.proto.allocTemp();
                        try self.proto.emitGETTABLE(next_reg, table_reg, last_key_reg);
                        table_reg = next_reg;
                        last_key_reg = 0;
                    }

                    self.advance(); // consume '.'
                    if (self.current.kind != .Identifier) {
                        return error.ExpectedIdentifier;
                    }
                    last_field_const = try self.proto.addConstString(self.current.lexeme);
                    last_is_field = true;
                    self.advance(); // consume field name
                } else if (std.mem.eql(u8, self.current.lexeme, "[")) {
                    // Navigate to field first if we have a pending access
                    if (last_is_field) {
                        const next_reg = self.proto.allocTemp();
                        try self.proto.emitGETFIELD(next_reg, table_reg, last_field_const);
                        table_reg = next_reg;
                        last_is_field = false;
                    } else if (last_key_reg != 0) {
                        const next_reg = self.proto.allocTemp();
                        try self.proto.emitGETTABLE(next_reg, table_reg, last_key_reg);
                        table_reg = next_reg;
                    }

                    self.advance(); // consume '['
                    last_key_reg = try self.parseExpr();
                    last_is_field = false;

                    if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "]"))) {
                        return error.ExpectedCloseBracket;
                    }
                    self.advance(); // consume ']'
                } else {
                    break;
                }
            }

            // Return the final target
            if (last_is_field) {
                return .{ .field = .{ .table_reg = table_reg, .field_const = last_field_const } };
            } else {
                return .{ .index = .{ .table_reg = table_reg, .key_reg = last_key_reg } };
            }
        }

        // Simple variable
        return .{ .variable = base_name };
    }

    /// Parse multiple assignment when the first target has already been parsed
    /// Used when parseAssignment encounters ',' after an indexed target
    fn parseMultipleAssignmentWithFirstTarget(self: *Parser, first_target: AssignTarget) ParseError!void {
        var targets: [256]AssignTarget = undefined;
        var target_count: u8 = 0;

        // Store the first target
        targets[target_count] = first_target;
        target_count += 1;

        // Parse remaining targets after commas
        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
            self.advance(); // consume ','
            if (self.current.kind != .Identifier) {
                return error.ExpectedIdentifier;
            }
            targets[target_count] = try self.parseAssignTarget();
            target_count += 1;
        }

        // Check for const variable assignments
        for (targets[0..target_count]) |target| {
            if (target == .variable) {
                const var_name = target.variable;
                if (self.proto.isVariableConst(var_name)) {
                    self.setError("attempt to assign to const variable '{s}'", .{var_name});
                    return error.AssignToConst;
                }
            }
        }

        // Expect '='
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "="))) {
            return error.ExpectedEquals;
        }
        self.advance(); // consume '='

        // Allocate temp registers for all values
        const first_temp = self.proto.allocTemp();
        var i: u8 = 1;
        while (i < target_count) : (i += 1) {
            _ = self.proto.allocTemp();
        }

        // Parse expressions
        var expr_count: u8 = 0;
        var expr_reg = try self.parseExpr();

        // Move first expression to first temp
        if (expr_reg != first_temp) {
            try self.proto.emitMOVE(first_temp, expr_reg);
        }
        expr_count += 1;

        // Parse remaining expressions
        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
            self.advance(); // consume ','
            expr_reg = try self.parseExpr();

            if (expr_count < target_count) {
                const target_reg = first_temp + expr_count;
                if (expr_reg != target_reg) {
                    try self.proto.emitMOVE(target_reg, expr_reg);
                }
            }
            expr_count += 1;
        }

        // Fill remaining temps with nil if fewer values
        if (expr_count < target_count) {
            const nil_start = first_temp + expr_count;
            const nil_count = target_count - expr_count;
            try self.proto.emitLOADNIL(nil_start, nil_count);
        }

        // Now assign from temps to actual targets
        i = 0;
        while (i < target_count) : (i += 1) {
            const target = targets[i];
            const value_reg = first_temp + i;

            switch (target) {
                .variable => |var_name| {
                    if (try self.proto.resolveVariable(var_name)) |loc| {
                        switch (loc) {
                            .local => |local_reg| {
                                if (local_reg != value_reg) {
                                    try self.proto.emitMOVE(local_reg, value_reg);
                                }
                            },
                            .upvalue => |idx| try self.proto.emitSETUPVAL(value_reg, idx),
                        }
                    } else {
                        // Global variable
                        const name_const = try self.proto.addConstString(var_name);
                        try self.proto.emitSETTABUP(0, name_const, value_reg);
                    }
                },
                .field => |f| {
                    try self.proto.emitSETFIELD(f.table_reg, f.field_const, value_reg);
                },
                .index => |idx| {
                    try self.proto.emitSETTABLE(idx.table_reg, idx.key_reg, value_reg);
                },
            }
        }
    }

    // Expression parsing (precedence order: Atom -> Pow -> Primary -> Mul -> Add -> Compare)
    // parseAtom: literals, parentheses, table constructors, identifiers
    fn parseAtom(self: *Parser) ParseError!u8 {
        // Vararg expression: ...
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
            if (!self.proto.is_vararg) {
                return error.VarargOutsideVarargFunction;
            }
            self.advance(); // consume '...'
            const reg = self.proto.allocTemp();
            // VARARG A C: load varargs into R[A]...
            // C=2 means load 1 value (C-1=1)
            try self.proto.emit(.VARARG, reg, 0, 2);
            return reg;
        }

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
            // Lua semantic: (f()) forces single return value
            // If the inner expression was a function call:
            // 1. Patch CALL to return exactly 1 result (C=2)
            // 2. Emit barrier MOVEs to prevent parseMultipleAssignment from expanding the CALL
            if (self.proto.code.items.len > 0) {
                const last_idx = self.proto.code.items.len - 1;
                const last_inst = self.proto.code.items[last_idx];
                if (last_inst.getOpCode() == .CALL) {
                    const a = last_inst.getA();
                    const b = last_inst.getB();
                    // Patch CALL to return exactly 1 result (C=2)
                    self.proto.code.items[last_idx] = Instruction.initABC(.CALL, a, b, 2);
                    // Emit two MOVEs as barrier (parseMultipleAssignment looks through one MOVE)
                    const barrier_reg = self.proto.allocTemp();
                    try self.proto.emitMOVE(barrier_reg, a);
                    const final_reg = self.proto.allocTemp();
                    try self.proto.emitMOVE(final_reg, barrier_reg);
                    return try self.parseSuffixChain(final_reg);
                }
            }
            return try self.parseSuffixChain(result);
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
                var content_start = start;
                if (content_start < end) {
                    if (lexeme[content_start] == '\n') {
                        content_start += 1;
                    } else if (lexeme[content_start] == '\r') {
                        content_start += 1;
                        if (content_start < end and lexeme[content_start] == '\n') content_start += 1;
                    }
                }
                const str_content = lexeme[content_start..end];
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
                const result_reg = try self.parseFunctionCallExpr();
                return try self.parseSuffixChain(result_reg);
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
                // Fall back to global lookup via GETTABUP
                // This handles global tables like `table`, `string`, `io`, `_G`, etc.
                base_reg = self.proto.allocTemp();
                const name_const = try self.proto.addConstString(var_name);
                try self.proto.emitGETTABUP(base_reg, 0, name_const);
                self.advance();
            }

            return try self.parseSuffixChain(base_reg);
        }

        return error.ExpectedExpression;
    }

    /// Parse suffixes for a prefix expression: calls, field/index access, and method calls.
    fn parseSuffixChain(self: *Parser, base_reg: u8) ParseError!u8 {
        var reg = base_reg;

        while (true) {
            if ((self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "(")) or
                self.isNoParensArg())
            {
                const arg_count = try self.parseCallArgs(reg);
                try self.proto.emitCallVararg(reg, arg_count, 1);
                continue;
            }

            if (!(self.current.kind == .Symbol and
                (std.mem.eql(u8, self.current.lexeme, ".") or
                    std.mem.eql(u8, self.current.lexeme, "[") or
                    (std.mem.eql(u8, self.current.lexeme, ":") and
                        !(self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ":"))))))
            {
                break;
            }

            if (std.mem.eql(u8, self.current.lexeme, ".")) {
                self.advance(); // consume '.'

                if (self.current.kind != .Identifier) {
                    return error.ExpectedIdentifier;
                }

                const field_name = self.current.lexeme;
                self.advance(); // consume field name

                const key_const = try self.proto.addConstString(field_name);
                const dst_reg = self.proto.allocTemp();
                try self.proto.emitGETFIELD(dst_reg, reg, key_const);
                reg = dst_reg;

                // Check for function call: t.g()
                if ((self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "(")) or
                    self.isNoParensArg())
                {
                    const func_reg = reg;
                    const arg_count = try self.parseCallArgs(func_reg);
                    try self.proto.emitCallVararg(func_reg, arg_count, 1);
                    reg = func_reg;
                }
            } else if (std.mem.eql(u8, self.current.lexeme, "[")) {
                self.advance(); // consume '['

                const key_reg = try self.parseExpr();

                if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "]"))) {
                    return error.ExpectedCloseBracket;
                }
                self.advance(); // consume ']'

                const dst_reg = self.proto.allocTemp();
                try self.proto.emitGETTABLE(dst_reg, reg, key_reg);
                reg = dst_reg;

                // Check for function call: t["key"]() or t[k]()
                if ((self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "(")) or
                    self.isNoParensArg())
                {
                    const func_reg = reg;
                    const arg_count = try self.parseCallArgs(func_reg);
                    try self.proto.emitCallVararg(func_reg, arg_count, 1);
                    reg = func_reg;
                }
            } else {
                // Method call: t:method() - returns result
                self.advance(); // consume ':'

                if (self.current.kind != .Identifier) {
                    return error.ExpectedIdentifier;
                }
                const method_name = self.current.lexeme;
                self.advance(); // consume method name

                // Use SELF: R[func_reg] := R[reg][K[method_const]]
                //           R[func_reg+1] := R[reg]
                const method_const = try self.proto.addConstString(method_name);
                const func_reg = self.proto.allocTemp();
                _ = self.proto.allocTemp(); // Reserve for self (SELF writes to A+1)
                try self.proto.emitSELF(func_reg, reg, method_const);

                // Parse extra arguments starting at func_reg + 2
                const extra_args = try self.parseMethodArgs(func_reg);

                // Call with 1 result (expression context)
                try self.proto.emitCall(func_reg, extra_args + 1, 1);
                reg = func_reg;
            }
        }

        return reg;
    }

    // parsePow: handles ^ (right-associative, highest precedence binary operator)
    fn parsePow(self: *Parser) ParseError!u8 {
        var left = try self.parseAtom();

        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "^")) {
            self.advance(); // consume '^'
            const right = try self.parsePowRight(); // use parsePowRight for right operand

            const dst = self.proto.allocTemp();
            try self.proto.emitPOW(dst, left, right);
            left = dst;
        }

        return left;
    }

    // parsePowRight: handles right operand of ^ which can include unary operators
    // This allows 2^-3 to be parsed as 2^(-3)
    fn parsePowRight(self: *Parser) ParseError!u8 {
        // Unary 'not' operator
        if (self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "not")) {
            self.advance();
            const operand = try self.parsePowRight();
            const dst = self.proto.allocTemp();
            try self.proto.emitNOT(dst, operand);
            return dst;
        }

        // Unary minus operator
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "-")) {
            self.advance();
            const operand = try self.parsePowRight();
            const dst = self.proto.allocTemp();
            try self.proto.emitUNM(dst, operand);
            return dst;
        }

        // Length operator
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "#")) {
            self.advance();
            const operand = try self.parsePowRight();
            const dst = self.proto.allocTemp();
            try self.proto.emitLEN(dst, operand);
            return dst;
        }

        // Bitwise NOT operator (unary ~)
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "~")) {
            self.advance();
            const operand = try self.parsePowRight();
            const dst = self.proto.allocTemp();
            try self.proto.emitBNOT(dst, operand);
            return dst;
        }

        // Otherwise, parse atom and check for chained ^
        var left = try self.parseAtom();

        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "^")) {
            self.advance();
            const right = try self.parsePowRight();
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
        var list_index: u32 = 1;

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
            } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
                // Vararg expansion: {...} includes all varargs
                if (!self.proto.is_vararg) {
                    return error.VarargOutsideVarargFunction;
                }
                self.advance(); // consume '...'

                // Emit VARARG with C=0 to load all varargs starting at table_reg+1
                const vararg_start = table_reg + 1;
                try self.proto.emit(.VARARG, vararg_start, 0, 0);

                // Emit SETLIST with k=1 to indicate offset mode
                // EXTRAARG contains the starting index (list_index)
                // When k=1: start_index = EXTRAARG value (not (C-1)*50+1)
                try self.proto.emitWithK(.SETLIST, table_reg, 0, 0, true);
                try self.proto.emitExtraArg(@intCast(list_index));

                // After vararg expansion, no more list elements expected
                // (vararg should be last in constructor)
            } else {
                // List element: expr (no key, use auto-index)
                const base_reg = self.proto.next_reg;
                const value_reg = try self.parseExpr();

                // Check if this is the last element and if the last instruction was a CALL
                // If so, we need to handle multi-return expansion
                // Last element check: either at '}' or at separator followed by '}'
                const is_last_element = if (self.current.kind == .Symbol)
                    std.mem.eql(u8, self.current.lexeme, "}") or
                        ((std.mem.eql(u8, self.current.lexeme, ",") or
                            std.mem.eql(u8, self.current.lexeme, ";")) and
                            self.peek().kind == .Symbol and
                            std.mem.eql(u8, self.peek().lexeme, "}"))
                else
                    false;

                if (is_last_element and self.proto.code.items.len > 0) {
                    const last_instr = self.proto.code.items[self.proto.code.items.len - 1];
                    const last_op = last_instr.getOpCode();
                    if (last_op == .CALL) {
                        const a = last_instr.getA();
                        // Only use variable-result optimization if CALL register
                        // is immediately after table_reg. For indexed calls like
                        // op[2](...), intermediate registers are used and SETLIST
                        // would copy wrong values.
                        if (a == table_reg + 1) {
                            // Patch CALL to return variable results (C=0)
                            const b = last_instr.getB();
                            self.proto.code.items[self.proto.code.items.len - 1] =
                                Instruction.initABC(.CALL, a, b, 0);

                            // Use SETLIST to assign all return values starting at list_index
                            try self.proto.emitWithK(.SETLIST, table_reg, 0, 0, true);
                            try self.proto.emitExtraArg(@intCast(list_index));

                            // Consume trailing separator if present (e.g., "f();}" or "f(),}")
                            if (self.current.kind == .Symbol and
                                (std.mem.eql(u8, self.current.lexeme, ",") or
                                    std.mem.eql(u8, self.current.lexeme, ";")))
                            {
                                self.advance(); // consume separator
                            }

                            // Don't increment list_index - SETLIST handles variable count
                            self.proto.next_reg = base_reg;
                            break; // Exit loop since this is the last element
                        }
                    }
                }

                // Normal case: emit SETI for single value
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

    /// Parse a single string literal into a register.
    fn parseStringLiteral(self: *Parser) ParseError!u8 {
        if (self.current.kind != .String) return error.ExpectedExpression;
        const reg = self.proto.allocTemp();
        const lexeme = self.current.lexeme;

        if (lexeme.len >= 2 and lexeme[0] == '[') {
            var level: usize = 0;
            var i: usize = 1;
            while (i < lexeme.len and lexeme[i] == '=') {
                level += 1;
                i += 1;
            }
            const start = 2 + level;
            const end = lexeme.len - 2 - level;
            var content_start = start;
            if (content_start < end) {
                if (lexeme[content_start] == '\n') {
                    content_start += 1;
                } else if (lexeme[content_start] == '\r') {
                    content_start += 1;
                    if (content_start < end and lexeme[content_start] == '\n') content_start += 1;
                }
            }
            const str_content = lexeme[content_start..end];
            const k = try self.proto.addConstString(str_content);
            try self.proto.emitLoadK(reg, k);
        } else {
            const str_raw = lexeme[1 .. lexeme.len - 1];
            const str_content = try processEscapes(self.proto.allocator, str_raw);
            defer self.proto.allocator.free(str_content);
            const k = try self.proto.addConstString(str_content);
            try self.proto.emitLoadK(reg, k);
        }

        self.advance();
        return reg;
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
                std.mem.eql(u8, self.current.lexeme, "~=") or
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
            } else if (std.mem.eql(u8, op, "!=") or std.mem.eql(u8, op, "~=")) {
                // For != or ~=: if not equal then set true, else set false
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
        var else_jumps: std.ArrayList(u32) = .{};
        defer else_jumps.deinit(self.proto.allocator);

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
            try else_jumps.append(self.proto.allocator, jump_to_end);
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

        // Expect first variable name
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        const first_var_name = self.current.lexeme;
        self.advance(); // consume identifier

        // Check what follows to determine loop type
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "=")) {
            // Numeric for loop: for var = start, limit[, step] do ... end
            try self.parseNumericFor(first_var_name, break_count);
        } else if ((self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) or
            (self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "in")))
        {
            // Generic for loop: for var1[, var2, ...] in explist do ... end
            try self.parseGenericFor(first_var_name, break_count);
        } else {
            return error.ExpectedEquals;
        }

        self.loop_depth -= 1;
    }

    fn parseNumericFor(self: *Parser, loop_var_name: []const u8, break_count: usize) ParseError!void {
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

        // Close upvalues for the loop variable before FORLOOP
        // This ensures closures capture the value, not the register
        try self.proto.emit(.CLOSE, base_reg + 3, 0, 0);

        // FORLOOP: increment and check, jump back if continuing
        const forloop_addr = try self.proto.emitPatchableFORLOOP(base_reg);

        // Patch FORPREP to jump to FORLOOP if initial condition fails
        self.proto.patchFORInstr(forprep_addr, forloop_addr);

        // Patch FORLOOP to jump back to loop start
        self.proto.patchFORInstr(forloop_addr, loop_start);

        // Close upvalues when loop exits (after FORLOOP falls through)
        try self.proto.emit(.CLOSE, base_reg + 3, 0, 0);

        // Patch all break jumps to after the loop
        const end_addr = @as(u32, @intCast(self.proto.code.items.len));
        for (self.break_jumps.items[break_count..]) |jmp| {
            self.proto.patchJMP(jmp, end_addr);
        }
        self.break_jumps.shrinkRetainingCapacity(break_count);
    }

    /// Generic for loop: for var1[, var2, ...] in explist do ... end
    /// Register layout:
    ///   R(A): iterator function
    ///   R(A+1): state
    ///   R(A+2): control variable
    ///   R(A+3), R(A+4), ...: loop variables (var1, var2, ...)
    fn parseGenericFor(self: *Parser, first_var_name: []const u8, break_count: usize) ParseError!void {
        // Collect loop variable names
        var var_names: [8][]const u8 = undefined;
        var var_count: u8 = 1;
        var_names[0] = first_var_name;

        // Parse additional variable names (comma-separated)
        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
            self.advance(); // consume ','
            if (self.current.kind != .Identifier) {
                return error.ExpectedIdentifier;
            }
            if (var_count >= 8) {
                return error.TooManyLoopVariables;
            }
            var_names[var_count] = self.current.lexeme;
            var_count += 1;
            self.advance(); // consume identifier
        }

        // Expect 'in'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "in"))) {
            return error.ExpectedIn;
        }
        self.advance(); // consume 'in'

        // Allocate base register for iterator state
        const base_reg = self.proto.allocTemp();
        _ = self.proto.allocTemp(); // state
        _ = self.proto.allocTemp(); // control

        // Record code position before parsing expression
        const code_before = self.proto.code.items.len;

        // Parse iterator expression (e.g., pairs(t) or ipairs(t))
        // The expression should return: iterator function, state, initial control value
        const expr_reg = try self.parseExpr();

        // Check if last instruction was a CALL (or trailing MOVE after CALL)
        // and patch it to return 3 values.
        if (self.proto.code.items.len > code_before) {
            const last_idx = self.proto.code.items.len - 1;
            const last_instr = self.proto.code.items[last_idx];
            var call_idx_opt: ?usize = null;
            if (last_instr.getOpCode() == .CALL) {
                call_idx_opt = last_idx;
            } else if (last_instr.getOpCode() == .MOVE and last_idx > code_before) {
                const prev_idx = last_idx - 1;
                if (self.proto.code.items[prev_idx].getOpCode() == .CALL) {
                    call_idx_opt = prev_idx;
                }
            }
            if (call_idx_opt) |call_idx| {
                self.proto.patchCallResults(@intCast(call_idx), 3);
            }
        }

        // Move iterator results to proper positions
        // The call should have put results at expr_reg, expr_reg+1, expr_reg+2
        if (expr_reg != base_reg) {
            try self.proto.emitMOVE(base_reg, expr_reg);
            try self.proto.emitMOVE(base_reg + 1, expr_reg + 1);
            try self.proto.emitMOVE(base_reg + 2, expr_reg + 2);
        }

        // Expect 'do'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "do"))) {
            return error.ExpectedDo;
        }
        self.advance(); // consume 'do'

        // TFORPREP: jump to TFORCALL
        const tforprep_addr = try self.proto.emitPatchableTFORPREP(base_reg);

        // Loop body starts here
        const loop_start = @as(u32, @intCast(self.proto.code.items.len));

        // Save locals_top and variables
        const saved_locals_top = self.proto.locals_top;
        const saved_var_len = self.proto.variables.items.len;

        // Set next_reg past the control registers and loop variables
        // Generic for uses: base(iter), base+1(state), base+2(control), base+3..(vars)
        const GENERIC_FOR_BASE_REGS: u8 = 3; // iter, state, control
        self.proto.next_reg = base_reg + GENERIC_FOR_BASE_REGS + var_count;
        self.proto.locals_top = base_reg + GENERIC_FOR_BASE_REGS + var_count;

        // Register loop variables (at base_reg + 3, base_reg + 4, ...)
        var i: u8 = 0;
        while (i < var_count) : (i += 1) {
            try self.proto.addVariable(var_names[i], base_reg + GENERIC_FOR_BASE_REGS + i);
        }

        // Mark for loop body
        const loop_body_mark = self.proto.markTemps();

        // Parse loop body
        try self.parseStatements();

        // Release temporaries and variables
        self.proto.resetTemps(loop_body_mark);
        self.proto.variables.shrinkRetainingCapacity(saved_var_len);
        self.proto.locals_top = saved_locals_top;
        self.proto.next_reg = saved_locals_top;

        // Expect 'end'
        if (!(self.current.kind == .Keyword and std.mem.eql(u8, self.current.lexeme, "end"))) {
            return error.ExpectedEnd;
        }
        self.advance(); // consume 'end'

        // Close upvalues for loop variables before TFORCALL (end of iteration)
        try self.proto.emit(.CLOSE, base_reg + GENERIC_FOR_BASE_REGS, 0, 0);

        // TFORCALL: call iterator and store results
        const tforcall_addr = @as(u32, @intCast(self.proto.code.items.len));
        try self.proto.emitTFORCALL(base_reg, var_count);

        // TFORLOOP: check first result and loop back
        const tforloop_addr = try self.proto.emitPatchableTFORLOOP(base_reg);

        // Patch TFORPREP to jump to TFORCALL
        self.proto.patchFORInstr(tforprep_addr, tforcall_addr);

        // Patch TFORLOOP to jump back to loop start
        self.proto.patchFORInstr(tforloop_addr, loop_start);

        // Close upvalues when loop exits (after TFORLOOP falls through)
        try self.proto.emit(.CLOSE, base_reg + GENERIC_FOR_BASE_REGS, 0, 0);

        // Patch all break jumps to after the loop
        const end_addr = @as(u32, @intCast(self.proto.code.items.len));
        for (self.break_jumps.items[break_count..]) |jmp| {
            self.proto.patchJMP(jmp, end_addr);
        }
        self.break_jumps.shrinkRetainingCapacity(break_count);
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
        try self.break_jumps.append(self.proto.allocator, jmp_addr);
    }

    /// Parse 'goto label' statement
    fn parseGoto(self: *Parser) ParseError!void {
        self.advance(); // consume 'goto'

        // Expect label name
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        const label_name = self.current.lexeme;
        self.advance(); // consume label name

        // Check if label is already defined
        if (self.proto.labels.get(label_name)) |target_pos| {
            // Backward jump - emit JMP directly
            const current_pos = self.proto.code.items.len;
            const offset = @as(i32, @intCast(target_pos)) - @as(i32, @intCast(current_pos)) - 1;
            try self.proto.emitJMP(@intCast(offset));
        } else {
            // Forward jump - emit placeholder JMP and record for patching
            const jmp_addr = try self.proto.emitPatchableJMP();
            try self.proto.pending_gotos.append(self.proto.allocator, .{
                .name = label_name,
                .code_pos = jmp_addr,
            });
        }
    }

    /// Parse '::label::' label definition
    fn parseLabel(self: *Parser) ParseError!void {
        self.advance(); // consume first ':'
        self.advance(); // consume second ':'

        // Expect label name
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        const label_name = self.current.lexeme;
        self.advance(); // consume label name

        // Expect closing '::'
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ":"))) {
            return error.ExpectedLabel;
        }
        self.advance(); // consume ':'
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ":"))) {
            return error.ExpectedLabel;
        }
        self.advance(); // consume ':'

        // Record label position
        const label_pos = self.proto.code.items.len;
        try self.proto.labels.put(label_name, label_pos);

        // Patch any pending gotos to this label
        var i: usize = 0;
        while (i < self.proto.pending_gotos.items.len) {
            const pending = self.proto.pending_gotos.items[i];
            if (std.mem.eql(u8, pending.name, label_name)) {
                // Patch the JMP instruction
                self.proto.patchJMP(@intCast(pending.code_pos), @intCast(label_pos));
                // Remove from pending list (swap remove)
                _ = self.proto.pending_gotos.swapRemove(i);
            } else {
                i += 1;
            }
        }
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
            // Skip empty statements (semicolons)
            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ";")) {
                self.advance();
            }
            // Re-check loop condition after consuming semicolons
            if (self.current.kind == .Eof or
                (self.current.kind == .Keyword and
                    (std.mem.eql(u8, self.current.lexeme, "else") or
                        std.mem.eql(u8, self.current.lexeme, "elseif") or
                        std.mem.eql(u8, self.current.lexeme, "end") or
                        std.mem.eql(u8, self.current.lexeme, "until")))) break;

            // Mark registers before each statement
            const stmt_mark = self.proto.markTemps();

            if (self.current.kind == .Keyword) {
                if (std.mem.eql(u8, self.current.lexeme, "return")) {
                    try self.parseReturn();
                    // Skip optional trailing semicolons after return
                    while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ";")) {
                        self.advance();
                    }
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
                } else if (std.mem.eql(u8, self.current.lexeme, "goto")) {
                    try self.parseGoto();
                } else if (std.mem.eql(u8, self.current.lexeme, "function")) {
                    try self.parseFunctionDefinition();
                } else {
                    return error.UnsupportedStatement;
                }
            } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ":")) {
                // Check for label: ::name::
                if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ":")) {
                    try self.parseLabel();
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
                    _ = try self.parseExpr();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "=")) {
                    // Simple assignment: x = expr
                    try self.parseAssignment();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ",")) {
                    // Multiple assignment: a, b, c = expr, expr, ...
                    try self.parseMultipleAssignment();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ".")) {
                    // Check for chained method call: t.a:method() or field assignment
                    try self.parseFieldAccessOrMethodCall();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, ":")) {
                    // Method call: t:method()
                    _ = try self.parseExpr();
                } else if (self.peek().kind == .Symbol and std.mem.eql(u8, self.peek().lexeme, "[")) {
                    // Index assignment: t[key] = expr
                    try self.parseAssignment();
                } else {
                    return error.UnsupportedStatement;
                }
            } else if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "(")) {
                // Lua allows function-call statements whose prefixexp starts with parentheses,
                // e.g. (Message or print)("...")
                _ = try self.parseExpr();
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

        // Parse variable names (comma-separated) with optional <close>/<const> attribute
        var var_names: [256][]const u8 = undefined;
        var var_is_close: [256]bool = undefined;
        var var_is_const: [256]bool = undefined;
        var var_count: u8 = 0;

        // First identifier
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        var_names[var_count] = self.current.lexeme;
        var_is_close[var_count] = false;
        var_is_const[var_count] = false;
        self.advance();

        // Check for <close>/<const> attribute
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "<")) {
            self.advance(); // consume '<'
            if (self.current.kind == .Identifier and std.mem.eql(u8, self.current.lexeme, "close")) {
                var_is_close[var_count] = true;
                var_is_const[var_count] = true; // close variables are also const
                self.advance(); // consume 'close'
                if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ">"))) {
                    return error.ExpectedCloseBracket;
                }
                self.advance(); // consume '>'
            } else if (self.current.kind == .Identifier and std.mem.eql(u8, self.current.lexeme, "const")) {
                var_is_const[var_count] = true;
                self.advance(); // consume 'const'
                if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ">"))) {
                    return error.ExpectedCloseBracket;
                }
                self.advance(); // consume '>'
            } else {
                // Unknown attribute
                const attr_name = if (self.current.kind == .Identifier) self.current.lexeme else "?";
                self.setError("unknown attribute '{s}'", .{attr_name});
                return error.InvalidAttribute;
            }
        }
        var_count += 1;

        // Additional identifiers after comma (note: <close>/<const> only valid for single variable)
        while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
            self.advance(); // consume ','
            if (self.current.kind != .Identifier) {
                return error.ExpectedIdentifier;
            }
            var_names[var_count] = self.current.lexeme;
            var_is_close[var_count] = false;
            var_is_const[var_count] = false;
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

            // Handle multiple return values: if single expression assigns to multiple vars,
            // adjust the last CALL/PCALL instruction's nresults to match var_count
            var handled_multi_return = false;
            if (expr_count == 1 and var_count > 1) {
                // Find the CALL or PCALL instruction (may be last or before a MOVE)
                if (self.proto.code.items.len > 0) {
                    var call_idx: ?usize = null;
                    var call_func_reg: u8 = 0;
                    const last_idx = self.proto.code.items.len - 1;
                    const last_inst = self.proto.code.items[last_idx];

                    const is_call = last_inst.getOpCode() == .CALL or last_inst.getOpCode() == .PCALL;
                    if (is_call) {
                        call_idx = last_idx;
                        call_func_reg = last_inst.a;
                    } else {
                        var scan = last_idx;
                        var removed_trailing_move = false;
                        while (true) {
                            const inst = self.proto.code.items[scan];
                            const scan_is_call = inst.getOpCode() == .CALL or inst.getOpCode() == .PCALL;
                            if (scan_is_call) {
                                call_idx = scan;
                                call_func_reg = inst.a;
                                if (removed_trailing_move) _ = self.proto.code.pop();
                                break;
                            }
                            if (inst.getOpCode() != .MOVE) break;
                            if (!removed_trailing_move and scan == last_idx) removed_trailing_move = true;
                            if (scan == 0) break;
                            scan -= 1;
                        }
                    }

                    if (call_idx) |idx| {
                        // Adjust CALL/PCALL to return var_count results
                        self.proto.code.items[idx].c = var_count + 1;

                        // Emit MOVEs to copy results from call_func_reg to first_reg...
                        var vi: u8 = 0;
                        while (vi < var_count) : (vi += 1) {
                            const src = call_func_reg + vi;
                            const dst = first_reg + vi;
                            if (src != dst) {
                                try self.proto.emitMOVE(dst, src);
                            }
                        }
                        handled_multi_return = true;
                    }
                }
            }

            // Fill remaining variables with nil if fewer values
            // (only if we didn't handle multiple returns from a function call)
            if (expr_count < var_count and !handled_multi_return) {
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
            if (var_is_const[i]) {
                try self.proto.addConstVariable(var_names[i], first_reg + i);
            } else {
                try self.proto.addVariable(var_names[i], first_reg + i);
            }
        }

        // Emit TBC opcode for close variables
        i = 0;
        while (i < var_count) : (i += 1) {
            if (var_is_close[i]) {
                try self.proto.emit(.TBC, first_reg + i, 0, 0);
            }
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
            try self.proto.emitCallVararg(func_reg, arg_count, 0);
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

            try self.proto.emitCallVararg(func_reg, arg_count, 0);
            return;
        }

        // Fall back to global lookup via GETTABUP for any unresolved function
        // This handles builtin functions like assert, setmetatable, getmetatable, etc.
        self.advance(); // consume function name

        const func_reg = self.proto.allocTemp();
        const name_const = try self.proto.addConstString(func_name);
        try self.proto.emitGETTABUP(func_reg, 0, name_const);

        // Parse arguments (handles both parens and no-parens styles)
        const arg_count = try self.parseCallArgs(func_reg);

        // Emit CALL instruction (0 results for statements)
        try self.proto.emitCallVararg(func_reg, arg_count, 0);
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

            // Emit CALL instruction (1 result, or variable args if last arg was multi-return call)
            try self.proto.emitCallVararg(func_reg, arg_count, 1);

            // Return the register where the result is stored
            return func_reg;
        }

        // Special handling for pcall - emits PCALL opcode
        if (std.mem.eql(u8, func_name, "pcall")) {
            return self.parsePcallExpr();
        }

        // Fall back to global lookup via GETTABUP for any unresolved function
        // This handles builtin functions like assert, setmetatable, getmetatable, etc.
        self.advance(); // consume function name

        const func_reg = self.proto.allocTemp();
        const name_const = try self.proto.addConstString(func_name);
        try self.proto.emitGETTABUP(func_reg, 0, name_const);

        // Parse arguments (handles both parens and no-parens styles)
        const arg_count = try self.parseCallArgs(func_reg);

        // Emit CALL instruction (1 result, or variable args if last arg was multi-return call)
        try self.proto.emitCallVararg(func_reg, arg_count, 1);

        // Return the register where the result is stored
        return func_reg;
    }

    /// Parse pcall(f, ...) and emit PCALL opcode
    /// PCALL layout: R(A) = status, R(A+1) = function, R(A+2...) = args
    fn parsePcallExpr(self: *Parser) ParseError!u8 {
        self.advance(); // consume "pcall"

        // Allocate result register - this is where the status boolean will go
        // Arguments will be placed at result_reg+1, result_reg+2, etc.
        const result_reg = self.proto.allocTemp();

        // parseCallArgs expects func_reg and places args at func_reg+1, func_reg+2...
        // For PCALL: result_reg = status, result_reg+1 = function, result_reg+2... = args
        // So we pass result_reg as "func_reg" and it places pcall's arguments correctly
        const total_args = try self.parseCallArgs(result_reg);

        // Emit PCALL instruction
        // nresults = 2 means status + 1 return value (typical usage)
        // Use VARARG_SENTINEL for variable results if caller wants multiple
        try self.proto.emitPcall(result_reg, total_args, 2);

        // Return the result register (where status boolean is stored)
        // Note: caller may need to handle multiple return values
        return result_reg;
    }

    /// Parse a function call where the function is stored in a local register
    fn parseLocalFunctionCall(self: *Parser, closure_reg: u8) ParseError!u8 {
        self.advance(); // consume function name

        // Move closure to a temp register for the call
        const func_reg = self.proto.allocTemp();
        try self.proto.emitMOVE(func_reg, closure_reg);

        // Parse arguments (handles both parens and no-parens styles)
        const arg_count = try self.parseCallArgs(func_reg);

        // Emit CALL instruction (1 result, or variable args if last arg was multi-return call)
        try self.proto.emitCallVararg(func_reg, arg_count, 1);

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

        // Emit CALL instruction (1 result, or variable args if last arg was multi-return call)
        try self.proto.emitCallVararg(func_reg, arg_count, 1);

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
    /// Returns the argument count (0 means variable - use vm.top).
    /// func_reg should already be allocated.
    fn parseCallArgs(self: *Parser, func_reg: u8) ParseError!u8 {
        var arg_count: u8 = 0;
        var last_was_call = false;
        var last_was_vararg = false;

        // Check for no-parens call: f "string" or f {table}
        if (self.isNoParensArg()) {
            // Single argument without parentheses
            const arg_reg = if (self.current.kind == .String)
                try self.parseStringLiteral()
            else
                try self.parseTableConstructor();
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
            // Check for vararg as first/only argument: f(...)
            if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
                if (!self.proto.is_vararg) {
                    return error.VarargOutsideVarargFunction;
                }
                self.advance(); // consume '...'
                // Emit VARARG with C=0 to load all varargs starting at func_reg+1
                try self.proto.emit(.VARARG, func_reg + 1, 0, 0);
                last_was_vararg = true;
            } else {
                // Parse first argument
                const code_len_before = self.proto.code.items.len;
                const arg_reg = try self.parseExpr();
                if (arg_reg != func_reg + 1) {
                    try self.proto.emitMOVE(func_reg + 1, arg_reg);
                }
                arg_count = 1;
                // Check if this argument resulted in a CALL instruction
                last_was_call = self.proto.code.items.len > code_len_before and
                    self.proto.code.items[self.proto.code.items.len - 1].getOpCode() == .CALL;
            }

            // Parse additional arguments
            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
                self.advance(); // consume ','

                // Check for vararg as last argument: f(a, b, ...)
                if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
                    if (!self.proto.is_vararg) {
                        return error.VarargOutsideVarargFunction;
                    }
                    self.advance(); // consume '...'
                    // Emit VARARG with C=0 to load all varargs starting at func_reg+arg_count+1
                    try self.proto.emit(.VARARG, func_reg + arg_count + 1, 0, 0);
                    last_was_vararg = true;
                    break; // ... must be last argument
                }

                const code_len_before2 = self.proto.code.items.len;
                const next_arg = try self.parseExpr();
                arg_count += 1;
                if (next_arg != func_reg + arg_count) {
                    try self.proto.emitMOVE(func_reg + arg_count, next_arg);
                }
                // Check if this (last) argument resulted in a CALL instruction
                last_was_call = self.proto.code.items.len > code_len_before2 and
                    self.proto.code.items[self.proto.code.items.len - 1].getOpCode() == .CALL;
            }
        }

        // Expect ')'
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            return error.ExpectedRightParen;
        }
        self.advance(); // consume ')'

        // If last argument was vararg, return VARARG_SENTINEL for variable argument count
        if (last_was_vararg) {
            return ProtoBuilder.VARARG_SENTINEL;
        }

        // If the last argument was a function call, modify it to return all values
        // and return VARARG_SENTINEL to indicate variable argument count (B=0 in CALL)
        if (last_was_call and arg_count > 1 and self.proto.code.items.len > 0) {
            // Find the CALL instruction (might be last, or before a MOVE)
            var call_idx = self.proto.code.items.len - 1;
            if (self.proto.code.items[call_idx].getOpCode() == .MOVE and call_idx > 0) {
                call_idx -= 1;
            }
            if (self.proto.code.items[call_idx].getOpCode() == .CALL) {
                // Change C to 0 (variable returns)
                self.proto.code.items[call_idx].c = 0;
                // Return VARARG_SENTINEL to indicate variable argument count
                return ProtoBuilder.VARARG_SENTINEL;
            }
        }

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
            // Fall back to global lookup via GETTABUP
            receiver_reg = self.proto.allocTemp();
            const name_const = try self.proto.addConstString(receiver_name);
            try self.proto.emitGETTABUP(receiver_reg, 0, name_const);
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

        // Use SELF: R[func_reg] := R[receiver_reg][K[method_const]]
        //           R[func_reg+1] := R[receiver_reg]
        const method_const = try self.proto.addConstString(method_name);
        const func_reg = self.proto.allocTemp();
        _ = self.proto.allocTemp(); // Reserve for self (SELF writes to A+1)
        try self.proto.emitSELF(func_reg, receiver_reg, method_const);

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
            // Fall back to global lookup via GETTABUP
            base_reg = self.proto.allocTemp();
            const name_const = try self.proto.addConstString(base_name);
            try self.proto.emitGETTABUP(base_reg, 0, name_const);
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

                // Use SELF: R[func_reg] := R[receiver_reg][K[method_const]]
                //           R[func_reg+1] := R[receiver_reg]
                const method_const = try self.proto.addConstString(method_name);
                const func_reg = self.proto.allocTemp();
                _ = self.proto.allocTemp(); // Reserve for self (SELF writes to A+1)
                try self.proto.emitSELF(func_reg, receiver_reg, method_const);

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
            } else if ((self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "(")) or
                self.isNoParensArg())
            {
                // Function call: t.field(args) - e.g., table.insert(t, v)
                const field_const = try self.proto.addConstString(field_name);
                const func_reg = self.proto.allocTemp();
                try self.proto.emitGETFIELD(func_reg, base_reg, field_const);

                // Parse arguments and emit call (keep 1 result so chained suffixes like
                // io.input():close() can continue in statement context)
                const arg_count = try self.parseCallArgs(func_reg);
                try self.proto.emitCallVararg(func_reg, arg_count, 1);
                _ = try self.parseSuffixChain(func_reg);
                return;
            } else {
                // Unknown pattern after field access
                return error.UnsupportedStatement;
            }
        }

        // If we reach here, it's an error (no = or : found)
        return error.UnsupportedStatement;
    }

    fn parseIoCall(self: *Parser) ParseError!void {
        // Parse "io.<method>(...)" calls (io.write, io.input, io.output, etc.)
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

        // Expect method name (any io method)
        if (self.current.kind != .Identifier) {
            return error.UnsupportedStatement;
        }
        const method_name = self.current.lexeme;
        self.advance(); // consume method name

        // Expect '('
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Generate bytecode for io.<method> call
        // Get io table from global
        const io_reg = self.proto.allocTemp();
        const io_key_const = try self.proto.addConstString("io");
        try self.proto.emitGETTABUP(io_reg, 0, io_key_const);

        // Get method from io table
        const method_reg = self.proto.allocTemp();
        const method_key_const = try self.proto.addConstString(method_name);
        try self.proto.emitLoadK(method_reg, method_key_const);

        // Get io.<method> function
        const func_reg = self.proto.allocTemp();
        try self.proto.emitGETTABLE(func_reg, io_reg, method_reg);

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
        // function t.field(param) ... end  -- equivalent to t.field = function(param) ... end
        // function t:method(param) ... end -- equivalent to t.method = function(self, param) ... end
        self.advance(); // consume 'function'

        // Parse function name (possibly with . or : chain)
        if (self.current.kind != .Identifier) {
            return error.ExpectedIdentifier;
        }
        const base_name = self.current.lexeme;
        const base_const = try self.proto.addConstString(base_name);
        self.advance(); // consume base name

        // Check for field access chain (t.a.b.c) or method (t:m)
        var is_method = false;
        var field_names: [64][]const u8 = undefined;
        var field_count: usize = 0;

        while (self.current.kind == .Symbol) {
            if (std.mem.eql(u8, self.current.lexeme, ".")) {
                self.advance(); // consume '.'
                if (self.current.kind != .Identifier) {
                    return error.ExpectedIdentifier;
                }
                field_names[field_count] = self.current.lexeme;
                field_count += 1;
                self.advance(); // consume field name
            } else if (std.mem.eql(u8, self.current.lexeme, ":")) {
                self.advance(); // consume ':'
                if (self.current.kind != .Identifier) {
                    return error.ExpectedIdentifier;
                }
                field_names[field_count] = self.current.lexeme;
                field_count += 1;
                is_method = true;
                self.advance(); // consume method name
                break; // ':' must be last in the chain
            } else {
                break;
            }
        }

        // Parse parameters: (param)
        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "("))) {
            return error.ExpectedLeftParen;
        }
        self.advance(); // consume '('

        // Create a separate builder for function body with parent reference
        var func_builder = try ProtoBuilder.init(self.proto.allocator, self.proto);
        defer func_builder.deinit(); // Clean up at end of function

        // Create RawProto container early (address is fixed, content will be filled later)
        const proto_ptr = try self.proto.allocator.create(RawProto);

        // Temporarily add function for recursive calls with unfilled RawProto
        // Use the full qualified name for lookup (base.field1.field2 or base)
        try self.proto.addFunction(base_name, proto_ptr);

        // Parse parameters and assign to registers
        var param_count: u8 = 0;

        // For method syntax (t:method), add implicit 'self' parameter
        if (is_method) {
            try func_builder.addVariable("self", param_count);
            param_count += 1;
        }

        // Check for vararg-only function: function(...)
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
            func_builder.is_vararg = true;
            self.advance(); // consume '...'
        } else if (self.current.kind == .Identifier) {
            // Parse first parameter
            const param_name = self.current.lexeme;
            self.advance();

            // Parameters start at register 0 in function scope
            try func_builder.addVariable(param_name, param_count);
            param_count += 1;

            // Parse additional parameters
            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
                self.advance(); // consume ','
                // Check for vararg: function(a, b, ...)
                if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
                    func_builder.is_vararg = true;
                    self.advance(); // consume '...'
                    break;
                }
                if (self.current.kind != .Identifier) {
                    return error.ExpectedIdentifier;
                }
                const next_param = self.current.lexeme;
                self.advance();

                try func_builder.addVariable(next_param, param_count);
                param_count += 1;
            }
        }

        // Parameters (including implicit self) occupy registers 0..param_count-1
        func_builder.next_reg = param_count;
        func_builder.locals_top = param_count;

        if (!(self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ")"))) {
            return error.ExpectedRightParen;
        }
        self.advance(); // consume ')'

        // Emit VARARGPREP for vararg functions
        if (func_builder.is_vararg) {
            try func_builder.emit(.VARARGPREP, param_count, 0, 0);
        }

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
        // Now emit CLOSURE to create the function
        const closure_reg = old_proto.allocTemp();
        const proto_idx = try old_proto.addProto(proto_ptr);
        try old_proto.emitClosure(closure_reg, proto_idx);

        // Store the closure based on how the function was defined
        if (field_count == 0) {
            // Simple function: function name() -> name = closure
            // First check if there's a local or upvalue with this name
            if (try old_proto.resolveVariable(base_name)) |loc| {
                switch (loc) {
                    .local => |local_reg| {
                        // Local found - store to local variable
                        try old_proto.emitMOVE(local_reg, closure_reg);
                    },
                    .upvalue => |uv_idx| {
                        // Upvalue found - store to upvalue
                        try old_proto.emit(.SETUPVAL, closure_reg, uv_idx, 0);
                    },
                }
            } else {
                // No local or upvalue - store to global _ENV[name]
                try old_proto.emitSETTABUP(0, base_const, closure_reg);
            }
        } else {
            // Field function: function t.a.b() -> t.a.b = closure
            // Load base table (could be local, upvalue, or global)
            var table_reg = old_proto.allocTemp();
            if (try old_proto.resolveVariable(base_name)) |loc| {
                switch (loc) {
                    .local => |local_reg| {
                        try old_proto.emitMOVE(table_reg, local_reg);
                    },
                    .upvalue => |uv_idx| {
                        try old_proto.emit(.GETUPVAL, table_reg, uv_idx, 0);
                    },
                }
            } else {
                // Load from _ENV
                try old_proto.emitGETTABUP(table_reg, 0, base_const);
            }

            // Navigate through intermediate fields (all but the last)
            var i: usize = 0;
            while (i < field_count - 1) : (i += 1) {
                const field_const = try old_proto.addConstString(field_names[i]);
                const next_reg = old_proto.allocTemp();
                try old_proto.emitGETFIELD(next_reg, table_reg, field_const);
                table_reg = next_reg;
            }

            // Set the last field to the closure
            const last_field_const = try old_proto.addConstString(field_names[field_count - 1]);
            try old_proto.emitSETFIELD(table_reg, last_field_const, closure_reg);
        }
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
        var func_builder = try ProtoBuilder.init(self.proto.allocator, self.proto);
        defer func_builder.deinit();

        // Create RawProto container with safe default values
        // This ensures cleanup won't crash if parsing fails before proto is filled
        const proto_ptr = try self.proto.allocator.create(RawProto);
        proto_ptr.* = .{
            .code = &.{},
            .booleans = &.{},
            .integers = &.{},
            .numbers = &.{},
            .strings = &.{},
            .native_ids = &.{},
            .const_refs = &.{},
            .protos = &.{},
            .numparams = 0,
            .is_vararg = false,
            .maxstacksize = 0,
        };

        // Add function to parent's function list for recursive calls
        try self.proto.addFunction(func_name, proto_ptr);

        // Add function name to local scope NOW (enables recursion via local lookup)
        try self.proto.addVariable(func_name, func_reg);

        // Parse parameters
        var param_count: u8 = 0;
        // Check for vararg-only function: function(...)
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
            func_builder.is_vararg = true;
            self.advance(); // consume '...'
        } else if (self.current.kind == .Identifier) {
            const param_name = self.current.lexeme;
            self.advance();
            try func_builder.addVariable(param_name, param_count);
            param_count += 1;

            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
                self.advance(); // consume ','
                // Check for vararg: function(a, b, ...)
                if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
                    func_builder.is_vararg = true;
                    self.advance(); // consume '...'
                    break;
                }
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

        // Emit VARARGPREP for vararg functions
        if (func_builder.is_vararg) {
            try func_builder.emit(.VARARGPREP, param_count, 0, 0);
        }

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
        var func_builder = try ProtoBuilder.init(self.proto.allocator, self.proto);
        defer func_builder.deinit();

        // Create RawProto container with safe default values
        // This ensures cleanup won't crash if parsing fails before proto is filled
        const proto_ptr = try self.proto.allocator.create(RawProto);
        errdefer self.proto.allocator.destroy(proto_ptr);
        proto_ptr.* = .{
            .code = &.{},
            .booleans = &.{},
            .integers = &.{},
            .numbers = &.{},
            .strings = &.{},
            .native_ids = &.{},
            .const_refs = &.{},
            .protos = &.{},
            .numparams = 0,
            .is_vararg = false,
            .maxstacksize = 0,
        };

        // Parse parameters
        var param_count: u8 = 0;
        // Check for vararg-only function: function(...)
        if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
            func_builder.is_vararg = true;
            self.advance(); // consume '...'
        } else if (self.current.kind == .Identifier) {
            const param_name = self.current.lexeme;
            self.advance();
            try func_builder.addVariable(param_name, param_count);
            param_count += 1;

            while (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, ",")) {
                self.advance(); // consume ','
                // Check for vararg: function(a, b, ...)
                if (self.current.kind == .Symbol and std.mem.eql(u8, self.current.lexeme, "...")) {
                    func_builder.is_vararg = true;
                    self.advance(); // consume '...'
                    break;
                }
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

        // Emit VARARGPREP for vararg functions
        if (func_builder.is_vararg) {
            try func_builder.emit(.VARARGPREP, param_count, 0, 0);
        }

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
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => {
                    try result.append(allocator, '\n');
                    i += 2;
                },
                't' => {
                    try result.append(allocator, '\t');
                    i += 2;
                },
                'r' => {
                    try result.append(allocator, '\r');
                    i += 2;
                },
                '\\' => {
                    try result.append(allocator, '\\');
                    i += 2;
                },
                '"' => {
                    try result.append(allocator, '"');
                    i += 2;
                },
                '\'' => {
                    try result.append(allocator, '\'');
                    i += 2;
                },
                else => {
                    // Unknown escape - keep as-is
                    try result.append(allocator, input[i]);
                    i += 1;
                },
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return try allocator.dupe(u8, result.items);
}
