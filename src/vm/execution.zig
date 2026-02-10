//! Execution ABI
//!
//! This module defines the execution contract between VM state and Mnemonics semantics:
//! - CallInfo: execution frame (the unit of coroutine resume)
//! - ReturnValue: execution result
//! - ExecuteResult: instruction dispatch result
//!
//! Future additions: YieldResult, ResumeResult, CallStatus

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const OpCode = opcodes.OpCode;
const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;

// ============================================================================
// Execution Results
// ============================================================================

pub const ReturnValue = union(enum) {
    none,
    single: TValue,
    multiple: []TValue,
};

/// Result of executing a single instruction.
pub const ExecuteResult = union(enum) {
    Continue,
    LoopContinue,
    ReturnVM: ReturnValue,
};

// ============================================================================
// Call Info
// ============================================================================

/// CallInfo represents a function call in the call stack
pub const CallInfo = struct {
    // Function info
    func: *const Proto,
    closure: ?*ClosureObject, // closure for upvalue access (null for main chunk)

    // Execution state
    pc: [*]const Instruction,
    savedpc: ?[*]const Instruction, // saved pc for yielding

    // Stack frame
    base: u32,
    ret_base: u32, // Where to place return values in caller's frame

    // Call control
    nresults: i16, // expected number of results (-1 = multiple)
    previous: ?*CallInfo, // previous frame in the call stack

    // Protected call support (for pcall)
    is_protected: bool = false, // true if this is a pcall frame

    /// Fetch next instruction and advance PC
    /// Encapsulates PC bounds checking as an invariant
    pub inline fn fetch(self: *CallInfo) !Instruction {
        try self.validatePC();
        const inst = self.pc[0];
        self.skip();

        return inst;
    }

    /// Skip next instruction (increment PC by 1)
    pub inline fn skip(self: *CallInfo) void {
        self.pc += 1;
    }

    /// Jump relatively from current PC position
    /// Handles both forward and backward jumps
    pub inline fn jumpRel(self: *CallInfo, offset: i32) !void {
        if (offset >= 0) {
            self.pc += @as(usize, @intCast(offset));
        } else {
            self.pc -= @as(usize, @intCast(-offset));
        }

        try self.validatePC();
    }

    /// Fetch next instruction expecting it to be EXTRAARG
    /// Used by instructions like LOADKX that consume 2-word opcodes
    pub inline fn fetchExtraArg(self: *CallInfo) !Instruction {
        const inst = try self.fetch();
        if (inst.getOpCode() != .EXTRAARG) {
            return error.UnknownOpcode;
        }
        return inst;
    }

    /// Validate PC is within function bounds (disabled in ReleaseFast)
    inline fn validatePC(self: *CallInfo) !void {
        if (std.debug.runtime_safety) {
            const pc_offset = @intFromPtr(self.pc) - @intFromPtr(self.func.code.ptr);
            const pc_index = pc_offset / @sizeOf(Instruction);
            if (pc_index >= self.func.code.len) {
                return error.PcOutOfRange;
            }
        }
    }
};
