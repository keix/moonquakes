const std = @import("std");

/// Note:
/// Current TValue includes only primitive types (nil/boolean/integer/number).
/// Later this union will be extended with pointer types (string, table, function, GCObject*).
pub const ValueType = enum(u8) {
    nil,
    boolean,
    integer,
    number,
};

pub const TValue = union(ValueType) {
    nil: void,
    boolean: bool,
    integer: i64,
    number: f64,

    pub fn isNil(self: TValue) bool {
        return self == .nil;
    }

    pub fn isBoolean(self: TValue) bool {
        return self == .boolean;
    }

    pub fn isInteger(self: TValue) bool {
        return self == .integer;
    }

    pub fn isNumber(self: TValue) bool {
        return self == .number;
    }

    pub fn toInteger(self: TValue) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .number => |n| if (std.math.modf(n).fpart == 0.0) @intFromFloat(n) else null,
            else => null,
        };
    }

    pub fn toNumber(self: TValue) ?f64 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .number => |n| n,
            else => null,
        };
    }

    pub fn toBoolean(self: TValue) bool {
        return switch (self) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    pub fn format(
        self: TValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .nil => try writer.print("nil", .{}),
            .boolean => |b| try writer.print("{}", .{b}),
            .integer => |i| try writer.print("{}", .{i}),
            .number => |n| try writer.print("{d}", .{n}),
        }
    }

    pub fn eql(a: TValue, b: TValue) bool {
        return switch (a) {
            .nil => b == .nil,
            .boolean => |ab| b == .boolean and ab == b.boolean,
            .integer => |ai| switch (b) {
                .integer => |bi| ai == bi,
                .number => |bn| @as(f64, @floatFromInt(ai)) == bn,
                else => false,
            },
            .number => |an| switch (b) {
                .integer => |bi| an == @as(f64, @floatFromInt(bi)),
                .number => |bn| an == bn,
                else => false,
            },
        };
    }
};
