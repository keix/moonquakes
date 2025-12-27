const std = @import("std");
const Closure = @import("closure.zig").Closure;

/// Note:
/// Current TValue includes primitive types and closure.
/// Later this union will be extended with more pointer types (string, table, GCObject*).
pub const ValueType = enum(u8) {
    nil,
    boolean,
    integer,
    number,
    closure,
    native_func,
    string, // Add at the end to preserve existing enum values
};

pub const TValue = union(ValueType) {
    nil: void,
    boolean: bool,
    integer: i64,
    number: f64,
    closure: *const Closure,
    native_func: u8,
    string: []const u8,

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

    pub fn isClosure(self: TValue) bool {
        return self == .closure;
    }

    pub fn isString(self: TValue) bool {
        return self == .string;
    }

    pub fn isNativeFunc(self: TValue) bool {
        return self == .native_func;
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

    pub fn toClosure(self: TValue) ?*const Closure {
        return switch (self) {
            .closure => |c| c,
            else => null,
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
            .closure => |c| try writer.print("function: 0x{x}", .{@intFromPtr(c)}),
            .native_func => |id| try writer.print("native_function_{}", .{id}),
            .string => |s| try writer.print("{s}", .{s}),
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
            .closure => |ac| b == .closure and ac == b.closure,
            .native_func => |af| b == .native_func and af == b.native_func,
            .string => |as| b == .string and std.mem.eql(u8, as, b.string),
        };
    }
};
