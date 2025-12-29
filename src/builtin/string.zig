const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

fn formatNumber(allocator: std.mem.Allocator, n: f64) ![]const u8 {
    // Handle integers that fit in i64 range and have no fractional part
    if (n == @floor(n) and n >= std.math.minInt(i64) and n <= std.math.maxInt(i64)) {
        const int_val: i64 = @intFromFloat(n);
        return try std.fmt.allocPrint(allocator, "{d}", .{int_val});
    }
    // Handle floating point numbers
    return try std.fmt.allocPrint(allocator, "{}", .{n});
}

fn formatInteger(allocator: std.mem.Allocator, i: i64) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{d}", .{i});
}

pub fn nativeToString(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const arg = if (nargs > 0) &vm.stack[vm.base + func_reg + 1] else null;

    // Use arena allocator for string management
    // TODO: Replace with vm.gc.allocString() when GC is implemented
    const arena_allocator = vm.arena.allocator();

    const result = if (arg) |v| switch (v.*) {
        .number => |n| TValue{ .string = try formatNumber(arena_allocator, n) },
        .integer => |i| TValue{ .string = try formatInteger(arena_allocator, i) },
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
