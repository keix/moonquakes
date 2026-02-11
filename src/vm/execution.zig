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
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const OpCode = opcodes.OpCode;
const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;
const ProtoObject = object.ProtoObject;

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
    func: *const ProtoObject,
    closure: ?*ClosureObject, // closure for upvalue access (null for main chunk)

    // Execution state
    pc: [*]const Instruction,
    savedpc: ?[*]const Instruction, // saved pc for yielding

    // Stack frame
    base: u32,
    ret_base: u32, // Where to place return values in caller's frame

    // Vararg support
    vararg_base: u32 = 0, // Stack position where varargs are stored
    vararg_count: u32 = 0, // Number of vararg values

    // Call control
    nresults: i16, // expected number of results (-1 = multiple)
    previous: ?*CallInfo, // previous frame in the call stack

    // Protected call support (for pcall)
    is_protected: bool = false, // true if this is a pcall frame

    // To-be-closed variable support (Lua 5.4)
    // Bitmap tracking which registers are marked as TBC (up to 64 registers)
    tbc_bitmap: u64 = 0,

    /// Mark a register as to-be-closed
    pub fn markTBC(self: *CallInfo, reg: u8) void {
        if (reg < 64) {
            self.tbc_bitmap |= (@as(u64, 1) << @intCast(reg));
        }
    }

    /// Check if a register is marked as to-be-closed
    pub fn isTBC(self: *const CallInfo, reg: u8) bool {
        if (reg >= 64) return false;
        return (self.tbc_bitmap & (@as(u64, 1) << @intCast(reg))) != 0;
    }

    /// Get the highest TBC register at or above 'from' (returns null if none)
    pub fn getHighestTBC(self: *const CallInfo, from: u8) ?u8 {
        if (self.tbc_bitmap == 0) return null;
        var i: u8 = 63;
        while (true) {
            if (i >= from and self.isTBC(i)) {
                return i;
            }
            if (i == 0) break;
            i -= 1;
        }
        return null;
    }

    /// Clear TBC mark for a register
    pub fn clearTBC(self: *CallInfo, reg: u8) void {
        if (reg < 64) {
            self.tbc_bitmap &= ~(@as(u64, 1) << @intCast(reg));
        }
    }

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
