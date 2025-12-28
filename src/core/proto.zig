const std = @import("std");
const TValue = @import("../core/value.zig").TValue;
const Instruction = @import("../compiler/opcodes.zig").Instruction;

pub const Proto = struct {
    k: []const TValue,
    code: []const Instruction,
    numparams: u8,
    is_vararg: bool,
    maxstacksize: u8,
};
