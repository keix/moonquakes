const std = @import("std");
const TValue = @import("../core/value.zig").TValue;
const Proto = @import("func.zig").Proto;
const Instruction = @import("../compiler/opcodes.zig").Instruction;

pub const CallFrame = struct {
    func: *const Proto,
    pc: [*]const u32,
    base: u32,
    top: u32,
};