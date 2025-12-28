const std = @import("std");
const TValue = @import("../core/value.zig").TValue;
const string = @import("string.zig");

pub fn nativePrint(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const stdout = std.io.getStdOut().writer();

    var i: u32 = 0;
    while (i < nargs) : (i += 1) {
        if (i > 0) {
            try stdout.writeAll("\t");
        }

        // Use temporary registers to avoid corrupting the stack
        const tmp_reg = vm.top;
        vm.top += 2; // Need 2 registers: argument at tmp_reg+1, result at tmp_reg

        // Copy argument to temporary register for tostring
        const arg_reg = func_reg + 1 + i;
        vm.stack[vm.base + tmp_reg + 1] = vm.stack[vm.base + arg_reg];

        // Call tostring with argument at tmp_reg+1, result at tmp_reg
        try string.nativeToString(vm, tmp_reg, 1, 1);

        // Get the string result from tostring
        const result = vm.stack[vm.base + tmp_reg];
        const str_val = switch (result) {
            .string => |s| s,
            else => unreachable, // tostring must return string
        };

        try stdout.writeAll(str_val);

        // Clean up temporary registers
        vm.top -= 2;
    }
    try stdout.writeAll("\n");

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue{ .nil = {} };
    }
}
