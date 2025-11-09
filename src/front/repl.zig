const std = @import("std");
const moonquakes = @import("moonquakes.zig");
const TValue = moonquakes.core.value.TValue;
const Proto = moonquakes.vm.func.Proto;
const VM = moonquakes.vm.vm.VM;
const opcodes = moonquakes.compiler.opcodes;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
    };

    const code = [_]opcodes.Instruction{
        opcodes.CREATE_ABx(.LOADK, 0, 0),
        opcodes.CREATE_ABx(.LOADK, 1, 1),
        opcodes.CREATE_ABC(.ADD, 2, 0, 1),
        opcodes.CREATE_ABC(.RETURN, 2, 2, 0),
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
