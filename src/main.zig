const std = @import("std");
const TValue = @import("core/value.zig").TValue;
const Proto = @import("vm/func.zig").Proto;
const VM = @import("vm/vm.zig").VM;
const opcodes = @import("compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
    };

    const code = [_]u32{
        @bitCast(Instruction.initABx(.LOADK, 0, 0)),
        @bitCast(Instruction.initABx(.LOADK, 1, 1)),
        @bitCast(Instruction.initABC(.ADD, 2, 0, 1)),
        @bitCast(Instruction.initABC(.RETURN, 2, 2, 0)),
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = VM.init();
    const result = try vm.execute(&proto);

    try stdout.print("Moonquakes speaks for the first time!\n", .{});
    if (result) |val| {
        try stdout.print("Result: {}\n", .{val});
    } else {
        try stdout.print("Result: nil\n", .{});
    }
}