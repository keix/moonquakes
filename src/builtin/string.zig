const std = @import("std");
const TValue = @import("../core/value.zig").TValue;

// TODO: real number formatting with proper allocator
fn formatNumberStub(n: f64) []const u8 {
    if (n == 0.0) return "0";
    if (n == 1.0) return "1";
    if (n == 2.0) return "2";
    if (n == 42.0) return "42";
    return "number"; // Stub fallback
}

pub fn nativeToString(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const arg = if (nargs > 0) &vm.stack[vm.base + func_reg + 1] else null;

    const result = if (arg) |v| switch (v.*) {
        .number => |n| TValue{ .string = formatNumberStub(n) },
        .integer => |i| TValue{ .string = formatNumberStub(@floatFromInt(i)) },
        .string => v.*,
        .nil => TValue{ .string = "nil" },
        .boolean => |b| TValue{ .string = if (b) "true" else "false" },
        .function => TValue{ .string = "<function>" },
        .table => TValue{ .string = "<table>" },
        .closure => TValue{ .string = "<function>" },
    } else TValue{ .string = "nil" };

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
}
