const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const Instruction = @import("opcodes.zig").Instruction;

/// Upvalue descriptor - describes how to capture an upvalue
pub const Upvaldesc = struct {
    /// If true, upvalue is in enclosing function's stack (local variable)
    /// If false, upvalue is in enclosing function's upvalues
    instack: bool,
    /// Index: stack slot if instack, upvalue index otherwise
    idx: u8,
    /// Name of the upvalue (for debugging, optional)
    name: ?[]const u8 = null,
};

pub const Proto = struct {
    k: []const TValue,
    code: []const Instruction,
    protos: []const *const Proto = &.{}, // Nested function prototypes
    numparams: u8,
    is_vararg: bool,
    maxstacksize: u8,
    nups: u8 = 0, // Number of upvalues
    upvalues: []const Upvaldesc = &.{}, // Upvalue descriptors
};
