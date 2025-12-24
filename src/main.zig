const std = @import("std");
const TValue = @import("core/value.zig").TValue;
const Proto = @import("vm/func.zig").Proto;
const VM = @import("vm/vm.zig").VM;
const opcodes = @import("compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const lexer = @import("compiler/lexer.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // Test lexer with simple Lua code
    const test_source = "local x = 42\nreturn x + 1";

    try stdout.print("Testing lexer with: {s}\n", .{test_source});
    try stdout.print("Tokens:\n", .{});
    lexer.dumpAllTokens(test_source);
    try stdout.print("\n", .{});

    // Original VM test
    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0),
        Instruction.initABx(.LOADK, 1, 1),
        Instruction.initABC(.ADD, 2, 0, 1),
        Instruction.initABC(.RETURN, 2, 2, 0),
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
    switch (result) {
        .none => try stdout.print("Result: nil\n", .{}),
        .single => |val| try stdout.print("Result: {}\n", .{val}),
        .multiple => |vals| {
            try stdout.print("Results: ", .{});
            for (vals, 0..) |val, i| {
                if (i > 0) try stdout.print(", ", .{});
                try stdout.print("{}", .{val});
            }
            try stdout.print("\n", .{});
        },
    }
}
