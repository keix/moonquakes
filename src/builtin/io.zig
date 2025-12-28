const std = @import("std");

pub fn nativeIoWrite(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const stdout = std.io.getStdOut().writer();
    if (nargs > 0) {
        const arg = &vm.stack[vm.base + func_reg + 1];
        try stdout.print("{}", .{arg.*}); // No newline for io.write
    }

    // Set result (io.write returns file object, but we return nil for simplicity)
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = .nil;
    }
}
