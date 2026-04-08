//! Synthetic CALL/RETURN frame helpers shared by bootstrap-style VM paths.

const std = @import("std");
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const object = @import("../runtime/gc/object.zig");

pub const call_return_code = [_]Instruction{
    Instruction.initABC(.CALL, 0, 0, 0),
    Instruction.initABC(.RETURN, 0, 0, 0),
};

pub const call_return_lineinfo = [_]u32{ 1, 1 };

pub fn initCallReturnProto(source: []const u8, maxstacksize: u8) object.ProtoObject {
    return .{
        .header = object.GCObject.init(.proto, null),
        .k = &.{},
        .code = call_return_code[0..],
        .protos = &.{},
        .numparams = 0,
        .is_vararg = true,
        .maxstacksize = maxstacksize,
        .nups = 0,
        .upvalues = &.{},
        .allocator = std.heap.page_allocator,
        .source = source,
        .lineinfo = call_return_lineinfo[0..],
    };
}
